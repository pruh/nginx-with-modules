#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE_REPOSITORY=nginx
readonly IMAGE_TAG=alpine-slim
readonly DOCKERFILE=Dockerfile
readonly NGINX_DOWNLOAD_URL=https://nginx.org/download
readonly -a BUILD_PACKAGES=(
  gcc
  musl-dev
  make
  openssl-dev
  pcre2-dev
  zlib-dev
  linux-headers
)
readonly -a SIGNING_KEYS=(
  "https://nginx.org/keys/arut.key|43387825DDB1BB97EC36BA5D007C8D7C15D87369"
  "https://nginx.org/keys/pluknet.key|D6786CE303D9A9022998DC6CC8464D549AF75C0A"
  "https://nginx.org/keys/thresh.key|13C82A63B603576156E30A4EA0EA981B66B0D967"
)

for command in awk curl docker git gpg sed sha256sum; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Run this script from the repository root" >&2
  exit 1
fi

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

digest=$(docker buildx imagetools inspect \
  "$IMAGE_REPOSITORY:$IMAGE_TAG" \
  --format '{{.Manifest.Digest}}')
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Invalid manifest digest: $digest" >&2
  exit 1
fi

exact_image="$IMAGE_REPOSITORY:$IMAGE_TAG@$digest"
docker pull --quiet --platform linux/amd64 "$exact_image" >/dev/null

nginx_version=
while IFS='=' read -r name value; do
  if [[ "$name" == NGINX_VERSION ]]; then
    nginx_version=$value
    break
  fi
done < <(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$exact_image")

if [[ ! "$nginx_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid nginx version: $nginx_version" >&2
  exit 1
fi

export GNUPGHOME="$workdir/gnupg"
mkdir -m 700 "$GNUPGHOME"

declare -A allowed_signers=()

for signing_key in "${SIGNING_KEYS[@]}"; do
  key_url=${signing_key%%|*}
  expected_fingerprint=${signing_key##*|}
  key_file="$workdir/${key_url##*/}"

  curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
    --location "$key_url" --output "$key_file"
  mapfile -t fingerprints < <(
    gpg --batch --show-keys --with-colons "$key_file" |
      awk -F: '
        $1 == "pub" { primary = 1; next }
        primary && $1 == "fpr" { print $10; primary = 0 }
      '
  )

  if (( ${#fingerprints[@]} != 1 )) ||
    [[ "${fingerprints[0]:-}" != "$expected_fingerprint" ]]; then
    echo "Expected only primary key $expected_fingerprint in $key_url" >&2
    exit 1
  fi

  gpg --batch --quiet --import "$key_file"
  allowed_signers["$expected_fingerprint"]=1
done

source_file="$workdir/nginx-$nginx_version.tar.gz"
signature_file="$source_file.asc"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  "$NGINX_DOWNLOAD_URL/nginx-$nginx_version.tar.gz" --output "$source_file"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  "$NGINX_DOWNLOAD_URL/nginx-$nginx_version.tar.gz.asc" \
  --output "$signature_file"
signature_status="$workdir/signature.status"
gpg --batch --status-file "$signature_status" \
  --verify "$signature_file" "$source_file"
mapfile -t valid_signers < <(
  awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3 }' \
    "$signature_status"
)
if (( ${#valid_signers[@]} != 1 )) ||
  [[ -z ${allowed_signers[${valid_signers[0]:-}]:-} ]]; then
  echo "Source signature was not made by exactly one allowlisted key" >&2
  exit 1
fi
source_sha256=$(sha256sum "$source_file")
source_sha256=${source_sha256%% *}

replace_exactly_once() {
  local pattern=$1
  local replacement=$2
  local expected=${3:-$replacement}
  local matches

  matches=$(awk -v pattern="$pattern" '$0 ~ pattern { count++ } END { print count + 0 }' \
    "$DOCKERFILE")
  if [[ "$matches" != 1 ]]; then
    echo "Expected one Dockerfile line matching: $pattern; found $matches" >&2
    exit 1
  fi

  sed -i -E "s|$pattern|$replacement|" "$DOCKERFILE"

  matches=$(EXPECTED_LINE="$expected" awk \
    '$0 == ENVIRON["EXPECTED_LINE"] { count++ } END { print count + 0 }' \
    "$DOCKERFILE")
  if [[ "$matches" != 1 ]]; then
    echo "Failed to write exactly one Dockerfile line: $expected" >&2
    exit 1
  fi
}

declare -A package_versions=()
while IFS='=' read -r package version; do
  package_versions["$package"]=$version
done < <(
  docker run --rm --platform linux/amd64 "$exact_image" \
    sh -c 'apk update >/dev/null && apk policy "$@"' sh "${BUILD_PACKAGES[@]}" |
    awk '
      / policy:$/ { package = $1; next }
      package != "" && /^  [^ ]/ {
        version = $1
        sub(/:$/, "", version)
        print package "=" version
        package = ""
      }
    '
)

for package in "${BUILD_PACKAGES[@]}"; do
  version=${package_versions[$package]:-}
  if [[ ! "$version" =~ ^[0-9][0-9A-Za-z._+~-]*-r[0-9]+$ ]]; then
    echo "Invalid package version for $package: $version" >&2
    exit 1
  fi

  expected_line="  ${package}=${version}"
  if [[ "$package" != "${BUILD_PACKAGES[-1]}" ]]; then
    expected_line+=" \\"
  fi
  replace_exactly_once \
    "^  ${package}=[^[:space:]]+" \
    "  ${package}=${version}" \
    "$expected_line"
done

replace_exactly_once \
  '^ARG NGINX_IMAGE=.*$' \
  "ARG NGINX_IMAGE=nginx:${nginx_version}-alpine-slim@${digest}"
replace_exactly_once \
  '^ARG NGINX_SOURCE_SHA256=.*$' \
  "ARG NGINX_SOURCE_SHA256=${source_sha256}"

changed=false
if ! git diff --quiet -- "$DOCKERFILE"; then
  changed=true
fi

content_sha=$(sha256sum "$DOCKERFILE")
content_sha=${content_sha%% *}
branch="automation/nginx-${nginx_version}-${content_sha:0:12}"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "base_digest=$digest"
    echo "branch=$branch"
    echo "changed=$changed"
    echo "nginx_version=$nginx_version"
  } >> "$GITHUB_OUTPUT"
fi

echo "nginx version: $nginx_version"
echo "base digest: $digest"
echo "source SHA-256: $source_sha256"
echo "changed: $changed"

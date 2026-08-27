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

current_image=$(awk '$1 == "ARG" && $2 ~ /^NGINX_IMAGE=/ { print $2 }' "$DOCKERFILE")
if [[ ! "$current_image" =~ ^NGINX_IMAGE=nginx:([0-9]+\.[0-9]+\.[0-9]+)-alpine-slim@(sha256:[0-9a-f]{64})$ ]]; then
  echo "Invalid current nginx image: $current_image" >&2
  exit 1
fi
current_nginx_version=${BASH_REMATCH[1]}
current_digest=${BASH_REMATCH[2]}

current_source=$(awk '$1 == "ARG" && $2 ~ /^NGINX_SOURCE_SHA256=/ { print $2 }' "$DOCKERFILE")
if [[ ! "$current_source" =~ ^NGINX_SOURCE_SHA256=([0-9a-f]{64})$ ]]; then
  echo "Invalid current nginx source checksum: $current_source" >&2
  exit 1
fi
current_source_sha256=${BASH_REMATCH[1]}

declare -A package_versions=()
declare -A current_package_versions=()
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
  current_version=$(awk -v prefix="$package=" \
    'index($1, prefix) == 1 { print substr($1, length(prefix) + 1) }' \
    "$DOCKERFILE")
  if [[ ! "$version" =~ ^[0-9][0-9A-Za-z._+~-]*-r[0-9]+$ ]]; then
    echo "Invalid package version for $package: $version" >&2
    exit 1
  fi
  if [[ ! "$current_version" =~ ^[0-9][0-9A-Za-z._+~-]*-r[0-9]+$ ]]; then
    echo "Invalid current package version for $package: $current_version" >&2
    exit 1
  fi
  current_package_versions["$package"]=$current_version

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

declare -a change_details=()
declare -a change_labels=()
declare -a changed_packages=()

if [[ "$current_nginx_version" != "$nginx_version" ]]; then
  change_details+=("- \`nginx\`: \`$current_nginx_version\` -> \`$nginx_version\`")
fi
if [[ "$current_digest" != "$digest" ]]; then
  change_labels+=("base image")
  change_details+=("- nginx base digest: \`$current_digest\` -> \`$digest\`")
fi
if [[ "$current_source_sha256" != "$source_sha256" ]]; then
  change_labels+=("source checksum")
  change_details+=("- nginx source SHA-256: \`$current_source_sha256\` -> \`$source_sha256\`")
fi
for package in "${BUILD_PACKAGES[@]}"; do
  current_version=${current_package_versions[$package]}
  version=${package_versions[$package]}
  if [[ "$current_version" != "$version" ]]; then
    changed_packages+=("$package")
    change_labels+=("$package")
    change_details+=("- \`$package\`: \`$current_version\` -> \`$version\`")
  fi
done

if [[ "$changed" == true ]] && (( ${#change_details[@]} == 0 )); then
  echo "Dockerfile changed without a recognized pinned input update" >&2
  exit 1
fi

if [[ "$changed" != true ]]; then
  update_title="No pinned input updates for nginx $nginx_version"
elif [[ "$current_nginx_version" != "$nginx_version" ]]; then
  update_title="Update nginx to $nginx_version"
elif (( ${#changed_packages[@]} == 1 && ${#change_labels[@]} == 1 )); then
  package=${changed_packages[0]}
  update_title="Update $package to ${package_versions[$package]}"
elif (( ${#changed_packages[@]} > 0 && ${#changed_packages[@]} == ${#change_labels[@]} )); then
  printf -v changed_names '%s, ' "${changed_packages[@]}"
  update_title="Update build dependencies: ${changed_names%, }"
else
  printf -v changed_names '%s, ' "${change_labels[@]}"
  update_title="Update nginx $nginx_version inputs: ${changed_names%, }"
fi

update_body='Automated update to pinned Dockerfile inputs.'
if (( ${#change_details[@]} > 0 )); then
  printf -v details '%s\n' "${change_details[@]}"
  update_body+=$'\n\n'
  update_body+=${details%$'\n'}
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
    echo "update_title=$update_title"
    echo "update_body<<update-body-$content_sha"
    echo "$update_body"
    echo "update-body-$content_sha"
  } >> "$GITHUB_OUTPUT"
fi

echo "nginx version: $nginx_version"
echo "base digest: $digest"
echo "source SHA-256: $source_sha256"
echo "changed: $changed"
echo "update title: $update_title"

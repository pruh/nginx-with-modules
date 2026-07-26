#!/bin/sh
set -eu

IMAGE=${1:?Usage: tests/smoke.sh IMAGE}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONTAINER="nginx-with-modules-smoke-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker run --rm \
  --entrypoint nginx \
  --volume "$ROOT/tests/nginx.conf:/etc/nginx/smoke.conf:ro" \
  "$IMAGE" -t -c /etc/nginx/smoke.conf

docker run --detach \
  --name "$CONTAINER" \
  --publish 127.0.0.1::8080 \
  --volume "$ROOT/tests/nginx.conf:/etc/nginx/smoke.conf:ro" \
  "$IMAGE" nginx -c /etc/nginx/smoke.conf -g "daemon off;" >/dev/null

ENDPOINT=$(docker port "$CONTAINER" 8080/tcp)
PORT=${ENDPOINT##*:}
EXPECTED="a%20b"
RESPONSE=
ATTEMPT=0

while [ "$ATTEMPT" -lt 20 ]; do
  if RESPONSE=$(curl --fail --silent --show-error "http://127.0.0.1:$PORT/"); then
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done

if [ "$RESPONSE" != "$EXPECTED" ]; then
  docker logs "$CONTAINER"
  echo "Unexpected response: $RESPONSE" >&2
  exit 1
fi

curl --fail --silent --show-error "http://127.0.0.1:$PORT/hmac" >/dev/null

# nginx-with-modules

An nginx Alpine image with these dynamic modules preloaded:

- [NGINX Development Kit](https://github.com/vision5/ngx_devel_kit) 0.3.4
- [set-misc-nginx-module](https://github.com/openresty/set-misc-nginx-module) 0.34

The image preserves the official nginx entrypoint, default server, exposed port,
and graceful shutdown behavior. It is useful for configurations that require
set-misc directives, including some Authelia deployments.

## Run

Start the default nginx server:

```sh
docker run --rm --publish 8080:80 pruh/nginx-with-modules:alpine
```

Mount custom server configuration in the same way as the official nginx image:

```sh
docker run --rm --publish 8080:80 \
  --volume "$PWD/conf.d:/etc/nginx/conf.d:ro" \
  pruh/nginx-with-modules:alpine
```

The module load directives are already present in `/etc/nginx/nginx.conf`.

## Tags

- `latest` and `alpine` track the most recently published build.
- `<nginx-version>-alpine`, such as `1.31.3-alpine`, identifies the nginx
  version but may be rebuilt when modules or image metadata change.

All tags are mutable. Pin the published image digest when deployment
reproducibility is required.

Published images support `linux/amd64` and `linux/arm64`.

## Build And Test

The Dockerfile pins the nginx manifest, module commits, and source checksums.
Build and run the smoke tests locally with:

```sh
docker build --pull --tag nginx-with-modules:test .
tests/smoke.sh nginx-with-modules:test
```

The smoke test validates nginx configuration, module loading, URI escaping,
HMAC execution, container startup, and an HTTP response.

## Releases

Pull requests always build and test the image without registry credentials.
Merges to `master`, or a manual workflow run on `master`, publish the
multi-architecture image to Docker Hub. Published manifests include OCI source
and revision labels, an SBOM, and BuildKit provenance attestations.

Base image or module updates are made as reviewed commits. When updating an
input, update its immutable reference and checksum together, then run the smoke
test before merging.

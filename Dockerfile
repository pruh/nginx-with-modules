ARG NGINX_IMAGE=nginx:1.31.4-alpine-slim@sha256:1870de6d59aafee152589b64404556d2535922cdd998e6dac1c4888c938ed8f9
ARG NGX_DEVEL_KIT_VERSION=0.3.4
ARG SET_MISC_VERSION=0.34

FROM ${NGINX_IMAGE} AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG NGINX_SOURCE_SHA256=e6f20b644a17a643f059ae6467a1971fe2811587d025e071068753a1f1e3b3c3
ARG NGX_DEVEL_KIT_COMMIT=bd44d16302273052d6005d7bdb55f74e23813de3
ARG NGX_DEVEL_KIT_SHA256=31963f6eb21c11991bd7b301bed0939570093f45c95ab947e4ac54da5855d4fd
ARG SET_MISC_COMMIT=35365f29dcba9d2f8e9c2c15bd2a14e8a1446d7d
ARG SET_MISC_SHA256=1a33bb62140786de21ae4f7d3d99eaa192a212492b396ba01162eb20c99ac7aa
ARG NGX_DEVEL_KIT_FILE=ngx-devel-kit.tar.gz
ARG SET_MISC_FILE=set-misc.tar.gz

WORKDIR /tmp/build

# Download sources
RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz && \
  wget -q "https://github.com/vision5/ngx_devel_kit/archive/${NGX_DEVEL_KIT_COMMIT}.tar.gz" -O "$NGX_DEVEL_KIT_FILE" && \
  wget -q "https://github.com/openresty/set-misc-nginx-module/archive/${SET_MISC_COMMIT}.tar.gz" -O "$SET_MISC_FILE" && \
  echo "${NGINX_SOURCE_SHA256}  nginx.tar.gz" | sha256sum -c - && \
  echo "${NGX_DEVEL_KIT_SHA256}  ${NGX_DEVEL_KIT_FILE}" | sha256sum -c - && \
  echo "${SET_MISC_SHA256}  ${SET_MISC_FILE}" | sha256sum -c -

# Match the dependencies used by the official nginx Alpine build.
RUN apk add --no-cache --virtual .build-deps \
  gcc=15.2.0-r5 \
  musl-dev=1.2.6-r2 \
  make=4.4.1-r4 \
  openssl-dev=3.5.7-r0 \
  pcre2-dev=10.47-r1 \
  zlib-dev=1.3.2-r0 \
  linux-headers=7.0.0-r1

RUN mkdir -p /usr/src/nginx /usr/src/ngx_devel_kit /usr/src/set-misc && \
  tar -zxC /usr/src/nginx -f nginx.tar.gz && \
  tar -zxC /usr/src/ngx_devel_kit --strip-components=1 -f "$NGX_DEVEL_KIT_FILE" && \
  tar -zxC /usr/src/set-misc --strip-components=1 -f "$SET_MISC_FILE"

WORKDIR /usr/src/nginx/nginx-${NGINX_VERSION}

# Parse the trusted base image's quoted configure arguments into argv.
# hadolint ignore=SC2086
RUN CONFARGS="$(nginx -V 2>&1 | sed -n -e 's/^.*arguments: //p')" && \
  test -n "$CONFARGS" && \
  eval "set -- $CONFARGS" && \
  ./configure "$@" \
    --add-dynamic-module=/usr/src/ngx_devel_kit \
    --add-dynamic-module=/usr/src/set-misc && \
  make modules

FROM ${NGINX_IMAGE}

ARG NGX_DEVEL_KIT_VERSION
ARG SET_MISC_VERSION

LABEL org.opencontainers.image.title="nginx-with-modules" \
  org.opencontainers.image.description="nginx with NDK and set-misc dynamic modules" \
  io.github.pruh.nginx-with-modules.ndk.version="${NGX_DEVEL_KIT_VERSION}" \
  io.github.pruh.nginx-with-modules.set-misc.version="${SET_MISC_VERSION}"

COPY --from=builder /usr/src/nginx/nginx-${NGINX_VERSION}/objs/ndk_http_module.so /usr/lib/nginx/modules/
COPY --from=builder /usr/src/nginx/nginx-${NGINX_VERSION}/objs/ngx_http_set_misc_module.so /usr/lib/nginx/modules/

RUN sed -i '1s/^/# Load dynamic modules\n/' /etc/nginx/nginx.conf && \
  sed -i '2s/^/load_module \/usr\/lib\/nginx\/modules\/ndk_http_module.so;\n/' /etc/nginx/nginx.conf && \
  sed -i '3s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_http_set_misc_module.so;\n/' /etc/nginx/nginx.conf && \
  nginx -t

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]

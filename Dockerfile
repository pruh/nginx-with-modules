ARG NGINX_IMAGE=nginx:1.31.3-alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752

FROM ${NGINX_IMAGE} AS builder

ARG NGINX_SOURCE_SHA256=a7657c50811c2d92d9895395e8b873ef60398142c4db21eb647811c38f6dd525
ARG NGX_DEVEL_KIT_COMMIT=b4642d6ca01011bd8cd30b253f5c3872b384fd21
ARG NGX_DEVEL_KIT_SHA256=c9f1413d6716c4b467a91dd45e5778e41ea678ec08328957cb2de4db06e0aac6
ARG SET_MISC_COMMIT=31c4ad67bb9e392a734e4e58ea8048e24012311f
ARG SET_MISC_SHA256=c65e0cd8fc81d594ed604fce768f8f47d4b9fd7a5ebe09ccc28e0463112a1864

# nginx:alpine contains NGINX_VERSION environment variable, like so:
# ENV NGINX_VERSION 1.23.3

# Modules versions
ENV NGX_DEVEL_KIT_VERSION=0.3.2
ENV NGX_DEVEL_KIT_FILE=ngx-devel-kit.tag.gz

ENV SET_MISC_VERSION=0.33
ENV SET_MISC_FILE=set-misc.tag.gz

# Download sources
RUN wget "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz && \
  wget "https://github.com/vision5/ngx_devel_kit/archive/${NGX_DEVEL_KIT_COMMIT}.tar.gz" -O "$NGX_DEVEL_KIT_FILE" && \
  wget "https://github.com/openresty/set-misc-nginx-module/archive/${SET_MISC_COMMIT}.tar.gz" -O "$SET_MISC_FILE" && \
  echo "${NGINX_SOURCE_SHA256}  nginx.tar.gz" | sha256sum -c - && \
  echo "${NGX_DEVEL_KIT_SHA256}  ${NGX_DEVEL_KIT_FILE}" | sha256sum -c - && \
  echo "${SET_MISC_SHA256}  ${SET_MISC_FILE}" | sha256sum -c -

# For latest build deps, see https://github.com/nginxinc/docker-nginx/blob/master/mainline/alpine/Dockerfile
RUN apk add --no-cache --virtual .build-deps \
  gcc \
  libc-dev \
  make \
  openssl-dev \
  pcre-dev \
  zlib-dev \
  linux-headers \
  curl \
  gnupg \
  libxslt-dev \
  gd-dev \
  geoip-dev

# Reuse same cli arguments as the nginx:alpine image used to build
RUN CONFARGS="$(nginx -V 2>&1 | sed -n -e 's/^.*arguments: //p')" && \
  test -n "$CONFARGS" && \
  mkdir -p /usr/src/nginx /usr/src/ngx_devel_kit /usr/src/set-misc && \
  tar -zxC /usr/src/nginx -f nginx.tar.gz && \
  tar -zxC /usr/src/ngx_devel_kit --strip-components=1 -f "$NGX_DEVEL_KIT_FILE" && \
  NGX_DEVEL_KIT_DIR=/usr/src/ngx_devel_kit && \
  tar -zxC /usr/src/set-misc --strip-components=1 -f "$SET_MISC_FILE" && \
  SET_MISC_DIR=/usr/src/set-misc && \
  cd /usr/src/nginx/nginx-$NGINX_VERSION && \
  eval "set -- $CONFARGS" && \
  ./configure "$@" --add-dynamic-module="$NGX_DEVEL_KIT_DIR" --add-dynamic-module="$SET_MISC_DIR" && \
  make modules

FROM ${NGINX_IMAGE}

# Extract the dynamic modules from the builder image
COPY --from=builder /usr/src/nginx/nginx-${NGINX_VERSION}/objs/*_module.so /etc/nginx/modules/

RUN rm /etc/nginx/conf.d/default.conf

RUN sed -i '1s/^/# Load dynamic modules\n/' /etc/nginx/nginx.conf
RUN sed -i '2s/^/load_module \/etc\/nginx\/modules\/ndk_http_module.so;\n/' /etc/nginx/nginx.conf
RUN sed -i '3s/^/load_module \/etc\/nginx\/modules\/ngx_http_set_misc_module.so;\n/' /etc/nginx/nginx.conf
RUN nginx -t

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]

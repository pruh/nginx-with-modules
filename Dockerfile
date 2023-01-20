FROM nginx:alpine AS builder

# nginx:alpine contains NGINX_VERSION environment variable, like so:
# ENV NGINX_VERSION 1.23.3

# Modules versions
ENV NGX_DEVEL_KIT_VERSION=0.3.2
ENV NGX_DEVEL_KIT_FILE=ngx-devel-kit.tag.gz

ENV SET_MISC_VERSION=0.33
ENV SET_MISC_FILE=set-misc.tag.gz

# Download sources
RUN wget "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz && \
  wget "https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NGX_DEVEL_KIT_VERSION}.tar.gz" -O $NGX_DEVEL_KIT_FILE && \
  wget "https://github.com/openresty/set-misc-nginx-module/archive/refs/tags/v${SET_MISC_VERSION}.tar.gz" -O $SET_MISC_FILE

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
RUN CONFARGS=$(nginx -V 2>&1 | sed -n -e 's/^.*arguments: //p') \
  mkdir -p /usr/src/nginx && \
  tar -zxC /usr/src/nginx -f nginx.tar.gz && \
  tar -xzvf "${NGX_DEVEL_KIT_FILE}" && \
  NGX_DEVEL_KIT_DIR="$(pwd)/ngx_devel_kit-${NGX_DEVEL_KIT_VERSION}" && \
  tar -xzvf $SET_MISC_FILE && \
  SET_MISC_DIR="$(pwd)/set-misc-nginx-module-${SET_MISC_VERSION}" && \
  cd /usr/src/nginx/nginx-$NGINX_VERSION && \
  ./configure --with-compat $CONFARGS --add-dynamic-module=$NGX_DEVEL_KIT_DIR --add-dynamic-module=$SET_MISC_DIR && \
  make modules

FROM nginx:alpine

# Extract the dynamic modules from the builder image
COPY --from=builder /usr/src/nginx/nginx-${NGINX_VERSION}/objs/*_module.so /etc/nginx/modules/

RUN rm /etc/nginx/conf.d/default.conf

RUN sed -i '1s/^/# Load dynamic modules\n/' /etc/nginx/nginx.conf
RUN sed -i '2s/^/load_module \/etc\/nginx\/modules\/ndk_http_module.so;\n/' /etc/nginx/nginx.conf
RUN sed -i '3s/^/load_module \/etc\/nginx\/modules\/ngx_http_set_misc_module.so;\n/' /etc/nginx/nginx.conf

EXPOSE 80
STOPSIGNAL SIGTERM
CMD ["nginx", "-g", "daemon off;"]

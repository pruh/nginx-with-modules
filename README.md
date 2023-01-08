# nginx-with-modules

The repository contains a Dockerfile to build a vanilla nginx with additional modules. The GitHub action pushes the image to Docker Hub on new nginx version. The image can be used in environments where additional modules are required, such as with [Authelia](https://www.authelia.com/).

Currently only contains the following modules:
1. [ngx_devel_kit](https://github.com/vision5/ngx_devel_kit)
2. [http_set_misc](https://github.com/openresty/set-misc-nginx-module)

The original idea is described in the [gist](https://gist.github.com/hermanbanken/96f0ff298c162a522ddbba44cad31081.js) and developed in [Adding dynamic modules to nginx](https://systemd.naboo.space/adding-dynamic-modules-to-nginx/)

# nginx-installer
 Automatic nginx install script

[![GitHub release](https://img.shields.io/github/release/tmiland/nginx-installer.svg?style=for-the-badge)](https://github.com/tmiland/nginx-installer/releases) [![licence](https://img.shields.io/github/license/tmiland/nginx-installer.svg?style=for-the-badge)](https://github.com/tmiland/nginx-installer/blob/main/LICENSE) ![Bash](https://img.shields.io/badge/Language-SH-4EAA25.svg?style=for-the-badge)


 ## Usage
 - Note: Use either headless or extra modules option
 ```bash
 Usage:  nginx_installer.sh [options]
   If called without arguments, installs stable nginx using /opt/nginx

   --help                 |-h   display this help and exit
   --nginx                |-ng  nginx version of choice
   --stable               |-s   stable nginx version 1.28.0
   --mainline             |-m   mainline nginx version 1.29.0
   --headless             |-h   headless install
   --modules-extra        |-me  extra modules
   --dir                  |-d   install directory
   --verbose              |-v   increase verbosity
   --nproc                |-n   set the number of processing units to use
   --enable-debug-info    |-edi enable debug info
   --changelog            |-cl  view changelog for nginx version
   --update               |-upd check for script update
   --uninstall            |-u   uninstall nginx
 ```

- Options / modules can be overridden, just like [nginx-autoinstall](https://github.com/angristan/nginx-autoinstall) 
- (This is the same option as extra modules option.)

 ```bash
 HEADLESS=y \
 PAGESPEED=n \
 BROTLI=n \
 HEADERMOD=y \
 GEOIP=y \
 GEOIP2_ACCOUNT_ID= \
 GEOIP2_LICENSE_KEY= \
 FANCYINDEX=y \
 CACHEPURGE=y \
 SUBFILTER=y \
 LUA=n \
 WEBDAV=y \
 VTS=y \
 RTMP=y \
 TESTCOOKIE=y \
 REDIS2=y \
 HTTPREDIS=n \
 SRCACHE=y \
 SETMISC=y \
 NGXECHO=y \
 ZSTF=y \
 ./nginx_installer.sh
 ```
 
 ### Installation

If root password is not set, type:

```bash
sudo passwd root
```
Log in as root
```bash
su root
```
- Latest release
  ```bash
  curl -sSL https://github.com/tmiland/nginx-installer/releases/latest/download/nginx_installer.sh > nginx_installer.sh && \
  chmod +x nginx_installer.sh && \
  ./nginx_installer.sh
  ```
- Master
  ```bash
  curl -sSL https://github.com/tmiland/nginx-installer/raw/refs/heads/main/nginx_installer.sh > nginx_installer.sh && \
  chmod +x nginx_installer.sh && \
  ./nginx_installer.sh
  ```

To install this script:
  - Latest release
    ```bash
    mkdir -p /opt/nginx-installer && \
      curl -sSL https://github.com/tmiland/nginx-installer/releases/latest/download/nginx_installer.sh > /opt/nginx-installer/nginx-installer.sh && \
      chmod +x /opt/nginx-installer/nginx-installer.sh && \
      ln -s /opt/nginx-installer/nginx-installer.sh /usr/local/bin/nginx-installer && \
      nginx-installer
    ```
  - Master
    ```bash
    mkdir -p /opt/nginx-installer && \
      curl -sSL https://github.com/tmiland/nginx-installer/raw/refs/heads/main/nginx_installer.sh > /opt/nginx-installer/nginx-installer.sh && \
      chmod +x /opt/nginx-installer/nginx-installer.sh && \
      ln -s /opt/nginx-installer/nginx-installer.sh /usr/local/bin/nginx-installer && \
      nginx-installer
    ```

  ## Compatibility and Requirements

  - Debian 9 and later

#### Compile options With headless

```bash
nginx -V
nginx version: nginx/1.28.0
built with Nginx Installer @tmiland
built by gcc 12.2.0 (Debian 12.2.0-14+deb12u1) 
built with OpenSSL 3.0.16 11 Feb 2025
TLS SNI support enabled
configure arguments: --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --user=nginx --group=nginx --with-cc-opt=-Wno-deprecated-declarations --with-cc-opt=-Wno-ignored-qualifiers --with-select_module --with-poll_module --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module --with-mail --with-mail_ssl_module --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_ssl_preread_module --with-cpp_test_module --with-compat --with-pcre --with-pcre-jit
```

#### Compile options With extra modules option
```bash
nginx -V
nginx version: nginx/1.28.0
built with Nginx Installer @tmiland
built by gcc 12.2.0 (Debian 12.2.0-14+deb12u1) 
built with OpenSSL 3.5.1 1 Jul 2025
TLS SNI support enabled
configure arguments: --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --user=nginx --group=nginx --with-cc-opt=-Wno-deprecated-declarations --with-cc-opt=-Wno-ignored-qualifiers --with-select_module --with-poll_module --with-threads --with-file-aio --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module --with-mail --with-mail_ssl_module --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module --with-stream --with-stream_ssl_module --with-stream_realip_module --with-stream_ssl_preread_module --with-cpp_test_module --with-compat --with-pcre --with-pcre-jit --add-module=/opt/nginx/modules/headers-more-nginx-module-0.39 --with-openssl=/opt/nginx/modules/openssl-3.5.1 --add-module=/opt/nginx/modules/ngx_cache_purge --add-module=/opt/nginx/modules/ngx_http_substitutions_filter_module --add-module=/opt/nginx/modules/fancyindex --with-http_dav_module --add-module=/opt/nginx/modules/nginx-dav-ext-module --add-module=/opt/nginx/modules/nginx-module-vts --add-module=/opt/nginx/modules/nginx-rtmp-module --add-module=/opt/nginx/modules/testcookie-nginx-module --add-module=/opt/nginx/modules/redis2-nginx-module --add-module=/opt/nginx/modules/srcache-nginx-module --add-module=/opt/nginx/modules/ngx_devel_kit-0.3.4 --add-module=/opt/nginx/modules/set-misc-nginx-module --add-module=/opt/nginx/modules/echo-nginx-module-0.63
  ```

## Credits
- Code is mixed and customized from these sources
  - [nginx-autoinstall](https://github.com/angristan/nginx-autoinstall)

  ## Donations
  <a href="https://coindrop.to/tmiland" target="_blank"><img src="https://coindrop.to/embed-button.png" style="border-radius: 10px; height: 57px !important;width: 229px !important;" alt="Coindrop.to me"></img></a>

  #### Disclaimer 

  *** ***Use at own risk*** ***

  ### License

  [![MIT License Image](https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/MIT_logo.svg/220px-MIT_logo.svg.png)](https://github.com/tmiland/nginx-installer/blob/main/LICENSE)

  [MIT License](https://github.com/tmiland/nginx-installer/blob/main/LICENSE)
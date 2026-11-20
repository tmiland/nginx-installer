# Usage reference

Full option and module reference for `nginx_installer.sh`. For installation examples, see the [README](../README.md#installation).

## Options

```bash
Usage: nginx_installer.sh [options]
  If called without arguments, installs stable nginx using /opt/nginx

  --help                 |-h   display this help and exit
  --nginx                |-ng  nginx version (X.Y.Z)
  --stable               |-s   stable nginx version (auto-detected)
  --mainline             |-m   mainline nginx version (auto-detected)
  --detect               |-dt  detect the distro and exit
  --headless             |-hl  headless install
  --modules              |-M   module ids or bundle names (comma separated)
  --modules-extra        |-me  preset: append the common extra module ids
  --profile              |-p   built-in module profile: minimal or full
  --modules-rev          |-mr  nginx-modules release tag (default: latest)
  --geoip-account-id     |-ga  MaxMind account id for geoip2
  --geoip-license-key    |-gk  MaxMind license key for geoip2 (visible in ps)
  --geoip-env-file       |-ge  file with GEOIP2_ACCOUNT_ID and GEOIP2_LICENSE_KEY
  --bad-bot              |-bb  install the bad bot blocker
  --dir                  |-d   temporary build directory
  --verbose              |-v   increase verbosity
  --nproc                |-n   set the number of processing units to use
  --enable-debug-info    |-edi enable debug info
  --changelog            |-cl  view changelog for nginx version
  --update               |-upd check for script update
  --uninstall            |-u   uninstall nginx
```

`--headless` only sets the `SSL=1`, `RM_CONF=n`, and `RM_LOGS=n` defaults. It does not select modules or make the installer fully non-interactive.

## Built-in module profiles

| Profile | What it builds |
|---|---|
| `minimal` (default) | TLS, HTTP/2, real IP, threads, file AIO, PCRE, and compatibility support. |
| `full` | Minimal plus select/poll, addition, XSLT, sub, DAV, FLV/MP4, gunzip, gzip static, auth request, random index, secure link, degradation, slice, stub status, Perl, mail, stream, HTTP/3, and the other optional modules. |

`MODULES_PROFILE` selects the default. `NGINX_MODULES` overrides both profiles.

## Module selection

Third-party modules are selected by id, not by per-module flags. The ids and their build steps live in `modules.conf` inside the verified [`tmiland/nginx-modules`](https://github.com/tmiland/nginx-modules) bundle; the bundle is the only module source. See that repository's README for the current id list.

```bash
# Individual ids
sudo ./nginx_installer.sh --modules "headers-more,zstd"

# Curated bundles, or a mix of bundles and ids
sudo ./nginx_installer.sh --modules "web,lua"
sudo ./nginx_installer.sh --modules "lua,headers-more"

# The full set
sudo ./nginx_installer.sh --profile full --modules "all"
```

| Bundle | What it adds |
|---|---|
| `core` | Brotli, headers-more, fancyindex, cachepurge, subfilter. |
| `web` | Core plus echo, set-misc, srcache, redis2, httpredis, vts, and ngx-devel-kit. |
| `security` | ModSecurity, ModSecurity-nginx, testcookie. |
| `observability` | vts. |
| `media` | rtmp. |
| `lua` | LuaJIT, ngx-devel-kit, lua-nginx, lua-resty-core, lua-resty-lrucache, set-misc. |
| `http3` | Legacy stack for nginx <= 1.24: quiche, tlsdyn, http3, hpack-http3. |
| `all` | Every active module except the TLS alternatives (`openssl`, `libressl`), PageSpeed, and the legacy HTTP/3 stack. |

- `--modules-extra` is only a preset that appends `headers-more,fancyindex,cachepurge,subfilter,webdav,vts,rtmp,testcookie,redis2,srcache,set-misc,echo,zstd,openssl`.
- `SSL=2`/`OPENSSL` appends `openssl`; `SSL=3`/`LIBRESSL` appends `libressl`; `SSL=1`/`SYSTEM` adds nothing.
- The old module flags (`BROTLI`, `HEADERMOD`, `LUA`, `GEOIP`, `VTS`, `REDIS2`, `ZSTD`, `HTTP3`, `TLSDYN`, `HPACK`, and the rest) no longer exist and select nothing.
- `MODULES_REV=latest` (default) uses the latest tested release; set a release tag to pin it. Third-party sources always come from the full `nginx-modules` release; `MODULES` selects what compiles.
- `BADBOT=y` is a separate addon and is not a module id.

## GeoIP credentials

`geoip2` downloads the GeoLite2 databases from MaxMind. Put the credentials in a mode-0600 env file instead of on the command line:

```bash
GEOIP2_ACCOUNT_ID=...
GEOIP2_LICENSE_KEY=...
```

```bash
./nginx_installer.sh --modules geoip2 --geoip-env-file "$HOME/.credentials/geoip.env"
# or: GEOIP_ENV_FILE="$HOME/.credentials/geoip.env" MODULES=geoip2 ./nginx_installer.sh
```

If `GEOIP_ENV_FILE` is unset, the installer also checks `$HOME/.credentials/geoip.env` automatically. Under `sudo` it checks the invoking user's home first (`$SUDO_USER`), then root's, so a file in your own home works without `-ge`.

`--geoip-account-id` and `--geoip-license-key` also exist, but a key passed in argv is visible in `ps`; prefer the env file or environment variables. The file is parsed, not sourced: only the two keys above are accepted.

## Related

- [Installation examples](../README.md#installation)
- [Compatibility](compatibility.md)
- [Troubleshooting](troubleshooting.md)

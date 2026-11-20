# nginx-installer

Automatic nginx install script.

[![GitHub release](https://img.shields.io/github/release/tmiland/nginx-installer.svg?style=for-the-badge)](https://github.com/tmiland/nginx-installer/releases) [![licence](https://img.shields.io/github/license/tmiland/nginx-installer.svg?style=for-the-badge)](https://github.com/tmiland/nginx-installer/blob/main/LICENSE) ![Bash](https://img.shields.io/badge/Language-SH-4EAA25.svg?style=for-the-badge)

## Installation

Run the installer as root. The examples use `sudo`; omit it if you are already root.

### Download the latest release

```bash
curl -fsSL https://github.com/tmiland/nginx-installer/releases/latest/download/nginx_installer.sh -o nginx_installer.sh
chmod +x nginx_installer.sh
```

The `main` branch is available for development, but is not the tested release:

```bash
curl -fsSL https://raw.githubusercontent.com/tmiland/nginx-installer/main/nginx_installer.sh -o nginx_installer.sh
chmod +x nginx_installer.sh
```

### Full module mainline install

Full built-in profile, the `all` third-party module set, GeoIP, and the bad bot blocker:

```bash
sudo ./nginx_installer.sh -m \
  --profile full \
  --modules "all" \
  --geoip-env-file "$HOME"/.credentials/geoip.env \
  --bad-bot \
  --dir /opt/nginx
```

`-m` selects the latest mainline nginx. `all` includes `geoip2`, so the GeoIP credentials file is required. Remove `--bad-bot` if you do not want the blocker.

### Minimal mainline install

The same `all` module set with the smaller built-in profile:

```bash
sudo ./nginx_installer.sh -m \
  --profile minimal \
  --modules "all" \
  --geoip-env-file "$HOME"/.credentials/geoip.env \
  --bad-bot \
  --dir /opt/nginx
```

The minimal profile builds TLS, HTTP/2, real IP, threads, file AIO, PCRE, and compatibility support only. It does not include native HTTP/3; `--profile full` adds that.

For nginx only, with no third-party modules:

```bash
sudo ./nginx_installer.sh -m --profile minimal
```

### Stable defaults

With no arguments, the installer builds the latest stable nginx with the minimal built-in profile and no third-party modules:

```bash
sudo ./nginx_installer.sh
```

### Install the script system-wide (optional)

```bash
sudo mkdir -p /opt/nginx-installer
sudo curl -fsSL https://github.com/tmiland/nginx-installer/releases/latest/download/nginx_installer.sh -o /opt/nginx-installer/nginx-installer.sh
sudo chmod +x /opt/nginx-installer/nginx-installer.sh
sudo ln -sf /opt/nginx-installer/nginx-installer.sh /usr/local/bin/nginx-installer
sudo nginx-installer
```

## Usage

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

`--headless` sets the `SSL=1`, `RM_CONF=n`, and `RM_LOGS=n` defaults. It does not select modules or make the installer fully non-interactive.

### Built-in module profile

`MODULES_PROFILE=minimal` (default) builds only TLS, HTTP/2, real IP, threads, file AIO, PCRE, and compatibility support. `MODULES_PROFILE=full` restores the previous broad set: Perl, XSLT, mail, stream, DAV, FLV/MP4, HTTP/3, stub status, and the other optional modules. `NGINX_MODULES` still overrides both.

### Module selection

Third-party modules are selected by id, not by per-module flags. The ids and their build steps live in `modules.conf` inside the verified [`tmiland/nginx-modules`](https://github.com/tmiland/nginx-modules) bundle; the bundle is the only module source. See that repository's README for the current id list.

- `MODULES="headers-more,fancyindex,..."` or `--modules|-M <ids|bundles>` selects modules. `requires` are resolved recursively, so `lua-nginx` pulls in `luajit2` and `ngx-devel-kit`.
- `--modules web` or `--modules "web,lua"` expands the curated bundle names from the release (`core`, `web`, `security`, `observability`, `media`, `lua`, `all`; `http3` is legacy for nginx <= 1.24). `all` selects every active third-party module except the TLS alternatives (`openssl`, `libressl`), PageSpeed, and the legacy HTTP/3 stack. nginx 1.25+ builds HTTP/3 natively via `--profile full`. Bundle names and explicit ids can be mixed.
- No `MODULES` means no bundle download and no third-party modules.
- `--modules-extra` is only a preset that appends `headers-more,fancyindex,cachepurge,subfilter,webdav,vts,rtmp,testcookie,redis2,srcache,set-misc,echo,zstd,openssl`.
- `SSL=2`/`OPENSSL` appends `openssl`; `SSL=3`/`LIBRESSL` appends `libressl`; `SSL=1`/`SYSTEM` adds nothing.
- The old module flags (`BROTLI`, `HEADERMOD`, `LUA`, `GEOIP`, `VTS`, `REDIS2`, `ZSTD`, `HTTP3`, `TLSDYN`, `HPACK`, and the rest) no longer exist and select nothing.
- `MODULES_REV=latest` (default) uses the latest tested release; set a release tag to pin it. Third-party sources always come from the full `nginx-modules` release; `MODULES` selects what compiles.
- `BADBOT=y` is a separate addon and is not a module id.

### GeoIP credentials

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

## Requirements

- Debian 9 or later, and Debian-family distributions including Ubuntu.
- Root access.
- Network access to nginx.org, GitHub, and the module sources.

CI builds and uninstalls nginx on Debian 12/13 and Ubuntu 22.04/24.04; Linux Mint 21.3 and LMDE 7 are checked for distro detection.

nginx source tarballs are PGP-verified against the pinned nginx.org signing keys. `src/slib.sh` and all third-party modules are pinned and checksum-verified.

## Verifying the build

```bash
nginx -V
```

The configure arguments show the selected profile and every `--add-module`. The module list is the authoritative record of what was compiled.

## Credits

- Code is mixed and customized from [nginx-autoinstall](https://github.com/angristan/nginx-autoinstall).

## Donations

<a href="https://coindrop.to/tmiland" target="_blank"><img src="https://coindrop.to/embed-button.png" style="border-radius: 10px; height: 57px !important;width: 229px !important;" alt="Coindrop.to me"></img></a>

## Disclaimer

***Use at own risk.***

## License

[MIT License](https://github.com/tmiland/nginx-installer/blob/main/LICENSE)

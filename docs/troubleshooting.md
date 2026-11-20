# Troubleshooting

Start with the installer log and nginx's own diagnostics:

```bash
sudo nginx -t
sudo nginx -V
sudo systemctl status nginx
sudo journalctl -u nginx -n 50 --no-pager
```

The installer log is `nginx_installer.log` next to the script.

## Common issues

| Symptom | Cause | Fix |
|---|---|---|
| `pkg-config not found` | Module dependencies were skipped on a rerun | Upgrade to v2.0.1+ or install the module dependencies manually |
| `Cannot prepare build directory: /opt/nginx` | `/opt` is a symlink and the path check rejected it | Upgrade to v2.0.1+ or pass `--dir "$(realpath -m /opt/nginx)"` |
| `ngx_http_lua_module 0.10.29 required` | `lua-resty-core` and `lua-nginx` versions do not match | Use `nginx-modules` v2026.11.6+ |
| `tlsdyn` patch `FAILED` | Old `nginx-modules` release with the 1.17.7 patch | Use `nginx-modules` v2026.11.5+ |
| `geoip2 requires GeoIP credentials` | `all` includes `geoip2` | Create the GeoIP env file |
| Build directory is not empty | It was not created by this installer | Remove it or choose another `--dir` |

## `pkg-config not found`

```text
checking for pkg-config... no
configure: error: pkg-config not found
```

v2.0.0 and earlier installed ModSecurity's dependencies only when the base packages were missing. On a rerun the base packages were already present, so `pkg-config` and the other module dependencies were skipped.

Upgrade to v2.0.1 or newer. To unblock an existing v2.0.0 install:

```bash
sudo apt-get install -y \
  apt-utils libcurl4-openssl-dev libgeoip-dev liblmdb-dev \
  libpcre++-dev libyajl-dev pkg-config
```

## `Cannot prepare build directory: /opt/nginx`

This happens when `/opt` is a symlink, for example `/opt -> /home/opt`. v2.0.0 compared the requested path with its resolved path and rejected the difference.

Upgrade to v2.0.1 or newer, or pass the resolved directory:

```bash
sudo ./nginx_installer.sh --dir "$(realpath -m /opt/nginx)"
```

## Lua runtime mismatch

```text
failed to load the 'resty.core' module
reason: ... ngx_http_lua_module 0.10.29 required
```

`lua-resty-core` 0.1.32 requires exactly `ngx_http_lua_module` 0.10.29, while the bundle builds 0.10.31. nginx-modules v2026.11.6 pins `lua-resty-core` 0.1.34rc3.

Use the latest module release, or pin the fixed one:

```bash
sudo ./nginx_installer.sh --modules "all" --modules-rev v2026.11.6
```

## `tlsdyn` patch fails

Old module releases used the nginx 1.17.7 dynamic TLS patch, which does not apply to nginx 1.30.7. nginx-modules v2026.11.5 uses the 1.29.2+ patch.

Remove an old `--modules-rev` pin or update it:

```bash
sudo ./nginx_installer.sh --modules "all" --modules-rev v2026.11.5
```

## HTTP/3 on nginx 1.25+

`quiche`, `http3`, and `hpack-http3` are the legacy third-party stack for nginx <= 1.24. nginx 1.25+ has native HTTP/3, enabled by `--profile full`. The `all` bundle excludes the legacy stack.

Do not select `http3` explicitly on a modern nginx. Use:

```bash
sudo ./nginx_installer.sh --profile full --modules "all"
```

## GeoIP credentials

`all` includes `geoip2`, so it needs MaxMind credentials. Create `~/.credentials/geoip.env` with mode 0600:

```bash
mkdir -p "$HOME/.credentials"
chmod 700 "$HOME/.credentials"
printf 'GEOIP2_ACCOUNT_ID=%s\nGEOIP2_LICENSE_KEY=%s\n' "$ACCOUNT_ID" "$LICENSE_KEY" > "$HOME/.credentials/geoip.env"
chmod 600 "$HOME/.credentials/geoip.env"
```

Under `sudo`, the installer checks `$SUDO_USER`'s home before root's. To use a different file, pass `--geoip-env-file`.

## Build directory is not empty

```text
Build directory /opt/nginx is not empty and was not created by this installer.
```

Remove the directory manually if it is yours, or choose another build directory:

```bash
sudo ./nginx_installer.sh --dir /opt/nginx-build
```

## `unknown directive "lua_package_path"`

A previous install left `conf.d/lua_package_path.conf` behind. v2.0.0+ removes the installer-generated file when Lua is not selected. If an edited file remains, remove it or reinstall with the current release.

## nginx passes `nginx -t` but will not start

`nginx -t` does not execute `init_by_lua`, so a Lua runtime mismatch can appear only when the service starts. Check:

```bash
sudo systemctl status nginx
sudo journalctl -u nginx -n 50 --no-pager
sudo tail -n 50 /var/log/nginx/error.log
```

If the log mentions `resty.core`, see the Lua section above.

## Related

- [Usage reference](usage.md)
- [Compatibility](compatibility.md)
- [How it works](how-it-works.md)

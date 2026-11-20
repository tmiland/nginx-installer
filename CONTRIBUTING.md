# Contributing

Thanks for taking the time to improve the installer.

## Scope

This repository contains the installer, its tests, and CI. Third-party module sources, pins, bundles, and the source release live in [`tmiland/nginx-modules`](https://github.com/tmiland/nginx-modules).

## Development

Work on a branch and keep changes focused:

```bash
git switch -c fix/short-description
```

Run the local checks before opening a pull request:

```bash
bash tests/test_installer.sh
shellcheck -x nginx_installer.sh tests/test_installer.sh
```

`actionlint` checks the GitHub workflows:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest
```

## Tests

The test suite sources `nginx_installer.sh` with `NGINX_INSTALLER_LIB_ONLY=1`, so it does not install anything. It covers option parsing, module resolution, checksum helpers, build-directory safety, and the GeoIP parser.

If you fix a bug, add a regression test. If a test needs root or network access, keep it in CI rather than the unit suite.

## CI

- `.github/workflows/tests.yml` runs shellcheck, the unit suite, and the pinned `src/slib.sh` check.
- `.github/workflows/test-install.yml` builds and uninstalls nginx on Debian 12/13 and Ubuntu 22.04/24.04, and runs the minimal/full module jobs on Debian 13.

The module jobs start nginx after installation; `nginx -t` alone does not execute `init_by_lua`, so a runtime Lua mismatch would otherwise pass unnoticed.

## Module changes

Do not add module source trees here. Change the `.mod` files or bundles in `tmiland/nginx-modules`, then:

1. Run `python3 scripts/build_catalog.py`.
2. Build the release bundle and tag a new `nginx-modules` release.
3. Update the installer CI pin and any documentation that names the release.
4. Run the installer module jobs before merging.

`--modules-rev` pins the module release; `latest` follows the newest tested release.

## Releases

Maintainers release the installer with:

1. Update `VERSION` in `nginx_installer.sh`.
2. Run the unit suite and shellcheck.
3. Tag `vX.Y.Z` on `main`.
4. Publish a GitHub release with `nginx_installer.sh` as the asset.

The release asset is the script; `src/slib.sh` is downloaded and verified from the pinned revision at runtime.

## Secrets and logs

Never commit:

- `nginx_installer.log`
- `~/.credentials/geoip.env`
- MaxMind keys, tokens, certificates, or private hostnames
- test fixtures containing real credentials

Use dummy values in tests and examples. A GeoIP credentials file must remain mode 0600.

## Pull requests

Describe the failure or the behavior being changed, include the commands you ran, and mention the affected platforms. Keep unrelated formatting or refactoring out of a bug-fix pull request.

By contributing, you agree that your changes are licensed under the repository's MIT license.

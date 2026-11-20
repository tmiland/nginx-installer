# Compatibility

## Tested platforms

CI coverage at the time of writing:

| Platform | Detection | Build and uninstall | Third-party modules |
|---|---|---|---|
| Debian 12 (bookworm) | yes | yes | - |
| Debian 13 (trixie) | yes | yes | yes (minimal and full profiles) |
| Ubuntu 22.04 (jammy) | yes | yes | - |
| Ubuntu 24.04 (noble) | yes | yes | - |
| Linux Mint 21.3 | yes | detection only | - |
| LMDE 7 | yes | detection only | - |

Debian 9 and later is the intended range; the current CI matrix covers Debian 12/13. Ubuntu is handled through the Debian family.

## nginx versions

The installer follows nginx.org's stable and mainline channels. `--stable` and `--mainline` resolve the current version; `--nginx X.Y.Z` pins an exact version.

- Stable 1.30.7 is covered by the install CI.
- Mainline 1.31.9 was verified with the full module set.

## Requirements

- Root access.
- A Debian-family system with `apt`.
- Network access to nginx.org, GitHub, and the module sources.
- Enough disk space and RAM to compile nginx and the selected third-party modules.

## Verification

- nginx source tarballs are PGP-verified against the pinned nginx.org signing keys.
- `src/slib.sh` is pinned to a revision and verified by SHA-256 before it is sourced.
- The `nginx-modules` bundle is downloaded by release tag and verified against `SHA256SUMS`.
- Third-party sources are pinned to commits, releases, or checksums in the module manifest.
- GeoIP credentials are parsed from an env file and never written to the installer log.

## Related

- [Usage reference](usage.md)
- [How it works](how-it-works.md)
- [Troubleshooting](troubleshooting.md)

#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2317
# Unit tests for nginx_installer.sh. No install is performed: the script is
# sourced with NGINX_INSTALLER_LIB_ONLY=1, which returns after option parsing.

set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nginx-installer-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }

assert_eq() {
  local expected=$1 actual=$2 msg=$3
  if [[ $actual == "$expected" ]]; then
    pass "$msg"
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ $haystack == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (missing '$needle')"
  fi
}

assert_ok() {
  local msg=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

assert_not_ok() {
  local msg=$1; shift
  if "$@" >/dev/null 2>&1; then fail "$msg"; else pass "$msg"; fi
}

assert_status() {
  local expected=$1 msg=$2; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq $expected ]]; then
    pass "$msg"
  else
    fail "$msg (expected status $expected, got $rc)"
  fi
}

assert_function() {
  if declare -F "$1" >/dev/null 2>&1; then
    pass "defines $1"
  else
    fail "defines $1"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: a stand-in for nginx.org's download page (single line, like the
# real minified page) and a temporary install/build root.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/etc/nginx"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '<div><h4>Stable version</h4><table><tr><td><a href="/download/nginx-1.30.7.tar.gz">nginx-1.30.7</a></td></tr></table></div><div><h4>Mainline version</h4><table><tr><td><a href="/download/nginx-1.31.9.tar.gz">nginx-1.31.9</a></td></tr></table></div>'
STUB
chmod +x "$WORK/bin/curl"

# slib registers a terminal-cleanup trap; keep test output clean.
cat > "$WORK/bin/tput" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  colors) printf '256\n' ;;
  cols) printf '80\n' ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/tput"

export PATH="$WORK/bin:$PATH"
export INSTALL_DIR="$WORK/etc/nginx"
export TEMP_INSTALL_DIR="$WORK/build"
export LOGFILE="$WORK/nginx_installer.log"
export NGINX_INSTALLER_LIB_ONLY=1

cd "$ROOT" || exit 1
# shellcheck source=/dev/null
source ./nginx_installer.sh >/dev/null
# slib replaces the EXIT trap; restore the test cleanup.
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Helpers must exist before behaviour is meaningful.
# ---------------------------------------------------------------------------
assert_function validate_build_dir
assert_function prepare_build_dir
assert_function validate_install_dir
assert_function nginx_source_version
assert_function detect_distro
assert_function verify_sha256
assert_function download_verified
assert_function load_slib
assert_function fetch_nginx_source
assert_function normalize_module_ids
assert_function load_modules_manifest
assert_function resolve_modules
assert_function module_build_args
assert_function load_geoip_env_file
assert_function geoip_default_env_file
assert_function run_module_handler
assert_function apply_module_patches
assert_function modules_bundle_url
assert_function fetch_modules_bundle

# ---------------------------------------------------------------------------
# Pinned dependencies and checksum helpers.
# ---------------------------------------------------------------------------
assert_eq "$(sha256sum src/slib.sh | awk '{print $1}')" "${SLIB_SHA256:-}" "SLIB_SHA256 pins the vendored slib"
if [[ ${SLIB_REV:-} =~ ^[0-9a-f]{40}$ ]]; then
  pass "SLIB_REV is a full commit SHA"
else
  fail "SLIB_REV is a full commit SHA"
fi
assert_contains "${SLIB_URL:-}" "/${SLIB_REV:-missing}/" "SLIB_URL uses the pinned revision"

# The release asset has no src/slib.sh; it must download and verify the pinned
# copy. This uses the real curl, not the test stub.
standalone="$WORK/standalone"
mkdir -p "$standalone"
cp nginx_installer.sh "$standalone/"
standalone_out=$(
  (
    export PATH=${PATH#"$WORK/bin:"}
    unset NGINX_INSTALLER_LIB_ONLY
    export SLIB_URL="file://$ROOT/src/slib.sh"
    export LOGFILE="$WORK/standalone.log"
    bash "$standalone/nginx_installer.sh" --detect
  ) 2>/dev/null
)
assert_contains "$standalone_out" "DISTRO_GROUP=Debian" "standalone release path verifies the pinned slib"

# ---------------------------------------------------------------------------
# Module bundle fetch and manifest parsing (file:// fixture, no network).
# ---------------------------------------------------------------------------
bundle_root="$WORK/fakebundle"
mkdir -p "$bundle_root/full/modules"/{headers-more-nginx-module-0.42,luajit2-2.1-20261117,ngx_devel_kit-0.3.4,lua-nginx-module-0.10.31,ngx_http_geoip2_module-3.4,libmaxminddb-1.14.1,set-misc-nginx-module,zstd-nginx-module,patches}
cat > "$bundle_root/full/modules.conf" <<'EOF'
# id|dir|kind|build|requires|env
headers-more|headers-more-nginx-module-0.42|archive|--add-module={dir}||HEADERMOD
luajit2|luajit2-2.1-20261117|archive|||LUA
ngx-devel-kit|ngx_devel_kit-0.3.4|archive|--add-module={dir}||LUA
lua-nginx|lua-nginx-module-0.10.31|archive|--add-module={dir}|luajit2,ngx-devel-kit|LUA
geoip2|ngx_http_geoip2_module-3.4|archive|--add-module={dir}|libmaxminddb|GEOIP
libmaxminddb|libmaxminddb-1.14.1|archive|||GEOIP
set-misc|set-misc-nginx-module|git|--add-module={dir}|ngx-devel-kit|SETMISC
zstd|zstd-nginx-module|archive|--add-module={dir}||ZSTD
tlsdyn|patches/tlsdyn.patch|file|||TLSDYN
EOF
cat > "$bundle_root/full/bundles.conf" <<'EOF'
# bundle|comma-separated module ids
web|headers-more,zstd
all|headers-more,zstd
lua|lua-nginx,set-misc
EOF
tar -czf "$WORK/nginx-modules-full.tar.gz" -C "$bundle_root" full
( cd "$WORK" && sha256sum nginx-modules-full.tar.gz > SHA256SUMS )

bundle_result=$(
  export TEMP_INSTALL_DIR="$WORK/bundle-extract"
  mkdir -p "$TEMP_INSTALL_DIR"
  export PATH=${PATH#"$WORK/bin:"}
  export MODULES_BUNDLE_URL="file://$WORK/nginx-modules-full.tar.gz"
  export MODULES_SUMS_URL="file://$WORK/SHA256SUMS"
  fetch_modules_bundle >/dev/null 2>&1 || exit 1
  load_modules_manifest || exit 1
  printf '%s' "${MODULE_DIR[headers-more]}"
)
assert_eq "headers-more-nginx-module-0.42" "$bundle_result" "parses modules.conf from the bundle"
if [[ -d "$WORK/bundle-extract/modules/headers-more-nginx-module-0.42" && -f "$WORK/bundle-extract/modules.conf" && -f "$WORK/bundle-extract/bundles.conf" ]]; then
  pass "extracts the module tree and manifests from the bundle"
else
  fail "extracts the module tree and manifests from the bundle"
fi

# Load the extracted fixture manifest in a subshell and inspect the result.
manifest_resolved() {
  (
    export TEMP_INSTALL_DIR="$WORK/bundle-extract"
    load_modules_manifest || exit 1
    load_bundles_manifest || exit 1
    resolve_modules "$@" || exit 1
    printf '%s' "${RESOLVED_MODULES[*]}"
  )
}
manifest_args() {
  (
    export TEMP_INSTALL_DIR="$WORK/bundle-extract"
    load_modules_manifest || exit 1
    module_build_args "$1"
  )
}

assert_eq "--add-module=$WORK/bundle-extract/modules/headers-more-nginx-module-0.42" \
  "$(manifest_args headers-more)" \
  "maps a manifest build template to the extracted module dir"
if (
  export TEMP_INSTALL_DIR="$WORK/bundle-extract"
  load_modules_manifest || exit 1
  load_bundles_manifest || exit 1
  resolve_modules tlsdyn || exit 1
  NGINX_MODULES=
  append_module_build_args
) >/dev/null 2>&1; then
  pass "appends build args when the last module has none"
else
  fail "appends build args when the last module has none"
fi
assert_eq "luajit2 ngx-devel-kit lua-nginx" \
  "$(manifest_resolved lua-nginx)" \
  "resolves requires recursively, dependencies first"
assert_eq "libmaxminddb geoip2" \
  "$(manifest_resolved geoip2)" \
  "resolves the geoip2 library dependency"
assert_eq "headers-more zstd" \
  "$(manifest_resolved web)" \
  "expands a bundle name"
assert_eq "headers-more zstd" \
  "$(manifest_resolved all)" \
  "expands the all bundle"
assert_eq "luajit2 ngx-devel-kit lua-nginx set-misc" \
  "$(manifest_resolved lua)" \
  "expands a bundle and its dependencies"
assert_eq "" \
  "$(manifest_args libmaxminddb)" \
  "library modules have no configure arguments"
if ( manifest_resolved not-a-module ) >/dev/null 2>&1; then
  fail "rejects an unknown module id"
else
  pass "rejects an unknown module id"
fi
mkdir -p "$WORK/bad-manifest"
printf 'Bad Id|dir|archive|--add-module={dir}||\n' > "$WORK/bad-manifest/modules.conf"
if ( export TEMP_INSTALL_DIR="$WORK/bad-manifest"; load_modules_manifest ) >/dev/null 2>&1; then
  fail "rejects an invalid modules.conf id"
else
  pass "rejects an invalid modules.conf id"
fi

# The whole selection path: fetch, parse, resolve requires, append build args.
selected_args=$(
  export TEMP_INSTALL_DIR="$WORK/download-run"
  mkdir -p "$TEMP_INSTALL_DIR"
  export PATH=${PATH#"$WORK/bin:"}
  export MODULES_BUNDLE_URL="file://$WORK/nginx-modules-full.tar.gz"
  export MODULES_SUMS_URL="file://$WORK/SHA256SUMS"
  export MODULES=set-misc
  # shellcheck source=/dev/null
  source ./nginx_installer.sh >/dev/null 2>&1
  download_modules >/dev/null 2>&1 || exit 1
  printf '%s' "$NGINX_MODULES"
)
assert_contains "$selected_args" "--add-module=$WORK/download-run/modules/set-misc-nginx-module" "download_modules appends manifest build args"
assert_contains "$selected_args" "--add-module=$WORK/download-run/modules/ngx_devel_kit-0.3.4" "download_modules appends required module args"

# No MODULES means no bundle download and no third-party modules.
if (
  export MODULES=
  export TEMP_INSTALL_DIR="$WORK/no-module-run"
  mkdir -p "$TEMP_INSTALL_DIR"
  export PATH=${PATH#"$WORK/bin:"}
  export MODULES_BUNDLE_URL="file://$WORK/missing.tar.gz"
  export MODULES_SUMS_URL="file://$WORK/missing.sums"
  # shellcheck source=/dev/null
  source ./nginx_installer.sh >/dev/null 2>&1
  download_modules >/dev/null 2>&1
) && [[ ! -d "$WORK/no-module-run/modules" ]]; then
  pass "does not fetch the bundle without MODULES"
else
  fail "does not fetch the bundle without MODULES"
fi

# Selected modules require the verified bundle; there is no upstream fallback.
if (
  export MODULES=headers-more
  export TEMP_INSTALL_DIR="$WORK/no-bundle-run"
  mkdir -p "$TEMP_INSTALL_DIR"
  export PATH=${PATH#"$WORK/bin:"}
  export MODULES_BUNDLE_URL="file://$WORK/missing.tar.gz"
  export MODULES_SUMS_URL="file://$WORK/missing.sums"
  # shellcheck source=/dev/null
  source ./nginx_installer.sh >/dev/null 2>&1
  download_modules
) >/dev/null 2>&1; then
  fail "fails when a selected module has no bundle"
else
  pass "fails when a selected module has no bundle"
fi

assert_contains "$(modules_bundle_url)" "/tmiland/nginx-modules/releases/latest/download/nginx-modules-full.tar.gz" "defaults to the latest full bundle"
if (
  export TEMP_INSTALL_DIR="$WORK/no-bundle"
  mkdir -p "$TEMP_INSTALL_DIR"
  export MODULES_BUNDLE_URL="file://$WORK/missing.tar.gz"
  export MODULES_SUMS_URL="file://$WORK/missing.sums"
  fetch_modules_bundle
) >/dev/null 2>&1; then
  fail "fails when the bundle is missing"
else
  pass "fails when the bundle is missing"
fi


if [[ ${BADBOT_REV:-} =~ ^[0-9a-f]{40}$ ]]; then
  pass "BADBOT_REV is a commit SHA"
else
  fail "BADBOT_REV is a commit SHA"
fi
for var in SLIB_SHA256 BADBOT_SHA256 RUSTUP_X86_64_SHA256 RUSTUP_AARCH64_SHA256; do
  value=${!var:-}
  if [[ $value =~ ^[0-9a-f]{64}$ ]]; then
    pass "$var is a sha256"
  else
    fail "$var is a sha256"
  fi
done

assert_eq "5" "$(printf '%s\n' "${NGINX_SIGNING_KEY_IDS:-}" | wc -w)" "pins five nginx signing keys"
assert_contains "${NGINX_SIGNING_KEY_IDS:-}" "D6786CE303D9A9022998DC6CC8464D549AF75C0A" "includes the 1.30 release signer"
if [[ ${RUSTUP_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "RUSTUP_VERSION is pinned"
else
  fail "RUSTUP_VERSION is pinned"
fi

printf 'pinned\n' > "$WORK/checksum"
sum=$(sha256sum "$WORK/checksum" | awk '{print $1}')
assert_ok "verify_sha256 accepts a matching file" verify_sha256 "$WORK/checksum" "$sum"
assert_not_ok "verify_sha256 rejects a mismatch" verify_sha256 "$WORK/checksum" "0000000000000000000000000000000000000000000000000000000000000000"

if grep -qE '(^|[^#])\becho[[:space:]]+\$GEOIP2_URL' nginx_installer.sh; then
  fail "does not echo the GeoIP download URL"
else
  pass "does not echo the GeoIP download URL"
fi
if grep -q 'curl -sSL https://github.com' README.md; then
  fail "README uses curl -fsSL"
else
  pass "README uses curl -fsSL"
fi
if grep -q '^  ./configure ' nginx_installer.sh; then
  pass "uses the release tarball configure script"
else
  fail "uses the release tarball configure script"
fi


# ---------------------------------------------------------------------------
# Version detection.
# ---------------------------------------------------------------------------
assert_eq "1.30.7" "$(latest_nginx Stable)" "latest_nginx parses the stable version"
assert_eq "1.31.9" "$(latest_nginx Mainline)" "latest_nginx parses the mainline version"

# ---------------------------------------------------------------------------
# Option parsing.
# ---------------------------------------------------------------------------
source_get() {
  local var=$1; shift
  (
    # shellcheck source=/dev/null
    source ./nginx_installer.sh "$@" >/dev/null
    printf '%s' "${!var}"
  )
}

assert_eq "stable" "$(source_get NGINX_VER_NAME --stable)" "--stable selects the stable channel"
assert_eq "stable" "$(source_get NGINX_VER_NAME)" "the default is the stable channel"
assert_eq "mainline" "$(source_get NGINX_VER_NAME --mainline)" "--mainline selects the mainline channel"
assert_eq "1.30.7" "$(source_get NGINX_VER --nginx 1.30.7)" "--nginx takes an explicit version"
assert_eq "1" "$(source_get DETECT_ONLY --detect)" "--detect is parsed"
assert_eq "full" "$(source_get MODULES_PROFILE --profile full)" "--profile sets the built-in profile"
if ( source ./nginx_installer.sh --modules-bundle web >/dev/null 2>&1 ); then
  fail "rejects the removed --modules-bundle option"
else
  pass "rejects the removed --modules-bundle option"
fi
assert_eq "v2026.11.2" "$(source_get MODULES_REV --modules-rev v2026.11.2)" "--modules-rev sets the release"
assert_eq "y" "$(source_get MODULES_EXTRA --modules-extra)" "--modules-extra is parsed"
assert_eq "minimal" "$(source_get MODULES_PROFILE --modules-extra)" "--modules-extra does not change the profile"
assert_eq "full" "$(source_get MODULES_PROFILE --modules-extra --profile full)" "--modules-extra composes with --profile"
if ( source ./nginx_installer.sh --profile balanced >/dev/null 2>&1 ); then
  fail "rejects an invalid --profile"
else
  pass "rejects an invalid --profile"
fi

# Module selection by id. The old module flags no longer exist.
assert_eq "headers-more zstd" "$(source_get MODULES_LIST --modules headers-more,zstd)" "--modules takes comma separated ids"
assert_eq "web" "$(source_get MODULES_LIST --modules web)" "--modules accepts a bundle name"
assert_eq "headers-more zstd" "$(source_get MODULES_LIST -M "headers-more zstd")" "-M takes space separated ids"
assert_eq "headers-more" "$(source_get MODULES_LIST --modules headers-more -M headers-more)" "--modules dedupes repeated ids"
assert_eq "headers-more zstd" "$(MODULES='headers-more zstd' source_get MODULES_LIST)" "MODULES env selects ids"
assert_eq "openssl" "$(SSL=2 source_get MODULES_LIST)" "SSL=2 appends openssl"
assert_eq "libressl" "$(SSL=3 source_get MODULES_LIST)" "SSL=3 appends libressl"
assert_eq "" "$(SSL=1 source_get MODULES_LIST)" "SSL=1 adds no TLS module"
assert_eq "" "$(BROTLI=y LUA=y GEOIP=y MODSEC=y source_get MODULES_LIST)" "old module flags no longer select modules"
assert_eq "headers-more fancyindex cachepurge subfilter webdav vts rtmp testcookie redis2 srcache set-misc echo zstd openssl" \
  "$(source_get MODULES_LIST --modules-extra)" "--modules-extra appends the preset ids"
assert_eq "zstd headers-more fancyindex cachepurge subfilter webdav vts rtmp testcookie redis2 srcache set-misc echo openssl" \
  "$(source_get MODULES_LIST --modules zstd --modules-extra)" "--modules-extra composes with --modules"
if ( source ./nginx_installer.sh --modules >/dev/null 2>&1 ); then
  fail "rejects --modules without a value"
else
  pass "rejects --modules without a value"
fi

# GeoIP credentials: CLI parsing and env-file parsing without sourcing.
mkdir -p "$WORK/credentials"
cat > "$WORK/credentials/geoip.env" <<'EOF'
# MaxMind credentials
GEOIP2_ACCOUNT_ID=123456
GEOIP2_LICENSE_KEY="fake-license-key"
EOF
assert_eq "$WORK/credentials/geoip.env" "$(source_get GEOIP_ENV_FILE --geoip-env-file "$WORK/credentials/geoip.env")" "--geoip-env-file is parsed"
assert_eq "123456" "$(source_get GEOIP2_ACCOUNT_ID --geoip-account-id 123456)" "--geoip-account-id is parsed"
assert_eq "fake" "$(source_get GEOIP2_LICENSE_KEY --geoip-license-key fake)" "--geoip-license-key is parsed"
assert_eq "$WORK/credentials/geoip.env" "$(source_get GEOIP_ENV_FILE -ge "$WORK/credentials/geoip.env")" "-ge is parsed"
assert_eq "123456" "$(source_get GEOIP2_ACCOUNT_ID -ga 123456)" "-ga is parsed"
assert_eq "fake" "$(source_get GEOIP2_LICENSE_KEY -gk fake)" "-gk is parsed"
assert_eq "123456|fake-license-key" \
  "$( ( load_geoip_env_file "$WORK/credentials/geoip.env"; printf '%s|%s' "$GEOIP2_ACCOUNT_ID" "$GEOIP2_LICENSE_KEY" ) )" \
  "loads GeoIP credentials and strips quotes"
printf 'GEOIP2_ACCOUNT_ID=42\r\nGEOIP2_LICENSE_KEY=line-key\r\n' > "$WORK/credentials/geoip-crlf.env"
assert_eq "42|line-key" \
  "$( ( load_geoip_env_file "$WORK/credentials/geoip-crlf.env"; printf '%s|%s' "$GEOIP2_ACCOUNT_ID" "$GEOIP2_LICENSE_KEY" ) )" \
  "strips CR from GeoIP env files"
cat > "$WORK/credentials/geoip-bad.env" <<'EOF'
GEOIP2_ACCOUNT_ID=1
GEOIP2_SECRET=not-allowed
EOF
if ( load_geoip_env_file "$WORK/credentials/geoip-bad.env" ) >/dev/null 2>&1; then
  fail "rejects unknown GeoIP env keys"
else
  pass "rejects unknown GeoIP env keys"
fi
if ( HOME="$WORK/no-geoip-home" GEOIP_ENV_FILE='' GEOIP2_LICENSE_KEY=''; prepare_geoip_credentials ) >/dev/null 2>&1; then
  fail "rejects a missing GeoIP license key"
else
  pass "rejects a missing GeoIP license key"
fi
mkdir -p "$WORK/geoip-home/.credentials"
cp "$WORK/credentials/geoip.env" "$WORK/geoip-home/.credentials/geoip.env"
assert_eq "123456|fake-license-key" \
  "$( (
    export HOME="$WORK/geoip-home"
    GEOIP_ENV_FILE='' GEOIP2_ACCOUNT_ID='' GEOIP2_LICENSE_KEY=''
    prepare_geoip_credentials >/dev/null 2>&1
    printf '%s|%s' "$GEOIP2_ACCOUNT_ID" "$GEOIP2_LICENSE_KEY"
  ) )" \
  "loads the default HOME GeoIP env file"
mkdir -p "$WORK/sudo-home/.credentials" "$WORK/root-home" "$WORK/bin"
cp "$WORK/credentials/geoip.env" "$WORK/sudo-home/.credentials/geoip.env"
cat > "$WORK/bin/getent" <<EOF
#!/bin/sh
if [ "\$1" = passwd ] && [ "\$2" = fakeuser ]; then
  printf '%s\n' 'fakeuser:x:1000:1000::$WORK/sudo-home:/bin/bash'
  exit 0
fi
exit 2
EOF
chmod +x "$WORK/bin/getent"
assert_eq "123456|fake-license-key" \
  "$( (
    export PATH="$WORK/bin:$PATH"
    export HOME="$WORK/root-home" SUDO_USER=fakeuser
    GEOIP_ENV_FILE='' GEOIP2_ACCOUNT_ID='' GEOIP2_LICENSE_KEY=''
    prepare_geoip_credentials >/dev/null 2>&1
    printf '%s|%s' "$GEOIP2_ACCOUNT_ID" "$GEOIP2_LICENSE_KEY"
  ) )" \
  "checks the sudo user's home for the GeoIP env file"
if ( GEOIP_ENV_FILE="$WORK/credentials/geoip.env" GEOIP2_LICENSE_KEY=''; prepare_geoip_credentials ) >/dev/null 2>&1; then
  pass "loads GeoIP credentials from the env file"
else
  fail "loads GeoIP credentials from the env file"
fi
if ( GEOIP_ENV_FILE='' GEOIP2_LICENSE_KEY=fake; prepare_geoip_credentials ) >/dev/null 2>&1; then
  pass "accepts a GeoIP license key from the environment"
else
  fail "accepts a GeoIP license key from the environment"
fi

profile_modules() {
  local profile=$1
  (
    export MODULES_PROFILE="$profile"
    unset NGINX_MODULES
    # shellcheck source=/dev/null
    source ./nginx_installer.sh >/dev/null
    printf '%s' "$NGINX_MODULES"
  )
}
assert_contains "$(profile_modules minimal)" "--with-http_ssl_module" "minimal profile keeps TLS"
assert_contains "$(profile_modules minimal)" "--with-http_v2_module" "minimal profile keeps HTTP/2"
if [[ $(profile_modules minimal) == *"--with-http_perl_module"* ]]; then
  fail "minimal profile excludes Perl"
else
  pass "minimal profile excludes Perl"
fi
if [[ $( (unset MODULES_PROFILE NGINX_MODULES; source ./nginx_installer.sh >/dev/null; printf '%s' "$NGINX_MODULES") ) == *"--with-http_perl_module"* ]]; then
  fail "the default profile is minimal"
else
  pass "the default profile is minimal"
fi
assert_contains "$(profile_modules full)" "--with-http_perl_module" "full profile keeps Perl"
assert_contains "$(profile_modules full)" "--with-stream" "full profile keeps stream"
if ( MODULES_PROFILE=bogus; source ./nginx_installer.sh >/dev/null 2>&1 ); then
  fail "rejects an unknown MODULES_PROFILE"
else
  pass "rejects an unknown MODULES_PROFILE"
fi

same_version_reinstall() {
  ( CURRENT_VER=1.30.7; NGINX_VER=1.30.7; chk_nginx )
}
assert_ok "allows an explicit reinstall of the same nginx version" same_version_reinstall

if ( source ./nginx_installer.sh --nginx 1.30 >/dev/null 2>&1 ); then
  fail "rejects a two-part --nginx version"
else
  pass "rejects a two-part --nginx version"
fi
if ( source ./nginx_installer.sh --nginx >/dev/null 2>&1 ); then
  fail "rejects --nginx without a value"
else
  pass "rejects --nginx without a value"
fi
if ( source ./nginx_installer.sh --nproc nope >/dev/null 2>&1 ); then
  fail "rejects a non-numeric --nproc"
else
  pass "rejects a non-numeric --nproc"
fi

usage_out=$(usage)
assert_contains "$usage_out" "|-hl" "usage documents -hl for headless"
assert_contains "$usage_out" "--bad-bot" "usage documents --bad-bot"
assert_contains "$usage_out" "--detect" "usage documents --detect"
assert_contains "$usage_out" "--profile" "usage documents --profile"
assert_contains "$usage_out" "--modules" "usage documents --modules"
assert_contains "$usage_out" "--geoip-env-file" "usage documents --geoip-env-file"
assert_contains "$usage_out" "temporary build directory" "usage describes the build directory simply"
if [[ $usage_out == *"(under /opt"* ]]; then
  fail "usage omits the build directory allowlist"
else
  pass "usage omits the build directory allowlist"
fi

# ---------------------------------------------------------------------------
# Distro detection (fixtures, so no container is needed).
# ---------------------------------------------------------------------------
make_distro_fixture() {
  local dir=$1 issue=$2
  mkdir -p "$dir/etc"
  : > "$dir/etc/debian_version"
  printf '%s\n' "$issue" > "$dir/etc/issue.net"
}

mint="$WORK/distro-mint"
make_distro_fixture "$mint" 'Linux Mint 21.3 Virginia'
assert_eq "Debian" "$( (detect_distro "$mint"; printf '%s' "$DISTRO_GROUP") )" "detects Linux Mint"
assert_eq "Linux Mint 21.3 Virginia" "$( (detect_distro "$mint"; printf '%s' "$DISTRO") )" "reads the Mint issue string"

lmde="$WORK/distro-lmde"
make_distro_fixture "$lmde" 'LMDE 7 Gigi'
assert_eq "Debian" "$( (detect_distro "$lmde"; printf '%s' "$DISTRO_GROUP") )" "detects LMDE"

debian="$WORK/distro-debian"
make_distro_fixture "$debian" 'Debian GNU/Linux 13 (trixie)'
assert_eq "Debian" "$( (detect_distro "$debian"; printf '%s' "$DISTRO_GROUP") )" "detects Debian"

ubuntu="$WORK/distro-ubuntu"
make_distro_fixture "$ubuntu" 'Ubuntu 24.04.3 LTS'
assert_eq "Debian" "$( (detect_distro "$ubuntu"; printf '%s' "$DISTRO_GROUP") )" "detects Ubuntu"

fedora="$WORK/distro-fedora"
mkdir -p "$fedora/etc"
printf '%s\n' 'Fedora Linux 44 (Forty Four)' > "$fedora/etc/redhat-release"
assert_not_ok "rejects an unsupported distro" detect_distro "$fedora"

unknown="$WORK/distro-unknown"
mkdir -p "$unknown/etc"
assert_not_ok "rejects an unknown distro" detect_distro "$unknown"

# os-release is the reliable source when /etc/issue.net is empty.
mint_os="$WORK/distro-mint-osrelease"
mkdir -p "$mint_os/etc"
: > "$mint_os/etc/debian_version"
: > "$mint_os/etc/issue.net"
cat > "$mint_os/etc/os-release" <<'EOF'
ID=linuxmint
ID_LIKE="ubuntu debian"
PRETTY_NAME="Linux Mint 21.3"
EOF
assert_eq "Debian" "$( (detect_distro "$mint_os"; printf '%s' "$DISTRO_GROUP") )" "detects Mint from os-release when issue.net is empty"

lmde_os="$WORK/distro-lmde-osrelease"
mkdir -p "$lmde_os/etc"
: > "$lmde_os/etc/debian_version"
: > "$lmde_os/etc/issue.net"
cat > "$lmde_os/etc/os-release" <<'EOF'
ID=lmde
ID_LIKE="debian"
PRETTY_NAME="LMDE 7"
EOF
assert_eq "Debian" "$( (detect_distro "$lmde_os"; printf '%s' "$DISTRO_GROUP") )" "detects LMDE from os-release when issue.net is empty"



# ---------------------------------------------------------------------------
# Build directory safety.
# ---------------------------------------------------------------------------
assert_ok "accepts the default build directory" validate_build_dir /opt/nginx
assert_ok "accepts a directory under /tmp" validate_build_dir "$WORK/fresh"
assert_not_ok "rejects /" validate_build_dir /
assert_not_ok "rejects /etc" validate_build_dir /etc
assert_not_ok "rejects /etc/nginx" validate_build_dir /etc/nginx
assert_not_ok "rejects /opt itself" validate_build_dir /opt
assert_not_ok "rejects a relative path" validate_build_dir relative/path
assert_not_ok "rejects a trailing slash" validate_build_dir /opt/nginx/
assert_not_ok "rejects path traversal" validate_build_dir /opt/../etc

assert_ok "accepts /etc/nginx as an install dir" validate_install_dir /etc/nginx
assert_not_ok "rejects /etc as an install dir" validate_install_dir /etc
assert_not_ok "rejects / as an install dir" validate_install_dir /

assert_ok "creates a fresh build directory" prepare_build_dir "$WORK/fresh"
if [[ -f "$WORK/fresh/.nginx-installer" ]]; then
  pass "marks a build directory it created"
else
  fail "marks a build directory it created"
fi

mkdir -p "$WORK/user-dir"
printf 'keep me\n' > "$WORK/user-dir/keep"
assert_status 2 "refuses a non-empty unmarked build directory" prepare_build_dir "$WORK/user-dir"
assert_eq "keep me" "$(cat "$WORK/user-dir/keep" 2>/dev/null)" "leaves an unmarked directory untouched"

mkdir -p "$WORK/marked"
printf 'old\n' > "$WORK/marked/old"
: > "$WORK/marked/.nginx-installer"
assert_ok "reuses a marked build directory" prepare_build_dir "$WORK/marked"
if [[ ! -e "$WORK/marked/old" && -f "$WORK/marked/.nginx-installer" ]]; then
  pass "clears a marked build directory"
else
  fail "clears a marked build directory"
fi

ln -s /etc "$WORK/link-to-etc"
assert_not_ok "rejects a symlinked build directory" prepare_build_dir "$WORK/link-to-etc"
if [[ -L "$WORK/link-to-etc" ]]; then
  pass "does not remove the symlink it refused"
else
  fail "does not remove the symlink it refused"
fi

# ---------------------------------------------------------------------------
# Source version parsing (anchored, not line-number based).
# ---------------------------------------------------------------------------
cat > "$WORK/nginx.h" <<'EOF'
/* comment */
#define NGINX_VERSION      "1.30.7"
#define NGINX_VER          "nginx/" NGINX_VERSION
EOF
assert_eq "1.30.7" "$(nginx_source_version "$WORK/nginx.h")" "reads NGINX_VERSION by name"
assert_not_ok "fails when NGINX_VERSION is absent" nginx_source_version "$WORK/missing.h"

# ---------------------------------------------------------------------------
printf '\n%d failure(s)\n' "$failures"
[[ $failures -eq 0 ]]

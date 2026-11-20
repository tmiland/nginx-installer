#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031
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
assert_function clone_pinned
assert_function fetch_nginx_source

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

assert_eq "14" "${#MODULE_PINS[@]}" "pins every git-based module"
for name in brotli cachepurge subfilter modsecurity modsecurity_nginx fancyindex dav_ext vts rtmp testcookie redis2 srcache set_misc quiche; do
  if [[ ${MODULE_PINS[$name]:-} =~ ^[0-9a-f]{40}$ ]]; then
    pass "MODULE_PINS[$name] is a commit SHA"
  else
    fail "MODULE_PINS[$name] is a commit SHA"
  fi
done

for var in BADBOT_REV TLSDYN_REV NGINX_AUTOINSTALL_REV OPENSSL_PATCH_REV; do
  value=${!var:-}
  if [[ $value =~ ^[0-9a-f]{40}$ ]]; then
    pass "$var is a commit SHA"
  else
    fail "$var is a commit SHA"
  fi
done
for var in SLIB_SHA256 BADBOT_SHA256 TLSDYN_SHA256 HTTP3_PATCH_SHA256 HPACK_HTTP3_PATCH_SHA256 HPACK_PATCH_SHA256 RUSTUP_X86_64_SHA256 RUSTUP_AARCH64_SHA256 MODSEC_CONF_SHA256; do
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

#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005,SC2317,SC2329

## Author: Tommy Miland (@tmiland) - Copyright (c) 2026


######################################################################
####                    Nginx Installer.sh                        ####
####               Automatic nginx install script                 ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.0.2'

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2026 Tommy Miland
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#------------------------------------------------------------------------------#
## Uncomment for debugging purpose
# set -o errexit
# set -o pipefail
# set -o nounset
# set -o xtrace
# Get current directory
CURRDIR=$(pwd)
# Set update check
UPDATE_SCRIPT=0
# Detect the distribution and exit
DETECT_ONLY=0
# Get script filename
self=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_FILENAME=$(basename "$self")
SCRIPT_DIR=$(dirname "$self")
# Logfile
LOGFILE=${LOGFILE:-$CURRDIR/nginx_installer.log}
# Default processing units (all available)
NPROC=$(nproc)
# Console output level; ignore debug level messages.
VERBOSE=0
# Show banners (Default: yes)
BANNERS=1
# Default Install dir (Default: /opt/linux)
TEMP_INSTALL_DIR=${TEMP_INSTALL_DIR:-/opt/nginx}
# Default install dir
INSTALL_DIR=${INSTALL_DIR:-/etc/nginx}
# https://stackoverflow.com/a/51068988
# latest_kernel() {
#   curl -s https://www.kernel.org/finger_banner | grep -m1 "$1" | sed -r 's/^.+: +([^ ]+)( .+)?$/\1/'
# }
latest_nginx() {
	curl -s https://nginx.org/en/download.html |
	grep -oP '(?<='"$1"' version).*?(?=[0-9]+\.[0-9]+\.[0-9](-[0-9])?</a)' |
	grep -oP '[0-9]+\.[0-9]+\.[0-9](-[0-9])?'
}
# True when the argument looks like an nginx release version (X.Y.Z).
is_nginx_version() {
  [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
# Read NGINX_VERSION from a source-tree nginx.h by name, not by line number.
nginx_source_version() {
  local header=${1:-}
  [[ -f $header ]] || return 1
  awk -F'"' '/^#define[[:space:]]+NGINX_VERSION[[:space:]]/ { print $2; exit }' "$header"
}
# Verify a file against an expected sha256.
verify_sha256() {
  local file=${1:-} expected=${2:-} actual
  [[ -f $file && -n $expected ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  actual=$(sha256sum -- "$file" | awk '{print $1}') || return 1
  [[ $actual == "$expected" ]]
}
# Download a pinned file and verify its sha256 before returning success.
download_verified() {
  local url=${1:-} dest=${2:-} expected=${3:-}
  [[ -n $url && -n $dest && -n $expected ]] || return 1
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" || return 1
  else
    return 1
  fi
  verify_sha256 "$dest" "$expected"
}
# Source slib from the checkout when present, otherwise from the pinned
# revision. Nothing is executed before its sha256 matches SLIB_SHA256.
load_slib() {
  local source_file temp_file=""
  if [[ -f $SCRIPT_DIR/src/slib.sh ]]; then
    source_file=$SCRIPT_DIR/src/slib.sh
  else
    temp_file=$(mktemp "${TMPDIR:-/tmp}/nginx-installer-slib.XXXXXX") || return 1
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$SLIB_URL" -o "$temp_file" || { rm -f "$temp_file"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$temp_file" "$SLIB_URL" || { rm -f "$temp_file"; return 1; }
    else
      rm -f "$temp_file"
      return 1
    fi
    source_file=$temp_file
  fi
  if [[ ${SLIB_SKIP_VERIFY:-0} != 1 ]] && ! verify_sha256 "$source_file" "$SLIB_SHA256"; then
    echo "slib checksum mismatch: $source_file (set SLIB_SKIP_VERIFY=1 for a local edit)" >&2
    [[ -n $temp_file ]] && rm -f "$temp_file"
    return 1
  fi
  # shellcheck source=/dev/null
  . "$source_file" || { [[ -n $temp_file ]] && rm -f "$temp_file"; return 1; }
  [[ -n $temp_file ]] && rm -f "$temp_file"
  return 0
}
# Clone a module at the exact revision recorded in MODULE_PINS. Fetching the
# SHA directly works for older commits that are not in a shallow branch tip.
clone_pinned() {
  local name=${1:-} url=${2:-} dir=${3:-}
  local rev=${MODULE_PINS[$name]:-} head
  [[ -n $name && -n $url && -n $dir ]] || return 1
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || return 1
  rm -rf -- "$dir" || return 1
  mkdir -p -- "$dir" || return 1
  git -C "$dir" init --quiet || return 1
  git -C "$dir" remote add origin "$url" || return 1
  if git -C "$dir" fetch --quiet --depth 1 origin "$rev"; then
    git -C "$dir" checkout --quiet FETCH_HEAD || return 1
  else
    git -C "$dir" fetch --quiet origin || return 1
    git -C "$dir" checkout --quiet "$rev" || return 1
  fi
  head=$(git -C "$dir" rev-parse HEAD) || return 1
  [[ $head == "$rev" ]] || { echo "pinned revision mismatch for $name" >&2; return 1; }
}
# Download the nginx release tarball and verify its PGP signature against the
# pinned nginx.org signing keys before extracting it.
fetch_nginx_source() {
  local version=${1:-} dest=${2:-}
  local tmp gnupg entry url expected actual
  is_nginx_version "$version" || return 1
  command -v gpg >/dev/null 2>&1 || return 1
  tmp=$(mktemp -d "$TEMP_INSTALL_DIR/nginx-download.XXXXXX") || return 1
  gnupg=$tmp/gnupg
  mkdir -m 700 "$gnupg" || return 1
  curl -fsSL "https://nginx.org/download/nginx-${version}.tar.gz" -o "$tmp/nginx.tar.gz" || return 1
  curl -fsSL "https://nginx.org/download/nginx-${version}.tar.gz.asc" -o "$tmp/nginx.tar.gz.asc" || return 1
  for entry in "${NGINX_SIGNING_KEYS[@]}"; do
    url=${entry%%|*}
    expected=${entry##*|}
    curl -fsSL "$url" -o "$tmp/signing.key" || return 1
    actual=$(GNUPGHOME="$gnupg" gpg --batch --with-colons --show-keys "$tmp/signing.key" 2>/dev/null |
      awk -F: '/^fpr:/ { print $10; exit }')
    [[ $actual == "$expected" ]] || return 1
    case " $NGINX_SIGNING_KEY_IDS " in
      *" $actual "*) ;;
      *) return 1 ;;
    esac
    GNUPGHOME="$gnupg" gpg --batch --quiet --import "$tmp/signing.key" || return 1
  done
  GNUPGHOME="$gnupg" gpg --batch --verify "$tmp/nginx.tar.gz.asc" "$tmp/nginx.tar.gz" >/dev/null 2>&1 || return 1
  mkdir -p -- "$dest" || return 1
  tar -xzf "$tmp/nginx.tar.gz" -C "$dest" --strip-components=1 || return 1
  rm -rf -- "$tmp"
  log_info "Verified nginx ${version} source (PGP)"
}
# True when at least one source module is selected.
modules_selected() {
  local flag
  for flag in PAGESPEED BROTLI HEADERMOD GEOIP FANCYINDEX CACHEPURGE SUBFILTER \
    LUA WEBDAV VTS RTMP TESTCOOKIE REDIS2 HTTPREDIS SRCACHE SETMISC NGXECHO \
    ZSTD MODSEC HTTP3 TLSDYN HPACK; do
    [[ ${!flag:-n} == y ]] && return 0
  done
  return 1
}
# Resolve the release asset for the selected module bundle.
modules_bundle_url() {
  local base
  if [[ -n $MODULES_BUNDLE_URL ]]; then
    printf '%s' "$MODULES_BUNDLE_URL"
    return 0
  fi
  [[ -n $MODULES_REPO && -n $MODULES_BUNDLE ]] || return 1
  if [[ $MODULES_REV == latest ]]; then
    base="https://github.com/$MODULES_REPO/releases/latest/download"
  else
    base="https://github.com/$MODULES_REPO/releases/download/$MODULES_REV"
  fi
  printf '%s/nginx-modules-%s.tar.gz' "$base" "$MODULES_BUNDLE"
}
# Download and verify the full module source bundle, then extract it into
# $TEMP_INSTALL_DIR/modules. The bundle is the primary source; per-module
# downloads remain only as a fallback for modules missing from it.
fetch_modules_bundle() {
  local url sums tmp archive extract src
  [[ $MODULES_SKIP_BUNDLE == 1 ]] && return 0
  url=$(modules_bundle_url) || return 1
  sums=${MODULES_SUMS_URL:-$(dirname -- "$url")/SHA256SUMS}
  tmp=$(mktemp -d "$TEMP_INSTALL_DIR/modules-download.XXXXXX") || return 1
  archive=$tmp/nginx-modules-${MODULES_BUNDLE}.tar.gz
  curl -fsSL "$url" -o "$archive" || { rm -rf "$tmp"; return 1; }
  curl -fsSL "$sums" -o "$tmp/SHA256SUMS" || { rm -rf "$tmp"; return 1; }
  ( cd "$tmp" && grep -E "[ *]nginx-modules-${MODULES_BUNDLE}\.tar\.gz$" SHA256SUMS | sha256sum -c - ) ||
    { rm -rf "$tmp"; return 1; }
  extract=$tmp/extract
  mkdir -p "$extract" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$archive" -C "$extract" --no-same-owner || { rm -rf "$tmp"; return 1; }
  if [[ -d $extract/modules ]]; then
    src=$extract
  elif [[ -d $extract/$MODULES_BUNDLE/modules ]]; then
    src=$extract/$MODULES_BUNDLE
  else
    src=$(dirname -- "$(find "$extract" -maxdepth 2 -type d -name modules -print -quit)") || true
  fi
  [[ -n ${src:-} && -d $src/modules ]] || { rm -rf "$tmp"; return 1; }
  mkdir -p "$TEMP_INSTALL_DIR/modules" || { rm -rf "$tmp"; return 1; }
  cp -a "$src/modules/." "$TEMP_INSTALL_DIR/modules/" || { rm -rf "$tmp"; return 1; }
  cp -a "$src/versions.conf" "$TEMP_INSTALL_DIR/versions.conf" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log_info "Verified nginx-modules ${MODULES_BUNDLE} bundle (${MODULES_REV})"
}
# Load module versions from the verified bundle without sourcing it.
load_module_versions() {
  local conf=$TEMP_INSTALL_DIR/versions.conf line key value
  [[ -f $conf ]] || return 1
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      NPS_VER|HEADERMOD_VER|LIBMAXMINDDB_VER|GEOIP2_VER|LUA_JIT_VER|LUA_NGINX_VER|LUA_RESTYCORE_VER|LUA_RESTYLRUACHE_VER|NGINX_DEV_KIT|HTTPREDIS_VER|NGXECHO_VER|ZSTD_VER|OPENSSL_VER|LIBRESSL_VER)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        log_warning "Unknown module version key in bundle: $key"
        return 1
        ;;
    esac
  done < "$conf"
}
# Refuse build directories that could destroy the system when wiped.
validate_build_dir() {
  local dir=${1:-} canonical
  [[ -n $dir && $dir == /* ]] || return 1
  canonical=$(realpath -m -- "$dir" 2>/dev/null) || return 1
  [[ $canonical == "$dir" ]] || return 1
  case "$dir" in
    /opt/*|/usr/local/*|/var/tmp/*|/tmp/*|/home/*|/root/*|/srv/*)
      return 0
      ;;
  esac
  return 1
}
# Prepare the build directory. Returns 2 when the directory exists, is
# non-empty, and was not created by this installer.
prepare_build_dir() {
  local dir=${1:-}
  validate_build_dir "$dir" || return 1
  [[ -L $dir ]] && return 1
  [[ -e $dir && ! -d $dir ]] && return 1
  if [[ -d $dir ]]; then
    if [[ ! -f $dir/.nginx-installer ]] &&
       [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      return 2
    fi
    rm -rf -- "$dir" || return 1
  fi
  mkdir -p -- "$dir" || return 1
  : > "$dir/.nginx-installer" || return 1
}
# Refuse install directories that must never be deleted on uninstall.
validate_install_dir() {
  local dir=${1:-} canonical
  [[ -n $dir && $dir == /* ]] || return 1
  canonical=$(realpath -m -- "$dir" 2>/dev/null) || return 1
  [[ $canonical == "$dir" ]] || return 1
  case "$dir" in
    /etc/*|/usr/local/*|/opt/*|/srv/*|/home/*|/root/*|/var/tmp/*|/tmp/*)
      return 0
      ;;
  esac
  return 1
}
# Detect the distribution family. The optional argument is a filesystem root
# for tests; production calls it with no argument.
# shellcheck disable=SC2120
detect_distro() {
  local root=${1:-} os_id="" os_like=""
  DISTRO=""
  DISTRO_GROUP=""
  PKGCMD=""
  LSB=""

  if [[ -f $root/etc/os-release ]]; then
    os_id=$(sed -n 's/^ID=//p' "$root/etc/os-release" | tr -d '"')
    os_like=$(sed -n 's/^ID_LIKE=//p' "$root/etc/os-release" | tr -d '"')
  fi

  if [[ -f $root/etc/debian_version ]]; then
    if [[ -s $root/etc/issue.net ]]; then
      DISTRO=$(cat "$root/etc/issue.net")
    elif [[ -f $root/etc/os-release ]]; then
      DISTRO=$(sed -n 's/^PRETTY_NAME=//p' "$root/etc/os-release" | tr -d '"')
    fi
    [[ -n $DISTRO ]] || DISTRO=Debian
  elif [[ -f $root/etc/redhat-release ]]; then
    DISTRO=$(cat "$root/etc/redhat-release")
  elif [[ -f $root/etc/os-release ]]; then
    DISTRO=$(sed -n 's/^PRETTY_NAME=//p' "$root/etc/os-release" | tr -d '"')
  fi

  shopt -s nocasematch
  # ID and ID_LIKE are the reliable source; /etc/issue.net is only a fallback.
  local ids=" ${os_id,,} ${os_like,,} "
  case "$ids" in
    *" debian "*|*" ubuntu "*)
      PKGCMD='apt-get -o Dpkg::Progress-Fancy=1 install -qq'
      LSB=lsb-release
      DISTRO_GROUP=Debian
      return 0
      ;;
  esac

  case "$DISTRO" in
    Debian*|Ubuntu*|Linux\ Mint*|LinuxMint*|LMDE*|PureOS*|Pop*|Devuan*)
      PKGCMD='apt-get -o Dpkg::Progress-Fancy=1 install -qq'
      LSB=lsb-release
      DISTRO_GROUP=Debian
      ;;
    CentOS*)
      PKGCMD='yum install -y'
      LSB=redhat-lsb
      DISTRO_GROUP=RHEL
      echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}"
      return 1
      ;;
    Fedora*)
      PKGCMD='dnf install -y'
      LSB=redhat-lsb
      DISTRO_GROUP=RHEL
      echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}"
      return 1
      ;;
    Arch*|Manjaro*)
      PKGCMD='yes | LC_ALL=en_US.UTF-8 pacman -S'
      LSB=lsb-release
      DISTRO_GROUP=Arch
      echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}"
      return 1
      ;;
    *)
      echo -e "${RED}${BALLOT_X} unknown distro: '${DISTRO:-unknown}'${NORMAL}"
      return 1
      ;;
  esac
  return 0
}
# Default Kernel version
STABLE_VER=$(latest_nginx Stable)
# Mainline kernel version
MAINLINE_VER=$(latest_nginx Mainline)
# Default kernel version without arguments
NGINX_VER=${NGINX_VER:-$STABLE_VER}
# Default nginx version name
NGINX_VER_NAME=${NGINX_VER_NAME:-stable}
NGINX_VER_NAME=${NGINX_VER_NAME,,}
# Installed kernel
CURRENT_VER=$INSTALL_DIR/installed_version
# Repo name for this script
REPO_NAME="tmiland/nginx-installer"
# slib is pinned to a commit and verified by sha256 before it is sourced.
SLIB_REV=595e489b7a6e4d6662333608d4056b519a75272a
SLIB_SHA256=b59fe3a9ede69a7e58af2c395b7cc7d655f96346a365abdd21f8471cce0ed036
SLIB_URL=${SLIB_URL:-https://raw.githubusercontent.com/$REPO_NAME/$SLIB_REV/src/slib.sh}

# Module source bundle. Full is the default; individual module flags still
# decide what gets compiled.
MODULES_REPO=${MODULES_REPO:-tmiland/nginx-modules}
MODULES_REV=${MODULES_REV:-latest}
MODULES_BUNDLE=${MODULES_BUNDLE:-full}
MODULES_BUNDLE_URL=${MODULES_BUNDLE_URL:-}
MODULES_SUMS_URL=${MODULES_SUMS_URL:-}
MODULES_SKIP_BUNDLE=${MODULES_SKIP_BUNDLE:-0}

# Define module versions
LIBRESSL_VER=${LIBRESSL_VER:-4.4.1}
OPENSSL_VER=${OPENSSL_VER:-3.5.9}
NPS_VER=${NPS_VER:-1.13.35.2}
HEADERMOD_VER=${HEADERMOD_VER:-0.42}
LIBMAXMINDDB_VER=${LIBMAXMINDDB_VER:-1.14.1}
GEOIP2_VER=${GEOIP2_VER:-3.4}
LUA_JIT_VER=${LUA_JIT_VER:-2.1-20261117}
LUA_NGINX_VER=${LUA_NGINX_VER:-0.10.31}
LUA_RESTYCORE_VER=${LUA_RESTYCORE_VER:-0.1.32}
LUA_RESTYLRUCACHE_VER=${LUA_RESTYLRUCACHE_VER:-0.15}
NGINX_DEV_KIT=${NGINX_DEV_KIT:-0.3.4}
HTTPREDIS_VER=${HTTPREDIS_VER:-0.4.2-build5}
NGXECHO_VER=${NGXECHO_VER:-0.66}
ZSTD_VER=${ZSTD_VER:-0.1.1}

# Pinned revisions for git-based modules. Fetched by SHA, so a branch moving
# upstream cannot change what this script builds.
declare -A MODULE_PINS=(
	[brotli]=25f86f0bac1101b6512135eac5f93c49c63609e3
	[cachepurge]=331fe43e8d9a3d1fa5e0c9fec7d3201d431a9177
	[subfilter]=e12e965ac1837ca709709f9a26f572a54d83430e
	[modsecurity]=475aece84b0823a4318cf31c558a9584d660dc47
	[modsecurity_nginx]=30a4747a170ad26848ae5112f4c0f8b7ad94156c
	[fancyindex]=70311f239ec1e88ff79c669d126d08532ddb8554
	[dav_ext]=f5e30888a256136d9c550bf1ada77d6ea78a48af
	[vts]=3b9235819e4a8bdadd30fbb70434b07d20c33248
	[rtmp]=6c7719d0ba32e00b563ec70bd43dad11960fa9c4
	[testcookie]=de7ca883344ff154f6c9cebc7289a54039e238d3
	[redis2]=0e7f942deae4cd3e85c8891fa30a815df9659e82
	[srcache]=3febcaa6d6e222047173c9701d855598141b3aab
	[set_misc]=4a4e2ce09ac8a6505a58ef8a2265ff42a87a0c9d
	[quiche]=d448b6b239652b09e81c8dde883b98cd5827c31f
)

# Pinned scripts, patches, and nginx signing keys.
BADBOT_REV=de661720daf023c6d4d840c7216d608c23dac445
BADBOT_SHA256=92db080637ec21883f608abd0a512678780a267c3d56f3e683b641ad11079aea
TLSDYN_REV=afb50796c16a2a8cdebfdd86ebb8806b05db3a35
TLSDYN_SHA256=edf627dd38f8092f81703226ef17d7ad11f5c1aeabe2bd64686bac7ad6b79094
NGINX_AUTOINSTALL_REV=da89d6c05ae1f456f4529aad5a6085a633f108ff
HTTP3_PATCH_SHA256=b9f14740113a550bb7b05a0f082446ecc654b04d68714b0f544b7a201845e591
HPACK_HTTP3_PATCH_SHA256=6cf3c61d749a17ffdfd5c85dbd914757af7d265845796cb9fc1b8da824fa5361
OPENSSL_PATCH_REV=c48a1f85a70c649364bb82daca13dc14a14df8c1
HPACK_PATCH_SHA256=452d20ffeda8eecca5f3338838cb907b38b2e1b0674568665b51101d834b60f3
RUSTUP_VERSION=1.27.1
RUSTUP_X86_64_SHA256=6aeece6993e902708983b209d04c0d1dbb14ebb405ddb87def578d41f920f56d
RUSTUP_AARCH64_SHA256=1cffbf51e63e634c746f741de50649bbbcbd9dbe1de363c9ecef64e278dba2b2
MODSEC_CONF_SHA256=a4b9bed9b27e9be225b76d3965b4237416aba62432c9824aca431dbac4e72f43
NGINX_SIGNING_KEY_IDS="43387825DDB1BB97EC36BA5D007C8D7C15D87369 8540A6F18833A80E9C1653A42FD21310B49F6B46 D6786CE303D9A9022998DC6CC8464D549AF75C0A 7338973069ED3F443F4D37DFA64FD5B17ADB39A8 13C82A63B603576156E30A4EA0EA981B66B0D967"
NGINX_SIGNING_KEYS=(
	"https://nginx.org/keys/arut.key|43387825DDB1BB97EC36BA5D007C8D7C15D87369"
	"https://nginx.org/keys/nginx_signing.key|8540A6F18833A80E9C1653A42FD21310B49F6B46"
	"https://nginx.org/keys/pluknet.key|D6786CE303D9A9022998DC6CC8464D549AF75C0A"
	"https://nginx.org/keys/sb.key|7338973069ED3F443F4D37DFA64FD5B17ADB39A8"
	"https://nginx.org/keys/thresh.key|13C82A63B603576156E30A4EA0EA981B66B0D967"
)

if [ -f $CURRENT_VER ]; then
  CURRENT_VER=$(cat "$CURRENT_VER")
else
	CURRENT_VER=none
fi
# Include functions. slib is verified against SLIB_SHA256 before it runs.
if ! load_slib; then
  echo "Failed to load or verify src/slib.sh (pin ${SLIB_REV})." >&2
  echo "Set SLIB_SKIP_VERIFY=1 only for a local development edit." >&2
  exit 1
fi

# Setup slog
# shellcheck disable=SC2034
LOG_PATH="$LOGFILE"
# Setup run_ok
# shellcheck disable=SC2034
RUN_LOG="$LOGFILE"
# Exit on any failure during shell stage
# shellcheck disable=SC2034
RUN_ERRORS_FATAL=1

# Console output level; ignore debug level messages.
if [ "$VERBOSE" = "1" ]; then
  # shellcheck disable=SC2034
  LOG_LEVEL_STDOUT="DEBUG"
else
  # shellcheck disable=SC2034
  LOG_LEVEL_STDOUT="INFO"
fi
# Log file output level; catch literally everything.
# shellcheck disable=SC2034
LOG_LEVEL_LOG="DEBUG"

# log_fatal calls log_error
log_fatal() {
  log_error "$1"
}

fatal() {
  echo
  log_fatal "Fatal Error Occurred: $1"
  printf "%s \\n" "${RED}Cannot continue installation.${NORMAL}"
  if [ -d "$TEMP_INSTALL_DIR" ]; then
    log_warning "Build directory retained for troubleshooting: $TEMP_INSTALL_DIR"
  fi
  log_fatal "If you are unsure of what went wrong, you may wish to review the log"
  log_fatal "in $LOGFILE"
  exit 1
}

success() {
  log_success "$1 Succeeded."
}

read_sleep() {
  read -rt "$1" <> <(:) || :
}

# Make sure that the script runs with root permissions
chk_permissions() {
  # Only root can run this
  if [[ "$EUID" != 0 ]]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} The ${SCRIPT_NAME} script must be run as root"
  fi
}

chk_nginx() {
  # Check if kernel is installed, abort if same version is found
  if [ "$CURRENT_VER" = "${NGINX_VER}" ]; then
    fatal "${RED}${BALLOT_X} nginx ${NGINX_VER} is already installed. Process aborted${NORMAL}"
  fi
}

versionToInt() {
  echo "$@" | awk -F "." '{ printf("%03d%03d%03d", $1,$2,$3); }';
}

changelog() {
    curl --silent "https://api.github.com/repos/nginx/nginx/releases/latest" |
    grep '"body":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p'
}

# BANNERS
header_logo() {
  #header
  echo -e "${GREEN}"
  cat <<'EOF'
          _   __      _           
         / | / /___ _(_)___  _  __
        /  |/ / __ `/ / __ \| |/_/
       / /|  / /_/ / / / / />  <  
      /_/ |_/\__, /_/_/ /_/_/|_|  
            /____/
    ____           __        ____               __  
   /  _/___  _____/ /_____ _/ / /__  __________/ /_ 
   / // __ \/ ___/ __/ __ `/ / / _ \/ ___/ ___/ __ \
 _/ // / / (__  ) /_/ /_/ / / /  __/ /  (__  ) / / /
/___/_/ /_/____/\__/\__,_/_/_/\___/_(_)/____/_/ /_/ 
EOF
  echo -e '                                                       ' "${NORMAL}"
}

# Header
header() {
  echo -e "${GREEN}\n"
  echo ' ╔═══════════════════════════════════════════════════════════════════╗'
  echo ' ║                        '"${SCRIPT_NAME}"'                        ║'
  echo ' ║                  Automatic nginx install script                   ║'
  echo ' ║                      Maintained by @tmiland                       ║'
  echo ' ║                          version: '${VERSION}'                           ║'
  echo ' ╚═══════════════════════════════════════════════════════════════════╝'
  echo -e "${NORMAL}"
}

# Update banner
show_update_banner () {
  header
  echo ""
  echo "There is a newer version of ${SCRIPT_NAME} available."
  #echo ""
  echo ""
  echo -e "${GREEN}${DONE} New version:${NORMAL} ${RELEASE_TAG} - ${RELEASE_TITLE}"
  echo ""
  echo -e "${YELLOW}${ARROW} Notes:${NORMAL}\n"
  echo -e "${BLUE}${RELEASE_NOTE}${NORMAL}"
  echo ""
}

# Exit Script
exit_script() {
  header_logo
  echo -e "
   This script runs on coffee ☕

   ${GREEN}${CHECK}${NORMAL} ${BBLUE}Paypal${NORMAL} ${ARROW} ${YELLOW}https://paypal.me/milandtommy${NORMAL}
   ${GREEN}${CHECK}${NORMAL} ${BBLUE}BTC${NORMAL}    ${ARROW} ${YELLOW}33mjmoPxqfXnWNsvy8gvMZrrcG3gEa3YDM${NORMAL}
  "
  echo -e "Documentation for this script is available here: ${YELLOW}\n${ARROW} https://github.com/${REPO_NAME}${NORMAL}\n"
  echo -e "${YELLOW}${ARROW} Goodbye.${NORMAL} ☺"
  echo ""
}

##
# Returns the version number of ${SCRIPT_NAME} file on line 14
##
get_updater_version () {
  echo $(sed -n '14 s/[^0-9.]*\([0-9.]*\).*/\1/p' "$1")
}

# Update script
# Default: Do not check for update
update_updater () {
  # Download files
  download_file () {
    declare -r url=$1
    declare -r tf=$(mktemp)
    local dlcmd=''
    dlcmd="wget -O $tf"
    $dlcmd "${url}" &>/dev/null && echo "$tf" || echo '' # return the temp-filename (or empty string on error)
  }
  # Open files
  open_file () { #expects one argument: file_path

    if [ "$(uname)" == 'Darwin' ]; then
      open "$1"
    elif [ "$(cut $(uname -s) 1 5)" == "Linux" ]; then
      xdg-open "$1"
    else
      echo -e "${RED}${ERROR} Error: Sorry, opening files is not supported for your OS.${NC}"
    fi
  }
  # Get latest release tag from GitHub
  get_latest_release_tag() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -n 's/[^0-9.]*\([0-9.]*\).*/\1/p'
  }

  RELEASE_TAG=$(get_latest_release_tag ${REPO_NAME})

  # Get latest release download url
  get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"browser_download_url":' |
    sed -n 's#.*\(https*://[^"]*\).*#\1#;p'
  }

  LATEST_RELEASE=$(get_latest_release ${REPO_NAME})

  # Get latest release notes
  get_latest_release_note() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"body":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p'
  }

  RELEASE_NOTE=$(get_latest_release_note ${REPO_NAME})

  # Get latest release title
  get_latest_release_title() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep -m 1 '"name":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p'
  }

  RELEASE_TITLE=$(get_latest_release_title ${REPO_NAME})

  echo -e "${GREEN}${ARROW} Checking for updates...${NORMAL}"
  # Get tmpfile from github
  declare -r tmpfile=$(download_file "$LATEST_RELEASE")
  if [[ $(get_updater_version "${CURRDIR}/$SCRIPT_FILENAME") < "${RELEASE_TAG}" ]]; then
    if [ $UPDATE_SCRIPT = "1" ]; then
      show_update_banner
      echo -e "${RED}${ARROW} Do you want to update [Y/N?]${NORMAL}"
      read -p "" -n 1 -r
      echo -e "\n\n"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        mv "${tmpfile}" "${CURRDIR}/${SCRIPT_FILENAME}"
        chmod u+x "${CURRDIR}/${SCRIPT_FILENAME}"
        "${CURRDIR}/${SCRIPT_FILENAME}" "$@" -d
        exit 1 # Update available, user chooses to update
      fi
      if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1 # Update available, but user chooses not to update
      fi
    fi
  else
    echo -e "${GREEN}${DONE} No update available.${NORMAL}"
    return 0 # No update available
  fi
}

usage() {
  #header
  ## shellcheck disable=SC2046
  printf "Usage: %s %s [options]" "${CYAN}" "${SCRIPT_FILENAME}${NORMAL}"
  echo
  echo "  If called without arguments, installs stable nginx ${YELLOW}${NGINX_VER}${NORMAL} using ${TEMP_INSTALL_DIR}"
  echo
  printf "%s\\n" "  ${YELLOW}--help                 |-h${NORMAL}   display this help and exit"
  printf "%s\\n" "  ${YELLOW}--nginx                |-ng${NORMAL}  nginx version (X.Y.Z)"
  printf "%s\\n" "  ${YELLOW}--stable               |-s${NORMAL}   stable nginx version ${YELLOW}$STABLE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--mainline             |-m${NORMAL}   mainline nginx version ${YELLOW}$MAINLINE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--detect               |-dt${NORMAL}  detect the distro and exit"
	printf "%s\\n" "  ${YELLOW}--headless             |-hl${NORMAL}  headless install"
	printf "%s\\n" "  ${YELLOW}--modules-extra        |-me${NORMAL}  extra modules"
	printf "%s\\n" "  ${YELLOW}--profile              |-p${NORMAL}   built-in module profile: minimal or full"
	printf "%s\\n" "  ${YELLOW}--modules-bundle       |-mb${NORMAL}  module source bundle (default: full)"
	printf "%s\\n" "  ${YELLOW}--modules-rev          |-mr${NORMAL}  nginx-modules release tag (default: latest)"
	printf "%s\\n" "  ${YELLOW}--bad-bot              |-bb${NORMAL}  install the bad bot blocker"
  printf "%s\\n" "  ${YELLOW}--dir                  |-d${NORMAL}   temporary build directory"
  printf "%s\\n" "  ${YELLOW}--verbose              |-v${NORMAL}   increase verbosity"
  printf "%s\\n" "  ${YELLOW}--nproc                |-n${NORMAL}   set the number of processing units to use"
  printf "%s\\n" "  ${YELLOW}--enable-debug-info    |-edi${NORMAL} enable debug info"
  printf "%s\\n" "  ${YELLOW}--changelog            |-cl${NORMAL}  view changelog for nginx version"
  printf "%s\\n" "  ${YELLOW}--update               |-upd${NORMAL} check for script update"
  printf "%s\\n" "  ${YELLOW}--uninstall            |-u${NORMAL}   uninstall nginx"
  echo
  printf "%s\\n" "  Installed nginx version: ${YELLOW}${CURRENT_VER}${NORMAL}  | Script version: ${CYAN}${VERSION}${NORMAL}"
  echo
}

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --help | -h)
      usage
      exit 0
      ;;
    --detect | -dt)
      DETECT_ONLY=1
      shift
      ;;
    --verbose | -v)
      shift
      VERBOSE=1
      ;;
    --stable | -s)
      shift
      NGINX_VER=$STABLE_VER
      NGINX_VER_NAME=stable
      ;;
    --mainline | -m)
      shift
      NGINX_VER=$MAINLINE_VER
      NGINX_VER_NAME=mainline
      ;;
    --nginx | -ng)
      if [[ -z ${2:-} || $2 == -* ]]; then
        fatal "Option --nginx requires a version (X.Y.Z)."
      fi
      NGINX_VER="$2"
      is_nginx_version "$NGINX_VER" || fatal "Invalid nginx version: '$NGINX_VER' (expected X.Y.Z)."
      NGINX_VER_NAME=custom
      shift 2
      ;;
		--headless | -hl)
			shift
			HEADLESS=y
			;;
		--modules-extra | -me)
			shift
			MODULES_EXTRA=y
			;;
		--profile | -p)
			case "${2:-}" in
				minimal | full) ;;
				*) fatal "Option --profile requires 'minimal' or 'full'." ;;
			esac
			MODULES_PROFILE=$2
			shift 2
			;;
		--modules-bundle | -mb)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --modules-bundle requires a bundle name."
			MODULES_BUNDLE=$2
			shift 2
			;;
		--modules-rev | -mr)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --modules-rev requires a release tag."
			MODULES_REV=$2
			shift 2
			;;
		--bad-bot | -bb)
			shift
			BADBOT=y
			;;
    --dir | -d) # Bash Space-Separated (e.g., --option argument)
      if [[ -z ${2:-} || $2 == -* ]]; then
        fatal "Option --dir requires a path."
      fi
      validate_build_dir "$2" ||
        fatal "Refusing unsafe build directory: '$2'. Use a path under /opt, /usr/local, /var/tmp, /tmp, /home, /root, or /srv."
      TEMP_INSTALL_DIR="$2" # Source: https://stackoverflow.com/a/14203146
      shift 2
      ;;
    --nproc | -n)
      if [[ ! ${2:-} =~ ^[1-9][0-9]*$ ]]; then
        fatal "Option --nproc requires a positive integer."
      fi
      NPROC=$2
      shift 2
      ;;
    --changelog | -cl)
      changelog
      exit 0
      ;;
    --update | -upd)
      UPDATE_SCRIPT=1
      update_updater "$@"
      exit 0
      ;;
    --uninstall | -u)
      shift
      mode="uninstall"
      ;;
    -* | --*)
      printf "%s\\n\\n" "Unrecognized option: $1"
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Define default modules
MODULES_PROFILE=${MODULES_PROFILE:-minimal}
case "$MODULES_PROFILE" in
  minimal)
    DEFAULT_NGINX_MODULES="--with-threads \
--with-file-aio \
--with-http_ssl_module \
--with-http_v2_module \
--with-http_realip_module \
--with-compat \
--with-pcre \
--with-pcre-jit"
    ;;
  full)
    DEFAULT_NGINX_MODULES="--with-select_module \
--with-poll_module \
--with-threads \
--with-file-aio \
--with-http_ssl_module \
--with-http_v2_module \
--with-http_v3_module \
--with-http_realip_module \
--with-http_addition_module \
--with-http_xslt_module \
--with-http_sub_module \
--with-http_dav_module \
--with-http_flv_module \
--with-http_mp4_module \
--with-http_gunzip_module \
--with-http_gzip_static_module \
--with-http_auth_request_module \
--with-http_random_index_module \
--with-http_secure_link_module \
--with-http_degradation_module \
--with-http_slice_module \
--with-http_stub_status_module \
--with-http_perl_module \
--with-mail \
--with-mail_ssl_module \
--without-mail_pop3_module \
--without-mail_imap_module \
--without-mail_smtp_module \
--with-stream \
--with-stream_ssl_module \
--with-stream_realip_module \
--with-stream_ssl_preread_module \
--with-cpp_test_module \
--with-compat \
--with-pcre \
--with-pcre-jit"
    ;;
  *)
    fatal "Unknown MODULES_PROFILE: '$MODULES_PROFILE' (expected minimal or full)"
    ;;
esac
NGINX_MODULES=${NGINX_MODULES:-$DEFAULT_NGINX_MODULES}

# Allow the test suite to source the helpers and option parser without
# running an install.
if [[ ${NGINX_INSTALLER_LIB_ONLY:-0} == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

# Read-only distro check; must work without root.
if [[ $DETECT_ONLY == 1 ]]; then
  detect_distro || exit 1
  printf 'DISTRO=%s\nDISTRO_GROUP=%s\n' "$DISTRO" "$DISTRO_GROUP"
  exit 0
fi

# Everything below this point changes the system.
chk_permissions

# Uninstall nginx
if [ "$mode" = "uninstall" ]
then
	if [ -d "$INSTALL_DIR" ] || [ -x /usr/sbin/nginx ]
	then
	systemctl stop nginx || true
	systemctl disable nginx || true
	systemctl daemon-reload || true
	rm -f /etc/systemd/system/nginx.service
	rm -f /etc/logrotate.d/nginx
  if [[ $RM_CONF == 'y' ]]; then
		validate_install_dir "$INSTALL_DIR" ||
		  fatal "Refusing to delete unsafe install directory: '$INSTALL_DIR'."
		rm -rf -- "$INSTALL_DIR"
	fi
	rm -f /usr/sbin/nginx
	if [[ $RM_LOGS == 'y' ]]; then
	  rm -rf -- /var/log/nginx
	fi
  rm -rf -- /var/cache/nginx
  rm -f /var/run/nginx.pid /var/run/nginx.lock
	apt-mark unhold nginx >/dev/null 2>&1 || true
  echo ""
  echo -e "${GREEN}${DONE} Success${NORMAL}"
  echo ""
	else
		echo ""
	  echo -e "${RED}${BALLOT_X} Looks like nginx is not installed! :(${NORMAL}"
	  echo ""
	fi
  exit 0
fi

# Validate the requested version before changing the system.
is_nginx_version "${NGINX_VER:-}" ||
  fatal "Could not determine the nginx version (got '${NGINX_VER:-empty}'). Check access to nginx.org or pass --nginx X.Y.Z."

chk_nginx

# Start with a clean log
if [[ -f $LOGFILE ]]; then
  rm "$LOGFILE"
fi

detect_distro || exit 1
if ! lsb_release -si 1>/dev/null 2>&1; then
  echo ""
  echo -e "${RED}${BALLOT_X} Looks like ${LSB} is not installed!${NORMAL}"
  echo ""
  read -r -p "Do you want to download ${LSB}? [y/n]? " ANSWER
  echo ""
  case $ANSWER in
    [Yy]* )
      echo -e "${GREEN}${ARROW} Installing ${LSB} on ${DISTRO}...${NORMAL}"
      su -s "$(which bash)" -c "${PKGCMD} ${LSB}" || echo -e "${RED}${BALLOT_X} Error: could not install ${LSB}!${NORMAL}"
      echo -e "${GREEN}${CHECK} Done${NORMAL}"
      read_sleep 3
      ;;
    [Nn]* )
      exit 1;
      ;;
    * ) echo "Enter Y, N, please." ;;
  esac
fi

UPDATE=""
INSTALL=""
PKGCHK=""
shopt -s nocasematch
if [[ $DISTRO_GROUP == "Debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  UPDATE="apt-get -o Dpkg::Progress-Fancy=1 update -qq"
  INSTALL="apt-get -o Dpkg::Progress-Fancy=1 install -qq"
  PKGCHK="dpkg -s"
  # Install packages
  INSTALL_PKGS="wget curl git build-essential apt-transport-https ca-certificates libpcre2-dev autoconf unzip automake libtool tar git libssl-dev zlib1g-dev uuid-dev libxml2-dev libxslt1-dev cmake libperl-dev gnupg libzstd-dev"
else
  echo -e "${RED}${BALLOT_X} Error: Sorry, your OS is not supported.${NORMAL}"
  exit 1;
fi

if [[ $HEADLESS == 'y' ]] && [[ $MODULES_EXTRA == 'y' ]]; then
	echo -e "${RED}${BALLOT_X} Error: Sorry, choose either headless or modules extra, not both.${NORMAL}"
  exit 1;
fi

# Define installation parameters for headless install (fallback if unspecifed)
if [[ $HEADLESS == 'y' ]]; then
	# Define default module options
	PAGESPEED=${PAGESPEED:-n}
	BROTLI=${BROTLI:-n}
	HEADERMOD=${HEADERMOD:-n}
	GEOIP=${GEOIP:-n}
	GEOIP2_ACCOUNT_ID=${GEOIP2_ACCOUNT_ID:-}
	GEOIP2_LICENSE_KEY=${GEOIP2_LICENSE_KEY:-}
	FANCYINDEX=${FANCYINDEX:-n}
	CACHEPURGE=${CACHEPURGE:-n}
	SUBFILTER=${SUBFILTER:-n}
	LUA=${LUA:-n}
	WEBDAV=${WEBDAV:-n}
	VTS=${VTS:-n}
	RTMP=${RTMP:-n}
	TESTCOOKIE=${TESTCOOKIE:-n}
	HTTP3=${HTTP3:-n}
	MODSEC=${MODSEC:-n}
	REDIS2=${REDIS2:-n}
	HTTPREDIS=${HTTPREDIS:-n}
	SRCACHE=${SRCACHE:-n}
	SETMISC=${SETMISC:-n}
	NGXECHO=${NGXECHO:-n}
	HPACK=${HPACK:-n}
	SSL=${SSL:-1}
	RM_CONF=${RM_CONF:-n}
	RM_LOGS=${RM_LOGS:-n}
fi

# Define installation parameters for headless install (fallback if unspecifed)

if [[ $MODULES_EXTRA == 'y' ]]; then
	# Define extra module options
	PAGESPEED=${PAGESPEED:-n}
	BROTLI=${BROTLI:-n}
	HEADERMOD=${HEADERMOD:-y}
	GEOIP=${GEOIP:-n}
	GEOIP2_ACCOUNT_ID=${GEOIP2_ACCOUNT_ID:-}
	GEOIP2_LICENSE_KEY=${GEOIP2_LICENSE_KEY:-}
	FANCYINDEX=${FANCYINDEX:-y}
	CACHEPURGE=${CACHEPURGE:-y}
	SUBFILTER=${SUBFILTER:-y}
	LUA=${LUA:-n}
	WEBDAV=${WEBDAV:-y}
	VTS=${VTS:-y}
	RTMP=${RTMP:-y}
	TESTCOOKIE=${TESTCOOKIE:-y}
	HTTP3=${HTTP3:-n}
	MODSEC=${MODSEC:-n}
	REDIS2=${REDIS2:-y}
	HTTPREDIS=${HTTPREDIS:-n}
	SRCACHE=${SRCACHE:-y}
	SETMISC=${SETMISC:-y}
	NGXECHO=${NGXECHO:-y}
	HPACK=${HPACK:-n}
	SSL=${SSL:-2}
	RM_CONF=${RM_CONF:-n}
	RM_LOGS=${RM_LOGS:-n}
fi

# The MaxMind key is only used in this shell; keep it out of child environments.
export -n GEOIP2_LICENSE_KEY 2>/dev/null || true

# Define default options
NGINX_OPTIONS=${NGINX_OPTIONS:-"
--sbin-path=/usr/sbin/nginx \
--conf-path=$INSTALL_DIR/nginx.conf \
--error-log-path=/var/log/nginx/error.log \
--http-log-path=/var/log/nginx/access.log \
--pid-path=/var/run/nginx.pid \
--lock-path=/var/run/nginx.lock \
--http-client-body-temp-path=/var/cache/nginx/client_temp \
--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
--user=nginx \
--group=nginx \
--with-cc-opt=-Wno-deprecated-declarations \
--with-cc-opt=-Wno-ignored-qualifiers"}


case $SSL in
1 | SYSTEM)
	;;

2 | OPENSSL)
	OPENSSL=y
	;;
3 | LIBRESSL)
	LIBRESSL=y
	;;
*)
	echo "SSL unspecified, fallback to system's OpenSSL ($(openssl version | cut -c9-14))"
	;;
esac

download_modules() {

	# Prefer the verified module bundle; per-module downloads are fallback.
	if modules_selected; then
		if [[ $MODULES_SKIP_BUNDLE == 1 ]]; then
			log_warning "Module bundle skipped; using upstream sources."
		elif fetch_modules_bundle; then
			load_module_versions || exit 1
		else
			log_warning "Module bundle unavailable; using upstream sources."
		fi
	fi

	# PageSpeed
	if [[ $PAGESPEED == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/incubator-pagespeed-ngx-${NPS_VER}-stable" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://github.com/pagespeed/ngx_pagespeed/archive/v${NPS_VER}-stable.zip
			unzip v${NPS_VER}-stable.zip
		fi
		cd "$TEMP_INSTALL_DIR/modules/incubator-pagespeed-ngx-${NPS_VER}-stable" || exit 1
		psol_url=https://dl.google.com/dl/page-speed/psol/${NPS_VER}.tar.gz
		[ -e scripts/format_binary_url.sh ] && psol_url=$(scripts/format_binary_url.sh PSOL_BINARY_URL)
		wget "${psol_url}"
		tar -xzvf "$(basename "${psol_url}")"
	fi

	#Brotli
	if [[ $BROTLI == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ngx_brotli" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			clone_pinned brotli https://github.com/google/ngx_brotli "$TEMP_INSTALL_DIR/modules/ngx_brotli" || exit 1
			git -C "$TEMP_INSTALL_DIR/modules/ngx_brotli" submodule update --init --recursive --depth 1 || exit 1
		fi
	fi

	# More Headers
	if [[ $HEADERMOD == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/headers-more-nginx-module-${HEADERMOD_VER}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERMOD_VER}.tar.gz
			tar xaf v${HEADERMOD_VER}.tar.gz
		fi
	fi

	# GeoIP
	if [[ $GEOIP == 'y' ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			# install libmaxminddb
			if [[ ! -d "libmaxminddb-${LIBMAXMINDDB_VER}" ]]; then
				wget https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VER}/libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz
				tar xaf libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz
			fi
			cd libmaxminddb-${LIBMAXMINDDB_VER}/ || exit 1
			./configure
			make -j "$(nproc)"
			make install
			ldconfig

			cd ../ || exit 1
			if [[ ! -d "ngx_http_geoip2_module-${GEOIP2_VER}" ]]; then
				wget https://github.com/leev/ngx_http_geoip2_module/archive/${GEOIP2_VER}.tar.gz
				tar xaf ${GEOIP2_VER}.tar.gz
			fi

			mkdir -p geoip-db
			cd geoip-db || exit 1
			# - Download GeoLite2 databases using the license key
			# - Keep the key out of argv and the log: curl reads the URL from
			#   a mode-0600 config file instead of the command line
			# - Verify every download against MaxMind's sha256
			if [[ ! -d /opt/geoip ]]; then
				GEOIP2_CURLRC="$TEMP_INSTALL_DIR/modules/geoip-db/.curlrc-$$"
				( umask 077; : > "$GEOIP2_CURLRC" ) || exit 1
				for edition in GeoLite2-ASN GeoLite2-City GeoLite2-Country; do
					echo "=== FETCHING ${edition} ==="
					GEOIP2_URL="https://download.maxmind.com/app/geoip_download?edition_id=${edition}&license_key=${GEOIP2_LICENSE_KEY}&suffix=tar.gz"
					printf 'url = "%s"\n' "${GEOIP2_URL}.sha256" > "$GEOIP2_CURLRC"
					curl -fs --config "$GEOIP2_CURLRC" -o "${edition}.sha256.tmp" || {
						echo "Failed to download the ${edition} checksum" >&2
						exit 1
					}
					GEOIP2_FILENAME=$(awk '{print $2}' "${edition}.sha256.tmp")
					[[ -n $GEOIP2_FILENAME ]] || {
						echo "Empty ${edition} checksum file" >&2
						exit 1
					}
					mv "${edition}.sha256.tmp" "$GEOIP2_FILENAME.sha256"
					printf 'url = "%s"\n' "$GEOIP2_URL" > "$GEOIP2_CURLRC"
					curl -fs --config "$GEOIP2_CURLRC" -o "$GEOIP2_FILENAME" || {
						echo "Failed to download ${edition}" >&2
						exit 1
					}
					echo "=== CHECKSUM ==="
					sha256sum -c "$GEOIP2_FILENAME.sha256" || exit 1
				done
				rm -f "$GEOIP2_CURLRC"
				tar -xf GeoLite2-ASN_*.tar.gz
				tar -xf GeoLite2-City_*.tar.gz
				tar -xf GeoLite2-Country_*.tar.gz
				mkdir /opt/geoip
				cd GeoLite2-ASN_*/ || exit 1
				mv GeoLite2-ASN.mmdb /opt/geoip/
				cd ../ || exit 1
				cd GeoLite2-City_*/ || exit 1
				mv GeoLite2-City.mmdb /opt/geoip/
				cd ../ || exit 1
				cd GeoLite2-Country_*/ || exit 1
				mv GeoLite2-Country.mmdb /opt/geoip/
			else
				echo -e "GeoLite2 database files exists... Skipping download"
			fi
			# Write GeoIP.conf without putting the key in sed's argv
			if [[ ! -f /usr/local/etc/GeoIP.conf ]]; then
				mkdir -p /usr/local/etc
				(
					umask 077
					{
						printf '%s\n' '# GeoIP.conf file for geoipupdate (>= 3.1.1).'
						printf '%s\n' '# AccountID and LicenseKey are from your MaxMind account.'
						printf 'AccountID %s\n' "$GEOIP2_ACCOUNT_ID"
						printf 'LicenseKey %s\n' "$GEOIP2_LICENSE_KEY"
						printf '%s\n' 'EditionIDs GeoLite2-ASN GeoLite2-City GeoLite2-Country'
					} > /usr/local/etc/GeoIP.conf
				)
				chmod 600 /usr/local/etc/GeoIP.conf
			else
				chmod 600 /usr/local/etc/GeoIP.conf 2>/dev/null || true
				echo -e "GeoIP.conf file exists... Skipping"
			fi
			if [[ ! -f /etc/cron.d/geoipupdate ]]; then
				# Install crontab to run twice a week
				echo -e "40 23 * * 6,3 /usr/local/bin/geoipupdate" > /etc/cron.d/geoipupdate
			else
				echo -e "geoipupdate crontab file exists... Skipping"
			fi
		fi

	# Cache Purge
	if [[ $CACHEPURGE == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ngx_cache_purge" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			clone_pinned cachepurge https://github.com/FRiCKLE/ngx_cache_purge "$TEMP_INSTALL_DIR/modules/ngx_cache_purge" || exit 1
		fi
	fi

	# Nginx Substitutions Filter
	if [[ $SUBFILTER == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ngx_http_substitutions_filter_module" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			clone_pinned subfilter https://github.com/yaoweibin/ngx_http_substitutions_filter_module "$TEMP_INSTALL_DIR/modules/ngx_http_substitutions_filter_module" || exit 1
		fi
	fi

	# Lua
	if [[ $LUA == 'y' ]]; then
		# LuaJIT download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		if [[ ! -d "luajit2-${LUA_JIT_VER}" ]]; then
			wget https://github.com/openresty/luajit2/archive/v${LUA_JIT_VER}.tar.gz
			tar xaf v${LUA_JIT_VER}.tar.gz
		fi
		cd luajit2-${LUA_JIT_VER} || exit 1
		make -j "$(nproc)"
		make install

		# ngx_devel_kit download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		if [[ ! -d "ngx_devel_kit-${NGINX_DEV_KIT}" ]]; then
			wget https://github.com/simplresty/ngx_devel_kit/archive/v${NGINX_DEV_KIT}.tar.gz
			tar xaf v${NGINX_DEV_KIT}.tar.gz
		fi

		# lua-nginx-module download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		if [[ ! -d "lua-nginx-module-${LUA_NGINX_VER}" ]]; then
			wget https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VER}.tar.gz
			tar xaf v${LUA_NGINX_VER}.tar.gz
		fi

		# lua-resty-core download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		if [[ ! -d "lua-resty-core-${LUA_RESTYCORE_VER}" ]]; then
			wget https://github.com/openresty/lua-resty-core/archive/v${LUA_RESTYCORE_VER}.tar.gz
			tar xaf v${LUA_RESTYCORE_VER}.tar.gz
		fi
		cd lua-resty-core-${LUA_RESTYCORE_VER} || exit 1
		make install PREFIX=/etc/nginx

		# lua-resty-lrucache download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		if [[ ! -d "lua-resty-lrucache-${LUA_RESTYLRUCACHE_VER}" ]]; then
			wget https://github.com/openresty/lua-resty-lrucache/archive/v${LUA_RESTYLRUCACHE_VER}.tar.gz
			tar xaf v${LUA_RESTYLRUCACHE_VER}.tar.gz
		fi
		cd lua-resty-lrucache-${LUA_RESTYLRUCACHE_VER} || exit 1
		make install PREFIX=/etc/nginx
	fi

	# LibreSSL
	if [[ $LIBRESSL == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/libressl-${LIBRESSL_VER}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			mkdir libressl-${LIBRESSL_VER}
			cd libressl-${LIBRESSL_VER} || exit 1
			wget -qO- http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VER}.tar.gz | tar xz --strip 1
		fi
		cd "$TEMP_INSTALL_DIR/modules/libressl-${LIBRESSL_VER}" || exit 1

		./configure \
			LDFLAGS=-lrt \
			CFLAGS=-fstack-protector-strong \
			--prefix="$TEMP_INSTALL_DIR"/modules/libressl-${LIBRESSL_VER}/.openssl/ \
			--enable-shared=no

		make install-strip -j "$(nproc)"
	fi

	# OpenSSL
	if [[ $OPENSSL == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/openssl-${OPENSSL_VER}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz
			tar xaf openssl-${OPENSSL_VER}.tar.gz
		fi
		cd "$TEMP_INSTALL_DIR/modules/openssl-${OPENSSL_VER}" || exit 1

		./config
	fi

	# ModSecurity
	if [[ $MODSEC == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ModSecurity" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			clone_pinned modsecurity https://github.com/SpiderLabs/ModSecurity "$TEMP_INSTALL_DIR/modules/ModSecurity" || exit 1
			cd "$TEMP_INSTALL_DIR/modules/ModSecurity" || exit 1
			git submodule update --init --recursive --depth 1 || exit 1
		fi
		cd "$TEMP_INSTALL_DIR/modules/ModSecurity" || exit 1
		./build.sh
		./configure
		make -j "$(nproc)"
		make install
		mkdir -p "$INSTALL_DIR/modsec"
		download_verified "https://raw.githubusercontent.com/SpiderLabs/ModSecurity/${MODULE_PINS[modsecurity]}/modsecurity.conf-recommended" \
			"$INSTALL_DIR/modsec/modsecurity.conf" "$MODSEC_CONF_SHA256" || exit 1

		# Enable ModSecurity in Nginx
		if [[ $MODSEC_ENABLE == 'y' ]]; then
			sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "$INSTALL_DIR/modsec/modsecurity.conf"
		fi
	fi

	# Download ngx_http_redis
	if [[ $HTTPREDIS == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ngx_http_redis-${HTTPREDIS_VER}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget -O "ngx_http_redis-${HTTPREDIS_VER}.tar.gz" "https://github.com/osokin/ngx_http_redis/archive/refs/tags/${HTTPREDIS_VER}.tar.gz"
			tar xaf ngx_http_redis-${HTTPREDIS_VER}.tar.gz
		fi
	fi

	# Download ngx_devel_kit if LUA = no
	if [[ $SETMISC == 'y' && $LUA == 'n' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ngx_devel_kit-${NGINX_DEV_KIT}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://github.com/simplresty/ngx_devel_kit/archive/v${NGINX_DEV_KIT}.tar.gz
			tar xaf v${NGINX_DEV_KIT}.tar.gz
		fi
	fi

	# Download echo-nginx-module
	if [[ $NGXECHO == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/echo-nginx-module-${NGXECHO_VER}" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://github.com/openresty/echo-nginx-module/archive/refs/tags/v${NGXECHO_VER}.tar.gz
			tar xaf v${NGXECHO_VER}.tar.gz
		fi
	fi

	if [[ $ZSTD == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/zstd-nginx-module" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			wget https://github.com/tokers/zstd-nginx-module/archive/refs/tags/${ZSTD_VER}.tar.gz
			tar xaf ${ZSTD_VER}.tar.gz
			[[ -d "zstd-nginx-module-${ZSTD_VER}" ]] && mv "zstd-nginx-module-${ZSTD_VER}" zstd-nginx-module
		fi
	fi

	# Optional options
	if [[ $LUA == 'y' ]]; then
		NGINX_OPTIONS=$(
			echo " $NGINX_OPTIONS"
			echo --with-ld-opt="-Wl,-rpath,/usr/local/lib"
		)

		NGINX_OPTIONS=$(
			echo " $NGINX_OPTIONS"
			echo --prefix="$INSTALL_DIR"
		)
	fi

	# Optional modules
	if [[ $LIBRESSL == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --with-openssl="$TEMP_INSTALL_DIR"/modules/libressl-${LIBRESSL_VER}
		)
	fi

	if [[ $PAGESPEED == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/incubator-pagespeed-ngx-${NPS_VER}-stable"
		)
	fi

	if [[ $BROTLI == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/ngx_brotli"
		)
	fi

	if [[ $HEADERMOD == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/headers-more-nginx-module-${HEADERMOD_VER}"
		)
	fi

	if [[ $GEOIP == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/ngx_http_geoip2_module-${GEOIP2_VER}"
		)
	fi

	if [[ $OPENSSL == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--with-openssl=$TEMP_INSTALL_DIR/modules/openssl-${OPENSSL_VER}"
		)
	fi

	if [[ $CACHEPURGE == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/ngx_cache_purge"
		)
	fi

	if [[ $SUBFILTER == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/ngx_http_substitutions_filter_module"
		)
	fi

	# Lua
	if [[ $LUA == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/ngx_devel_kit-${NGINX_DEV_KIT}"
		)
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo "--add-module=$TEMP_INSTALL_DIR/modules/lua-nginx-module-${LUA_NGINX_VER}"
		)
	fi

	if [[ $FANCYINDEX == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/fancyindex" ]]; then
			clone_pinned fancyindex https://github.com/aperezdc/ngx-fancyindex.git "$TEMP_INSTALL_DIR/modules/fancyindex" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/fancyindex
		)
	fi

	if [[ $WEBDAV == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/nginx-dav-ext-module" ]]; then
			clone_pinned dav_ext https://github.com/arut/nginx-dav-ext-module.git "$TEMP_INSTALL_DIR/modules/nginx-dav-ext-module" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --with-http_dav_module --add-module="$TEMP_INSTALL_DIR"/modules/nginx-dav-ext-module
		)
	fi

	if [[ $VTS == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/nginx-module-vts" ]]; then
			clone_pinned vts https://github.com/vozlt/nginx-module-vts.git "$TEMP_INSTALL_DIR/modules/nginx-module-vts" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/nginx-module-vts
		)
	fi

	if [[ $RTMP == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/nginx-rtmp-module" ]]; then
			clone_pinned rtmp https://github.com/arut/nginx-rtmp-module.git "$TEMP_INSTALL_DIR/modules/nginx-rtmp-module" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/nginx-rtmp-module
		)
	fi

	if [[ $TESTCOOKIE == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/testcookie-nginx-module" ]]; then
			clone_pinned testcookie https://github.com/kyprizel/testcookie-nginx-module.git "$TEMP_INSTALL_DIR/modules/testcookie-nginx-module" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/testcookie-nginx-module
		)
	fi

	if [[ $MODSEC == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/ModSecurity-nginx" ]]; then
			clone_pinned modsecurity_nginx https://github.com/SpiderLabs/ModSecurity-nginx.git "$TEMP_INSTALL_DIR/modules/ModSecurity-nginx" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/ModSecurity-nginx
		)
	fi

	if [[ $REDIS2 == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/redis2-nginx-module" ]]; then
			clone_pinned redis2 https://github.com/openresty/redis2-nginx-module.git "$TEMP_INSTALL_DIR/modules/redis2-nginx-module" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/redis2-nginx-module
		)
	fi

	if [[ $HTTPREDIS == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/ngx_http_redis-${HTTPREDIS_VER}
		)
	fi

	if [[ $SRCACHE == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/srcache-nginx-module" ]]; then
			clone_pinned srcache https://github.com/openresty/srcache-nginx-module.git "$TEMP_INSTALL_DIR/modules/srcache-nginx-module" || exit 1
		fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/srcache-nginx-module
		)
	fi

	if [[ $SETMISC == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/set-misc-nginx-module" ]]; then
			clone_pinned set_misc https://github.com/openresty/set-misc-nginx-module.git "$TEMP_INSTALL_DIR/modules/set-misc-nginx-module" || exit 1
		fi
	if [[ $LUA == 'n' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
				echo --add-module="$TEMP_INSTALL_DIR"/modules/ngx_devel_kit-${NGINX_DEV_KIT}
		)
	fi
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/set-misc-nginx-module
		)
	fi

	if [[ $NGXECHO == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/echo-nginx-module-${NGXECHO_VER}
		)
	fi

	if [[ $ZSTD == 'y' ]]; then
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/zstd-nginx-module
		)
	fi

	# Cloudflare's TLS Dynamic Record Resizing patch
	if [[ $TLSDYN == 'y' ]]; then
		download_verified "https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/${TLSDYN_REV}/nginx__dynamic_tls_records_1.17.7%2B.patch" \
			tcp-tls.patch "$TLSDYN_SHA256" || exit 1
		patch -p1 < tcp-tls.patch || exit 1
	fi

	# HTTP3
	if [[ $HTTP3 == 'y' ]]; then
		if [[ ! -d "$TEMP_INSTALL_DIR/modules/quiche" ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			clone_pinned quiche https://github.com/cloudflare/quiche "$TEMP_INSTALL_DIR/modules/quiche" || exit 1
			git -C "$TEMP_INSTALL_DIR/modules/quiche" submodule update --init --recursive --depth 1 || exit 1
		fi
		# Dependencies for BoringSSL and Quiche
		apt-get install -y golang
		# Rust is not packaged at a new enough version, so use a pinned
		# rustup-init binary and verify it before running.
		case "$(uname -m)" in
			x86_64)
				rustup_arch=x86_64-unknown-linux-gnu
				rustup_sha=$RUSTUP_X86_64_SHA256
				;;
			aarch64 | arm64)
				rustup_arch=aarch64-unknown-linux-gnu
				rustup_sha=$RUSTUP_AARCH64_SHA256
				;;
			*)
				echo "Unsupported architecture for rustup: $(uname -m)" >&2
				exit 1
				;;
		esac
		download_verified "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_arch}/rustup-init" \
			"$TEMP_INSTALL_DIR/rustup-init" "$rustup_sha" || exit 1
		chmod 700 "$TEMP_INSTALL_DIR/rustup-init" || exit 1
		"$TEMP_INSTALL_DIR/rustup-init" -y --profile minimal || exit 1
		# shellcheck source=/dev/null
		source "$HOME/.cargo/env"

		cd "$TEMP_INSTALL_DIR"/nginx-${NGINX_VER} || exit 1
		# Apply actual patch
		patch -p01 <"$TEMP_INSTALL_DIR"/modules/quiche/nginx/nginx-1.16.patch || exit 1

		# Apply patch for nginx > 1.19.7 (source: https://github.com/cloudflare/quiche/issues/936#issuecomment-857618081)
		download_verified "https://raw.githubusercontent.com/angristan/nginx-autoinstall/${NGINX_AUTOINSTALL_REV}/patches/nginx-http3-1.19.7.patch" \
			nginx-http3.patch "$HTTP3_PATCH_SHA256" || exit 1
		patch -p01 < nginx-http3.patch || exit 1

		NGINX_OPTIONS=$(
			echo "$NGINX_OPTIONS"
			echo --with-openssl="$TEMP_INSTALL_DIR"/modules/quiche/quiche/deps/boringssl --with-quiche="$TEMP_INSTALL_DIR"/modules/quiche
		)
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --with-http_v3_module
		)
	fi

	# Cloudflare's Cloudflare's full HPACK encoding patch
	if [[ $HPACK == 'y' ]]; then
		if [[ $HTTP3 == 'n' ]]; then
			# Working Patch from https://github.com/hakasenyang/openssl-patch/issues/2#issuecomment-413449809
			download_verified "https://raw.githubusercontent.com/hakasenyang/openssl-patch/${OPENSSL_PATCH_REV}/nginx_hpack_push_1.15.3.patch" \
				nginx_http2_hpack.patch "$HPACK_PATCH_SHA256" || exit 1
		else
			# Same patch as above but fixed conflicts with the HTTP/3 patch
			download_verified "https://raw.githubusercontent.com/angristan/nginx-autoinstall/${NGINX_AUTOINSTALL_REV}/patches/nginx_hpack_push_with_http3.patch" \
				nginx_http2_hpack.patch "$HPACK_HTTP3_PATCH_SHA256" || exit 1
		fi
		patch -p1 < nginx_http2_hpack.patch || exit 1

		NGINX_OPTIONS=$(
			echo "$NGINX_OPTIONS"
			echo --with-http_v2_hpack_enc
		)
	fi

}

configure() {
  ./configure $NGINX_OPTIONS $NGINX_MODULES
  # --with-debug
}

bad_bot_blocker() {
	local repo="https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/${BADBOT_REV}"
	# Pin and verify the entry script; -r pins the files it downloads too.
	download_verified "${repo}/install-ngxblocker" /usr/local/sbin/install-ngxblocker "$BADBOT_SHA256" || return 1
	chmod 700 /usr/local/sbin/install-ngxblocker || return 1
	cd /usr/local/sbin || return 1
	./install-ngxblocker -x -r "$repo" || return 1
	# setup-ngxblocker hardcodes master; pin this run to the same revision.
	sed -i "s#https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master#${repo}#g" \
		/usr/local/sbin/setup-ngxblocker || return 1
	chmod 700 /usr/local/sbin/setup-ngxblocker /usr/local/sbin/update-ngxblocker || return 1
	# update-ngxblocker intentionally tracks upstream for blocklist updates.
	./setup-ngxblocker -x -e conf || return 1
}

install_nginx() {
  clear
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing Nginx version:${NORMAL} $NGINX_VER_NAME: ${YELLOW}$NGINX_VER${NORMAL}"
  echo
  prepare_build_dir "$TEMP_INSTALL_DIR"
  prepare_rc=$?
  if [[ $prepare_rc -eq 2 ]]; then
    fatal "Build directory $TEMP_INSTALL_DIR is not empty and was not created by this installer. Remove it manually or choose another --dir."
  elif [[ $prepare_rc -ne 0 ]]; then
    fatal "Cannot prepare build directory: $TEMP_INSTALL_DIR"
  fi
  printf "%s \\n" "${YELLOW}▣${CYAN}□□□□□${NORMAL} Phase ${YELLOW}1${NORMAL} of ${GREEN}6${NORMAL}: Setup packages"
  # Setup Dependencies
  log_debug "Configuring package manager for ${DISTRO_GROUP} .."
  if ! ${PKGCHK} $INSTALL_PKGS 1>/dev/null 2>&1; then
    log_debug "Updating packages"
    run_ok "${UPDATE}" "Updating package repo..."
    for i in $INSTALL_PKGS; do
      log_debug "Installing required packages $i"
      # shellcheck disable=SC2086
      ${INSTALL} ${i} >>"${RUN_LOG}" 2>&1
    done
		if [[ $MODSEC == 'y' ]]; then
			apt-get install -y apt-utils libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre++-dev libyajl-dev pkgconf
		fi

		if [[ $GEOIP == 'y' ]]; then
			if grep -q "# See /etc/apt/sources.list.d/debian.sources" /etc/apt/sources.list
			then
				sources_list=/etc/apt/sources.list.d/debian.sources
			else
				sources_list=/etc/apt/sources.list
			fi
			if grep -q "main contrib" $sources_list
			then
				echo "main contrib already in sources.list... Skipping"
			else
				sed -i "s/main/main contrib/g" $sources_list
			fi
			apt-get update
			apt-get install -y geoipupdate
		fi
		if [[ $ZSTD == "y" ]]; then
			apt-get install -y zstd
		fi
  fi
  log_success "Package Setup Finished"

  # Reap any clingy processes (like spinner forks)
  # get the parent pids (as those are the problem)
  allpids="$(ps -o pid= --ppid $$) $allpids"
  for pid in $allpids; do
    kill "$pid" 1>/dev/null 2>&1
  done

  # Next step is configuration. Wait here for a moment, hopefully letting any
  # apt processes disappear before we start, as they're huge and memory is a
  # problem. This is hacky. I'm not sure what's really causing random fails.
  read_sleep 1
  echo
  # Download Nginx source code
  log_debug "Phase 2 of 6: Nginx source code download"
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}6${NORMAL}: Download Nginx source code"
  cd "$TEMP_INSTALL_DIR" || fatal "Could not enter build directory: $TEMP_INSTALL_DIR"
  log_debug "Downloading Nginx ${NGINX_VER} source"
  if ! fetch_nginx_source "$NGINX_VER" "$TEMP_INSTALL_DIR/nginx-$NGINX_VER"; then
    fatal "Could not download or PGP-verify nginx ${NGINX_VER} source."
  fi
  log_success "Download finished"
  echo
  cd "nginx-$NGINX_VER" || fatal "nginx source directory is missing: $TEMP_INSTALL_DIR/nginx-$NGINX_VER"
  log_debug "Phase 3 of 6: Nginx modules download"
  printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}6${NORMAL}: Download Nginx modules"
  mkdir -p "$TEMP_INSTALL_DIR/modules" || fatal "Could not create module directory in $TEMP_INSTALL_DIR."
  log_debug "Downloading Nginx modules"
  run_ok "download_modules" "Downloading modules..."
  log_success "Module download finished"
  if [ -d "$TEMP_INSTALL_DIR"/nginx-"${NGINX_VER}" ]; then
    if ! (
      cd "$TEMP_INSTALL_DIR"/nginx-"${NGINX_VER}" || exit 1
      echo
      # Config
      log_debug "Phase 4 of 5: Configuration"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}6${NORMAL}: Setup nginx"
      log_debug "Configuring..."
			sed -i '/ngx_write_stderr("built by " NGX_COMPILER NGX_LINEFEED);/i\        ngx_write_stderr("built with Nginx Installer @tmiland" NGX_LINEFEED);' src/core/nginx.c
			if [[ $LUA == 'y' ]]; then
				export LUAJIT_LIB=/usr/local/lib
				export LUAJIT_INC=/usr/local/include/luajit-2.1
			fi
      run_ok "configure" "Running configuration..."
			# Install default nginx server configuration
			mkdir -p "$INSTALL_DIR/sites-available"
			# shellcheck disable=SC2129
			tee "$INSTALL_DIR/sites-available/default.conf" <<EOF >>"${RUN_LOG}" 2>&1
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _; # This is just an invalid value which will never trigger on a real hostname.
  #access_log logs/default.access.log main;

  server_name_in_redirect off;

  root  $INSTALL_DIR/html;
}
EOF
			# Install systemd configuration
			tee /etc/systemd/system/nginx.service <<EOF >>"${RUN_LOG}" 2>&1
[Unit]
Description=nginx - high performance web server
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStart=/usr/sbin/nginx -c $INSTALL_DIR/nginx.conf
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s TERM $MAINPID

[Install]
WantedBy=multi-user.target

EOF
			# Install systemd configuration
			tee /etc/logrotate.d/nginx <<'EOF' >>"${RUN_LOG}" 2>&1
/var/log/nginx/*.log {
        daily
        missingok
        rotate 52
        compress
        delaycompress
        notifempty
        create 640 nginx adm
        sharedscripts
        postrotate
                if [ -f /var/run/nginx.pid ]; then
                        kill -USR1 `cat /var/run/nginx.pid`
                fi
        endscript
}
EOF

			NGINX_FOLDERS=(
				"conf.d"
				"sites-available"
				"sites-enabled"
			)
			for f in "${NGINX_FOLDERS[@]}"; do
			  ! test -d $INSTALL_DIR || mkdir -p $INSTALL_DIR/$f >>"${RUN_LOG}" 2>&1
			done
			mkdir -p /var/cache/nginx ||
			mkdir -p /var/cache/nginx/client_temp >>"${RUN_LOG}" 2>&1
			if ! id -u "nginx" >/dev/null 2>&1; then
    		run_ok "useradd --no-create-home nginx" "Adding nginx user"
			fi
			systemctl enable nginx >>"${RUN_LOG}" 2>&1 && systemctl daemon-reload >>"${RUN_LOG}" 2>&1
      log_success "Configuration finished"
      read_sleep 1
      echo
      # Compilation
      log_debug "Phase 5 of 6: Compilation"
      printf "%s \\n" "${GREEN}▣▣▣▣${YELLOW}▣${CYAN}□${NORMAL} Phase ${YELLOW}5${NORMAL} of ${GREEN}6${NORMAL}: Nginx Compilation"
      log_debug "Compiling The Nginx source code"
      printf "%s \\n" "Go grab a coffee ☕ 😎 This may take a while..."
      run_ok "make -j${NPROC}" "Compiling Nginx source code..."
      log_success "Compiling finished"
      echo
      # Installation
      log_debug "Phase 6 of 6: Installation"
      printf "%s \\n" "${GREEN}▣▣▣▣▣${YELLOW}▣${NORMAL} Phase ${YELLOW}6${NORMAL} of ${GREEN}6${NORMAL}: Nginx Installation"
      log_debug "Installing Nginx source code"
      run_ok "make install" "Installing Nginx source code..."
			log_success "Installation finished"
			# remove debugging symbols
			strip -s /usr/sbin/nginx
			if [[ -d $INSTALL_DIR/conf.d && $LUA == 'y' ]]; then
				# add necessary `lua_package_path` directive to `nginx.conf`, in the http context
				tee $INSTALL_DIR/conf.d/lua_package_path.conf <<EOF >>"${RUN_LOG}" 2>&1
lua_package_path "$INSTALL_DIR/lib/lua/?.lua;;";
EOF
				# echo -e 'lua_package_path "$INSTALL_DIR/lib/lua/?.lua;;";' > $INSTALL_DIR/conf.d/lua_package_path.conf >>"${RUN_LOG}" 2>&1
			fi
			NGINX_BUILT_VER=$(nginx_source_version ./src/core/nginx.h) ||
			  fatal "Could not read NGINX_VERSION from ./src/core/nginx.h"
			[[ -n $NGINX_BUILT_VER ]] ||
			  fatal "Empty NGINX_VERSION in ./src/core/nginx.h"
			printf '%s\n' "$NGINX_BUILT_VER" > "$INSTALL_DIR/installed_version"
			if [[ $NGINX_VER_NAME != "mainline" && $NGINX_BUILT_VER != "$NGINX_VER" ]]; then
			  log_warning "Built nginx $NGINX_BUILT_VER but requested $NGINX_VER."
			fi
			run_ok "nginx -t && systemctl restart nginx" "Restarting nginx..."
			log_success "done"
			# Block Nginx from being installed via APT
			if [[ $DISTRO_GROUP == "Debian" ]]; then
				# echo -e 'Package: nginx*\nPin: release *\nPin-Priority: -1' > /etc/apt/preferences.d/nginx-block apt-mark hold nginx
				apt-mark hold nginx
			fi
			if [[ $BADBOT == "y" ]]; then
				run_ok "bad_bot_blocker" "Installing nginx bad bot blocker"
				log_success "Bad bot blocker installation finished"
				run_ok "nginx -t && systemctl restart nginx" "Restarting nginx..."
				log_success "done"
			fi
      log_success "Installation finished"
      cd - 1>/dev/null 2>&1 || exit 1
    ); then
      fatal "nginx build failed; see $LOGFILE"
    fi
  else
    fatal "nginx source directory is missing: $TEMP_INSTALL_DIR/nginx-$NGINX_VER"
  fi

  echo
  # Cleanup
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} Cleaning up"
  cd "$CURRDIR" 1>/dev/null 2>&1 || cd /
  if [[ -f "$TEMP_INSTALL_DIR/.nginx-installer" ]]; then
    log_debug "Cleaning up temporary files in $TEMP_INSTALL_DIR."
    find "$TEMP_INSTALL_DIR" -delete || log_warning "Could not fully clean up $TEMP_INSTALL_DIR."
  else
    log_warning "Not cleaning up $TEMP_INSTALL_DIR: installer marker is missing."
  fi
  # Make sure the cursor is back (if spinners misbehaved)
  tput cnorm
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} All ${GREEN}6${NORMAL} phases finished successfully"
}

# Start Script

# Install Nginx
errors=$((0))
if ! install_nginx; then
  errorlist="${errorlist}  ${YELLOW}◉${NORMAL} nginx installation returned an error.\\n"
  errors=$((errors + 1))
fi
if [ $errors -eq "0" ]; then
  read_sleep 5
  if [ "$BANNERS" = "1" ]; then
    exit_script
  fi
  read_sleep 5
  #indexit
else
  log_warning "The following errors occurred during installation:"
  echo
  printf "%s" "${errorlist}"
  if [ -d "$TEMP_INSTALL_DIR" ]; then
    log_warning "Build directory retained for troubleshooting: $TEMP_INSTALL_DIR"
  fi
  exit 1
fi

exit 0

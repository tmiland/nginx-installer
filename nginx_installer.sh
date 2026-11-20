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
# Normalize a comma/space separated module id list: drop blanks and
# duplicates while keeping the first-seen order.
normalize_module_ids() {
  local raw=${1:-} id out="" IFS=', '
  local -a tokens=()
  local -A seen=()
  read -r -a tokens <<< "$raw"
  for id in "${tokens[@]}"; do
    [[ -n $id && -z ${seen[$id]:-} ]] || continue
    seen[$id]=1
    out=${out:+$out }$id
  done
  printf '%s' "$out"
}
# True when the user selected this module id (requires are not included).
module_selected() {
  local id=${1:-} selected
  for selected in "${MODULE_ROOTS[@]}"; do
    [[ $selected == "$id" ]] && return 0
  done
  return 1
}
# True when this module id survived dependency resolution.
module_resolved() {
  local id=${1:-}
  [[ -n $id && -n ${RESOLVED_SEEN[$id]:-} ]]
}
# Parse the bundle's modules.conf into id -> fields tables. The file is data,
# not shell: id|dir|kind|build|requires|env.
declare -A MODULE_DIR=() MODULE_KIND=() MODULE_BUILD=() MODULE_REQUIRES=() MODULE_ENV=()
declare -a RESOLVED_MODULES=()
declare -A RESOLVED_SEEN=() RESOLVING=()
load_modules_manifest() {
  local conf=$TEMP_INSTALL_DIR/modules.conf line id dir kind build requires env
  [[ -f $conf ]] || return 1
  MODULE_DIR=() MODULE_KIND=() MODULE_BUILD=() MODULE_REQUIRES=() MODULE_ENV=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    IFS='|' read -r id dir kind build requires env <<< "$line"
    [[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    [[ -n $dir && $dir != /* && $dir != *..* ]] || return 1
    [[ -z ${MODULE_DIR[$id]:-} ]] || return 1
    case $kind in
      git | archive | zip | file) ;;
      *) return 1 ;;
    esac
    MODULE_DIR[$id]=$dir
    MODULE_KIND[$id]=$kind
    MODULE_BUILD[$id]=$build
    MODULE_REQUIRES[$id]=$requires
    MODULE_ENV[$id]=$env
  done < "$conf"
  ((${#MODULE_DIR[@]} > 0))
}
# Resolve ids and their recursive requires into RESOLVED_MODULES, dependencies
# first. Unknown ids are rejected; a dependency cycle is a manifest error.
resolve_module_id() {
  local id=${1:-} parent=${2:-} dep
  local -a deps=()
  if [[ -z ${MODULE_DIR[$id]:-} ]]; then
    if [[ -n $parent ]]; then
      log_error "Unknown module id '$id' (required by '$parent')."
    else
      log_error "Unknown module id '$id'; see modules.conf in nginx-modules."
    fi
    return 1
  fi
  [[ -z ${RESOLVED_SEEN[$id]:-} ]] || return 0
  [[ -z ${RESOLVING[$id]:-} ]] || { log_error "Module dependency cycle at '$id'."; return 1; }
  RESOLVING[$id]=1
  IFS=',' read -r -a deps <<< "${MODULE_REQUIRES[$id]:-}"
  for dep in "${deps[@]}"; do
    dep=${dep//[[:space:]]/}
    [[ -n $dep ]] || continue
    resolve_module_id "$dep" "$id" || return 1
  done
  unset 'RESOLVING[$id]'
  RESOLVED_SEEN[$id]=1
  RESOLVED_MODULES+=("$id")
  log_debug "Selected module id=$id (kind=${MODULE_KIND[$id]}, env=${MODULE_ENV[$id]:-none})"
}
resolve_modules() {
  local id
  RESOLVED_MODULES=()
  RESOLVED_SEEN=()
  RESOLVING=()
  ((${#MODULE_DIR[@]} > 0)) || { log_error "Module manifest is not loaded."; return 1; }
  for id in "$@"; do
    [[ -n $id ]] || continue
    resolve_module_id "$id" "" || return 1
  done
}
# Build the configure arguments for a module from its manifest build field.
module_build_args() {
  local id=${1:-} dir args
  [[ -n $id && -n ${MODULE_DIR[$id]:-} ]] || return 1
  dir=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[$id]}
  args=${MODULE_BUILD[$id]:-}
  [[ -n $args ]] || return 0
  printf '%s' "${args//\{dir\}/$dir}"
}
append_module_build_args() {
  local id args
  for id in "${RESOLVED_MODULES[@]}"; do
    args=$(module_build_args "$id") || return 1
    [[ -n $args ]] && NGINX_MODULES="$NGINX_MODULES $args"
  done
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
# Download and verify the full module source bundle, then extract its module
# tree and manifest into $TEMP_INSTALL_DIR. The bundle is the only module
# source; there is no per-module upstream fallback.
fetch_modules_bundle() {
  local url sums tmp archive extract src
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
  cp -a "$src/modules.conf" "$TEMP_INSTALL_DIR/modules.conf" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log_info "Verified nginx-modules ${MODULES_BUNDLE} bundle (${MODULES_REV})"
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

# Module source bundle. `modules.conf` inside the verified bundle decides the
# build flags and special build steps for the ids in MODULES.
MODULES_REPO=${MODULES_REPO:-tmiland/nginx-modules}
MODULES_REV=${MODULES_REV:-latest}
MODULES_BUNDLE=${MODULES_BUNDLE:-full}
MODULES_BUNDLE_URL=${MODULES_BUNDLE_URL:-}
MODULES_SUMS_URL=${MODULES_SUMS_URL:-}

# Comma/space separated module ids from the bundle's modules.conf.
MODULES=${MODULES:-}
# GeoIP credentials for the geoip2 module. Prefer an env file over argv.
GEOIP_ENV_FILE=${GEOIP_ENV_FILE:-}
GEOIP2_ACCOUNT_ID=${GEOIP2_ACCOUNT_ID:-}
GEOIP2_LICENSE_KEY=${GEOIP2_LICENSE_KEY:-}
# The MaxMind credentials are used only in this shell; keep them out of the
# environment of child processes.
export -n GEOIP2_ACCOUNT_ID GEOIP2_LICENSE_KEY 2>/dev/null || true

# Pinned scripts and nginx signing keys.
BADBOT_REV=de661720daf023c6d4d840c7216d608c23dac445
BADBOT_SHA256=92db080637ec21883f608abd0a512678780a267c3d56f3e683b641ad11079aea
RUSTUP_VERSION=1.27.1
RUSTUP_X86_64_SHA256=6aeece6993e902708983b209d04c0d1dbb14ebb405ddb87def578d41f920f56d
RUSTUP_AARCH64_SHA256=1cffbf51e63e634c746f741de50649bbbcbd9dbe1de363c9ecef64e278dba2b2
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
	printf "%s\\n" "  ${YELLOW}--modules              |-M${NORMAL}   module ids to build from the bundle (comma separated)"
	printf "%s\\n" "  ${YELLOW}--modules-extra        |-me${NORMAL}  preset: append the common extra module ids"
	printf "%s\\n" "  ${YELLOW}--profile              |-p${NORMAL}   built-in module profile: minimal or full"
	printf "%s\\n" "  ${YELLOW}--modules-bundle       |-mb${NORMAL}  module source bundle (default: full)"
	printf "%s\\n" "  ${YELLOW}--modules-rev          |-mr${NORMAL}  nginx-modules release tag (default: latest)"
	printf "%s\\n" "  ${YELLOW}--geoip-account-id     |-ga${NORMAL}      MaxMind account id for geoip2"
	printf "%s\\n" "  ${YELLOW}--geoip-license-key    |-gk${NORMAL}      MaxMind license key for geoip2 (visible in ps)"
	printf "%s\\n" "  ${YELLOW}--geoip-env-file       |-ge${NORMAL}      file with GEOIP2_ACCOUNT_ID and GEOIP2_LICENSE_KEY"
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
		--modules | -M)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --modules requires module ids (comma separated)."
			MODULES=${MODULES:+$MODULES,}$2
			shift 2
			;;
		--modules-extra | -me)
			shift
			MODULES_EXTRA=y
			;;
		--geoip-account-id | -ga)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --geoip-account-id requires a value."
			GEOIP2_ACCOUNT_ID=$2
			shift 2
			;;
		--geoip-license-key | -gk)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --geoip-license-key requires a value."
			GEOIP2_LICENSE_KEY=$2
			shift 2
			;;
		--geoip-env-file | -ge)
			[[ -n ${2:-} && $2 != -* ]] || fatal "Option --geoip-env-file requires a path."
			GEOIP_ENV_FILE=$2
			shift 2
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

# Define installation parameters for headless install (fallback if unspecified)
if [[ $HEADLESS == 'y' ]]; then
	SSL=${SSL:-1}
	RM_CONF=${RM_CONF:-n}
	RM_LOGS=${RM_LOGS:-n}
fi

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

# TLS selection stays backward compatible: it only appends a module id.
case $SSL in
1 | SYSTEM)
	;;

2 | OPENSSL)
	MODULES="$MODULES,openssl"
	;;

3 | LIBRESSL)
	MODULES="$MODULES,libressl"
	;;
*)
	;;
esac

# --modules-extra is only a preset: it appends ids to the selection.
if [[ $MODULES_EXTRA == 'y' ]]; then
	MODULES="$MODULES,headers-more,fancyindex,cachepurge,subfilter,webdav,vts,rtmp,testcookie,redis2,srcache,set-misc,echo,zstd,openssl"
fi

# MODULE_ROOTS is the user selection; requires are resolved from the bundle
# manifest once it has been downloaded.
MODULES_LIST=$(normalize_module_ids "$MODULES")
read -r -a MODULE_ROOTS <<< "$MODULES_LIST"

# Load GeoIP credentials from KEY=VALUE lines without sourcing the file. Only
# the two MaxMind keys are accepted; values may be quoted.
load_geoip_env_file() {
	local file=${1:-} line key value
	[[ -n $file ]] || return 0
	[[ -f $file ]] || { log_error "GeoIP env file not found: $file"; return 1; }
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		[[ -z $line || $line == \#* ]] && continue
		key=${line%%=*}
		[[ $key != "$line" ]] || { log_error "Invalid line in GeoIP env file: $file"; return 1; }
		value=${line#*=}
		case $value in
			\"*\" | \'*\')
				((${#value} >= 2)) && value=${value:1:${#value}-2}
				;;
		esac
		case $key in
			GEOIP2_ACCOUNT_ID) GEOIP2_ACCOUNT_ID=$value ;;
			GEOIP2_LICENSE_KEY) GEOIP2_LICENSE_KEY=$value ;;
			*) log_error "Unknown key in GeoIP env file: $key"; return 1 ;;
		esac
	done < "$file"
}

# geoip2 needs a MaxMind license key. Prefer the env file over the environment
# so the key does not appear in the process list. Never log the value.
prepare_geoip_credentials() {
	if [[ -z $GEOIP_ENV_FILE && -f ${HOME:-/root}/.credentials/geoip.env ]]; then
		GEOIP_ENV_FILE=${HOME:-/root}/.credentials/geoip.env
	fi
	if [[ -n $GEOIP_ENV_FILE ]]; then
		load_geoip_env_file "$GEOIP_ENV_FILE" || return 1
	fi
	if [[ -z $GEOIP2_LICENSE_KEY ]]; then
		log_error "geoip2 requires GeoIP credentials."
		log_error "Pass --geoip-env-file <path> (or set GEOIP_ENV_FILE) to a file containing"
		log_error "GEOIP2_ACCOUNT_ID=... and GEOIP2_LICENSE_KEY=..., or set both in the environment."
		return 1
	fi
}

# Download and verify the GeoLite2 databases, then write geoipupdate configs.
# The license key is only written to mode-0600 files, never to argv or the log.
download_geoip_databases() {
	local dbdir=$TEMP_INSTALL_DIR/modules/geoip-db
	local edition rcfile url filename
	mkdir -p "$dbdir" || return 1
	(
		cd "$dbdir" || exit 1
		if [[ ! -d /opt/geoip ]]; then
			rcfile=.curlrc-$$
			( umask 077; : > "$rcfile" ) || exit 1
			trap 'rm -f "$rcfile"' EXIT
			for edition in GeoLite2-ASN GeoLite2-City GeoLite2-Country; do
				echo "=== FETCHING ${edition} ==="
				url="https://download.maxmind.com/app/geoip_download?edition_id=${edition}&license_key=${GEOIP2_LICENSE_KEY}&suffix=tar.gz"
				printf 'url = "%s"\n' "${url}.sha256" > "$rcfile"
				curl -fs --config "$rcfile" -o "${edition}.sha256.tmp" || {
					echo "Failed to download the ${edition} checksum" >&2
					exit 1
				}
				filename=$(awk '{print $2}' "${edition}.sha256.tmp")
				[[ -n $filename ]] || {
					echo "Empty ${edition} checksum file" >&2
					exit 1
				}
				mv "${edition}.sha256.tmp" "$filename.sha256"
				printf 'url = "%s"\n' "$url" > "$rcfile"
				curl -fs --config "$rcfile" -o "$filename" || {
					echo "Failed to download ${edition}" >&2
					exit 1
				}
				echo "=== CHECKSUM ==="
				sha256sum -c "$filename.sha256" || exit 1
			done
			rm -f "$rcfile"
			tar -xf GeoLite2-ASN_*.tar.gz || exit 1
			tar -xf GeoLite2-City_*.tar.gz || exit 1
			tar -xf GeoLite2-Country_*.tar.gz || exit 1
			mkdir /opt/geoip || exit 1
			cd GeoLite2-ASN_*/ || exit 1
			mv GeoLite2-ASN.mmdb /opt/geoip/ || exit 1
			cd ../ || exit 1
			cd GeoLite2-City_*/ || exit 1
			mv GeoLite2-City.mmdb /opt/geoip/ || exit 1
			cd ../ || exit 1
			cd GeoLite2-Country_*/ || exit 1
			mv GeoLite2-Country.mmdb /opt/geoip/ || exit 1
		else
			echo -e "GeoLite2 database files exists... Skipping download"
		fi
	) || return 1
	# Write GeoIP.conf without putting the key in sed's argv
	if [[ ! -f /usr/local/etc/GeoIP.conf ]]; then
		mkdir -p /usr/local/etc || return 1
		(
			umask 077
			{
				printf '%s\n' '# GeoIP.conf file for geoipupdate (>= 3.1.1).'
				printf '%s\n' '# AccountID and LicenseKey are from your MaxMind account.'
				printf 'AccountID %s\n' "$GEOIP2_ACCOUNT_ID"
				printf 'LicenseKey %s\n' "$GEOIP2_LICENSE_KEY"
				printf '%s\n' 'EditionIDs GeoLite2-ASN GeoLite2-City GeoLite2-Country'
			} > /usr/local/etc/GeoIP.conf
		) || return 1
		chmod 600 /usr/local/etc/GeoIP.conf || return 1
	else
		chmod 600 /usr/local/etc/GeoIP.conf 2>/dev/null || true
		echo -e "GeoIP.conf file exists... Skipping"
	fi
	if [[ ! -f /etc/cron.d/geoipupdate ]]; then
		# Install crontab to run twice a week
		echo -e "40 23 * * 6,3 /usr/local/bin/geoipupdate" > /etc/cron.d/geoipupdate || return 1
	else
		echo -e "geoipupdate crontab file exists... Skipping"
	fi
}

# PageSpeed ships only in the legacy bundle; its PSOL binary is still fetched
# from Google. Derive the version from the manifest directory, not a pin.
download_pagespeed_psol() {
	local dir=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[pagespeed]:-}
	local version url
	[[ -n ${MODULE_DIR[pagespeed]:-} && -d $dir ]] || return 1
	version=${MODULE_DIR[pagespeed]}
	version=${version#incubator-pagespeed-ngx-}
	version=${version%-stable}
	[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		log_error "Cannot derive the PageSpeed version from '${MODULE_DIR[pagespeed]}'."
		return 1
	}
	(
		cd "$dir" || exit 1
		url=https://dl.google.com/dl/page-speed/psol/${version}.tar.gz
		[ -e scripts/format_binary_url.sh ] && url=$(scripts/format_binary_url.sh PSOL_BINARY_URL)
		wget "$url" || exit 1
		tar -xzf "$(basename "$url")" || exit 1
	) || return 1
}

# quiche needs a Go toolchain and a recent Rust; keep the pinned rustup-init
# so the build is reproducible. The manifest supplies the configure flags and
# apply_module_patches applies quiche/nginx/nginx-1.16.patch.
build_quiche_deps() {
	local rustup_arch rustup_sha
	apt-get install -y golang >>"${RUN_LOG}" 2>&1 || return 1
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
			return 1
			;;
	esac
	download_verified "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_arch}/rustup-init" \
		"$TEMP_INSTALL_DIR/rustup-init" "$rustup_sha" || return 1
	chmod 700 "$TEMP_INSTALL_DIR/rustup-init" || return 1
	"$TEMP_INSTALL_DIR/rustup-init" -y --profile minimal || return 1
	# shellcheck source=/dev/null
	source "$HOME/.cargo/env" || return 1
}

# Run the special build step for one resolved module id. Modules without a
# handler are simple build-flag modules and need no preparation.
run_module_handler() {
	local id=${1:-} dir
	[[ -n $id ]] || return 1
	dir=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[$id]:-}
	case $id in
		luajit2)
			( cd "$dir" && make -j "$(nproc)" && make install ) || return 1
			;;
		libmaxminddb)
			( cd "$dir" && ./configure && make -j "$(nproc)" && make install && ldconfig ) || return 1
			;;
		openssl)
			( cd "$dir" && ./config ) || return 1
			;;
		libressl)
			( cd "$dir" &&
				./configure \
					LDFLAGS=-lrt \
					CFLAGS=-fstack-protector-strong \
					--prefix="$dir/.openssl" \
					--enable-shared=no &&
				make install-strip -j "$(nproc)" ) || return 1
			;;
		modsecurity)
			( cd "$dir" && ./build.sh && ./configure && make -j "$(nproc)" && make install ) || return 1
			mkdir -p "$INSTALL_DIR/modsec" || return 1
			cp -f "$dir/modsecurity.conf-recommended" "$INSTALL_DIR/modsec/modsecurity.conf" || return 1
			# Enable ModSecurity in Nginx
			if [[ $MODSEC_ENABLE == 'y' ]]; then
				sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "$INSTALL_DIR/modsec/modsecurity.conf" || return 1
			fi
			;;
		lua-resty-core | lua-resty-lrucache)
			( cd "$dir" && make install PREFIX=/etc/nginx ) || return 1
			;;
		lua-nginx)
			export LUAJIT_LIB=/usr/local/lib
			export LUAJIT_INC=/usr/local/include/luajit-2.1
			NGINX_OPTIONS="$NGINX_OPTIONS --with-ld-opt=-Wl,-rpath,/usr/local/lib --prefix=$INSTALL_DIR"
			;;
		geoip2)
			download_geoip_databases || return 1
			;;
		pagespeed)
			download_pagespeed_psol || return 1
			;;
		quiche)
			build_quiche_deps || return 1
			;;
	esac
}

# Apply the patch modules to the nginx source tree. The fixed order preserves
# the historical stack: TLS resize, quiche, HTTP/3, then HPACK.
apply_module_patches() {
	local src=$TEMP_INSTALL_DIR/nginx-$NGINX_VER file
	if ! module_resolved tlsdyn && ! module_resolved quiche &&
		! module_resolved http3 && ! module_resolved hpack && ! module_resolved hpack-http3; then
		return 0
	fi
	[[ -d $src ]] || { log_error "nginx source directory is missing: $src"; return 1; }
	cd "$src" || return 1
	if module_resolved tlsdyn; then
		file=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[tlsdyn]}
		[[ -f $file ]] || return 1
		patch -p1 < "$file" || return 1
	fi
	if module_resolved quiche; then
		file=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[quiche]}/nginx/nginx-1.16.patch
		[[ -f $file ]] || return 1
		patch -p01 < "$file" || return 1
	fi
	if module_resolved http3; then
		file=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[http3]}
		[[ -f $file ]] || return 1
		patch -p01 < "$file" || return 1
	fi
	if module_resolved hpack; then
		file=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[hpack]}
		[[ -f $file ]] || return 1
		patch -p1 < "$file" || return 1
	fi
	if module_resolved hpack-http3; then
		file=$TEMP_INSTALL_DIR/modules/${MODULE_DIR[hpack-http3]}
		[[ -f $file ]] || return 1
		patch -p1 < "$file" || return 1
	fi
}

download_modules() {
	local id

	# No ids means no bundle and no third-party modules.
	if [[ -z $MODULES_LIST ]]; then
		log_debug "No module ids selected; skipping the nginx-modules bundle."
		return 0
	fi

	fetch_modules_bundle || { log_error "Could not download or verify the nginx-modules bundle (${MODULES_REV})."; return 1; }
	load_modules_manifest || { log_error "Invalid or missing modules.conf in the nginx-modules bundle."; return 1; }
	resolve_modules "${MODULE_ROOTS[@]}" || return 1

	if module_resolved geoip2; then
		prepare_geoip_credentials || return 1
	fi

	# Build libraries and download payloads before nginx is configured.
	for id in "${RESOLVED_MODULES[@]}"; do
		run_module_handler "$id" || return 1
	done

	# Patches apply to the extracted nginx source tree.
	apply_module_patches || return 1

	# The verified manifest supplies the remaining configure flags.
	append_module_build_args || return 1
}

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

# Keep the informational fallback for an unspecified or unknown SSL value.
case ${SSL:-} in
1 | SYSTEM | 2 | OPENSSL | 3 | LIBRESSL) ;;
*)
	if ! module_selected openssl && ! module_selected libressl; then
		echo "SSL unspecified, fallback to system's OpenSSL ($(openssl version | cut -c9-14))"
	fi
	;;
esac

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
		if module_selected modsecurity || module_selected modsecurity-nginx; then
			apt-get install -y apt-utils libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre++-dev libyajl-dev pkgconf >>"${RUN_LOG}" 2>&1
		fi

		if module_selected geoip2; then
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
			apt-get update >>"${RUN_LOG}" 2>&1
			apt-get install -y geoipupdate >>"${RUN_LOG}" 2>&1
		fi
		if module_selected zstd; then
			apt-get install -y zstd >>"${RUN_LOG}" 2>&1
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
			if module_resolved lua-nginx; then
				export LUAJIT_LIB=/usr/local/lib
				export LUAJIT_INC=/usr/local/include/luajit-2.1
			fi
      run_ok "configure" "Running configuration..."
			# Install the default server config only when it does not exist.
			if [[ ! -f "$INSTALL_DIR/sites-available/default.conf" ]]; then
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
			else
				log_info "Keeping existing $INSTALL_DIR/sites-available/default.conf"
			fi
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
			if [[ -d $INSTALL_DIR/conf.d ]] && module_resolved lua-nginx; then
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

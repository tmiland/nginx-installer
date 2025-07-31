#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005,SC2317

## Author: Tommy Miland (@tmiland) - Copyright (c) 2025


######################################################################
####                    Nginx Installer.sh                        ####
####               Automatic nginx install script                 ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.0.0'

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2025 Tommy Miland
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
# Get script filename
self=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_FILENAME=$(basename "$self")
# Logfile
LOGFILE=$CURRDIR/nginx_installer.log
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
	grep -oP "(?<="$1" version).*?(?=[0-9]+\.[0-9]+\.[0-9](-[0-9])?</a)" |
	grep -oP "[0-9]+\.[0-9]+\.[0-9](-[0-9])?"
}
# Default Kernel version
STABLE_VER=$(latest_nginx Stable)
# Mainline kernel version
MAINLINE_VER=$(latest_nginx Mainline)
# Default kernel version without arguments
NGINX_VER=${NGINX_VER:-$STABLE_VER}
# Default nginx version name
NGINX_VER_NAME=${NGINX_VER_NAME:-stable}
# Installed kernel
CURRENT_VER=$INSTALL_DIR/installed_version
# Repo name for this script
REPO_NAME="tmiland/nginx-installer"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/main/src/slib.sh

# Define module versions
LIBRESSL_VER=${LIBRESSL_VER:-4.1.0}
OPENSSL_VER=${OPENSSL_VER:-3.5.1}
NPS_VER=${NPS_VER:-1.13.35.2}
HEADERMOD_VER=${HEADERMOD_VER:-0.39}
LIBMAXMINDDB_VER=${LIBMAXMINDDB_VER:-1.12.2}
GEOIP2_VER=${GEOIP2_VER:-3.4}
LUA_JIT_VER=${LUA_JIT_VER:-2.1-20250529}
LUA_NGINX_VER=${LUA_NGINX_VER:-0.10.28}
LUA_RESTYCORE_VER=${LUA_RESTYCORE_VER:-0.1.31}
LUA_RESTYLRUCACHE_VER=${LUA_RESTYLRUCACHE_VER:-0.15}
NGINX_DEV_KIT=${NGINX_DEV_KIT:-0.3.4}
HTTPREDIS_VER=${HTTPREDIS_VER:-0.3.9}
NGXECHO_VER=${NGXECHO_VER:-0.63}
ZSTD_VER=${ZSTD_VER:-0.1.1}

if [ -f $CURRENT_VER ]; then
  CURRENT_VER=$(cat "$CURRENT_VER")
else
	CURRENT_VER=none
fi
# Include functions
if [[ -f $CURRDIR/src/slib.sh ]]; then
  # shellcheck disable=SC1091
  . ./src/slib.sh
else
  if [[ $(command -v 'curl') ]]; then
    # shellcheck source=/dev/null
    source <(curl -sSLf $SLIB_URL)
  elif [[ $(command -v 'wget') ]]; then
    # shellcheck source=/dev/null
    . <(wget -qO - $SLIB_URL)
  else
    echo -e "${RED}${BALLOT_X} This script requires curl or wget.\nProcess aborted${NORMAL}"
    exit 0
  fi
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
  if [ -x "$TEMP_INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$TEMP_INSTALL_DIR"
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
  printf "%s\\n" "  ${YELLOW}--nginx                |-ng${NORMAL}  nginx version of choice"
  printf "%s\\n" "  ${YELLOW}--stable               |-s${NORMAL}   stable nginx version ${YELLOW}$STABLE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--mainline             |-m${NORMAL}   mainline nginx version ${YELLOW}$MAINLINE_VER${NORMAL}"
	printf "%s\\n" "  ${YELLOW}--headless             |-h${NORMAL}   headless install"
	printf "%s\\n" "  ${YELLOW}--modules-extra        |-me${NORMAL}  extra modules"
  printf "%s\\n" "  ${YELLOW}--dir                  |-d${NORMAL}   install directory"
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
    --verbose | -v)
      shift
      VERBOSE=1
      ;;
    --stable | -s)
      shift
      NGINX_VER=$STABLE_VER
      NGINX_VER_NAME=Stable
      ;;
    --mainline | -m)
      shift
      NGINX_VER=$MAINLINE_VER
      NGINX_VER_NAME=Mainline
      ;;
    --nginx | -ng)
      NGINX_VER="$2"
      NGINX_VER_NAME=Custom
      shift
      shift
      ;;
		--headless | -hl)
			shift
			HEADLESS=y
			;;
		--modules-extra | -me)
			shift
			MODULES_EXTRA=y
			;;
		--bad-bot | -bb)
			shift
			BADBOT=y
			;;
    --dir | -d) # Bash Space-Separated (e.g., --option argument)
      TEMP_INSTALL_DIR="$2" # Source: https://stackoverflow.com/a/14203146
      shift # past argument
      shift # past value
      ;;
    --nproc | -n)
      NPROC=$2
      shift
      shift
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

# Uninstall nginx
if [ "$mode" = "uninstall" ]
then
	if [ -d $INSTALL_DIR ]
	then
	systemctl stop nginx && systemctl disable nginx
	systemctl daemon-reload
	rm -rf /etc/systemd/system/nginx.service
	rm -rf /etc/logrotate.d/nginx
  if [[ $RM_CONF == 'y' ]]; then
		! test -d '$INSTALL_DIR' || rm -rf '$INSTALL_DIR'
	fi
	  ! test -f '/usr/sbin/nginx' \
	          || rm -rf '/usr/sbin/nginx'
	if [[ $RM_LOGS == 'y' ]]; then
	  ! test -d '/var/log/nginx' \
	          || rm -rf '/var/log/nginx'
	fi
  ! test -d '/var/cache/nginx' \
          || rm -rf '/var/cache/nginx'
  ! test -f '/var/run/nginx.pid' \
          || rm -rf '/var/run/nginx.pid'
  ! test -f '/var/run/nginx.lock' \
          || rm -rf '/var/run/nginx.lock'
	apt-mark unhold nginx
	if [ $? -eq 0 ]
  then
    echo ""
    echo -e "${GREEN}${DONE} Success${NORMAL}"
    echo ""
	fi
	else
		echo ""
	  echo -e "${RED}${BALLOT_X} Looks like nginx is not installed! :(${NORMAL}"
	  echo ""
	fi
  exit
fi

chk_nginx

# Start with a clean log
if [[ -f $LOGFILE ]]; then
  rm "$LOGFILE"
fi

shopt -s nocasematch
if [[ -f /etc/debian_version ]]; then
  DISTRO=$(cat /etc/issue.net)
elif [[ -f /etc/redhat-release ]]; then
  DISTRO=$(cat /etc/redhat-release)
elif [[ -f /etc/os-release ]]; then
  DISTRO=$(cat < /etc/os-release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')
fi

case "$DISTRO" in
  Debian*|Ubuntu*|LinuxMint*|PureOS*|Pop*|Devuan*)
    # shellcheck disable=SC2140
    PKGCMD="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
    LSB=lsb-release
    DISTRO_GROUP=Debian
    ;;
  CentOS*)
    PKGCMD="yum install -y"
    LSB=redhat-lsb
    DISTRO_GROUP=RHEL
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  Fedora*)
    PKGCMD="dnf install -y"
    LSB=redhat-lsb
    DISTRO_GROUP=RHEL
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  Arch*|Manjaro*)
    PKGCMD="yes | LC_ALL=en_US.UTF-8 pacman -S"
    LSB=lsb-release
    DISTRO_GROUP=Arch
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  *) echo -e "${RED}${BALLOT_X} unknown distro: '$DISTRO'${NORMAL}" ; exit 1 ;;
esac
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
  UPDATE="apt-get -o Dpkg::Progress-Fancy="1" update -qq"
  INSTALL="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
  PKGCHK="dpkg -s"
  # Install packages
  INSTALL_PKGS="wget curl git build-essential apt-transport-https ca-certificates libpcre3 libpcre3-dev autoconf unzip automake libtool tar git libssl-dev zlib1g-dev uuid-dev libxml2-dev libxslt1-dev cmake libperl-dev"
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

# Define default modules
NGINX_MODULES=${NGINX_MODULES:-"--with-select_module \
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
--with-pcre-jit"}

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

	# PageSpeed
	if [[ $PAGESPEED == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/pagespeed/ngx_pagespeed/archive/v${NPS_VER}-stable.zip
		unzip v${NPS_VER}-stable.zip
		cd incubator-pagespeed-ngx-${NPS_VER}-stable || exit 1
		psol_url=https://dl.google.com/dl/page-speed/psol/${NPS_VER}.tar.gz
		[ -e scripts/format_binary_url.sh ] && psol_url=$(scripts/format_binary_url.sh PSOL_BINARY_URL)
		wget "${psol_url}"
		tar -xzvf "$(basename "${psol_url}")"
	fi

	#Brotli
	if [[ $BROTLI == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		git clone https://github.com/google/ngx_brotli
		cd ngx_brotli || exit 1
		git checkout v1.0.0rc
		git submodule update --init
	fi

	# More Headers
	if [[ $HEADERMOD == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERMOD_VER}.tar.gz
		tar xaf v${HEADERMOD_VER}.tar.gz
	fi

	# GeoIP
	if [[ $GEOIP == 'y' ]]; then
			cd "$TEMP_INSTALL_DIR"/modules || exit 1
			# install libmaxminddb
			wget https://github.com/maxmind/libmaxminddb/releases/download/${LIBMAXMINDDB_VER}/libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz
			tar xaf libmaxminddb-${LIBMAXMINDDB_VER}.tar.gz
			cd libmaxminddb-${LIBMAXMINDDB_VER}/ || exit 1
			./configure
			make -j "$(nproc)"
			make install
			ldconfig

			cd ../ || exit 1
			wget https://github.com/leev/ngx_http_geoip2_module/archive/${GEOIP2_VER}.tar.gz
			tar xaf ${GEOIP2_VER}.tar.gz

			mkdir geoip-db
			cd geoip-db || exit 1
			# - Download GeoLite2 databases using license key
			# - Apply the correct, dated filename inside the checksum file to each download instead of a generic filename
			# - Perform all checksums
			GEOIP2_URLS=( \
			"https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-ASN&license_key="$GEOIP2_LICENSE_KEY"&suffix=tar.gz" \
			"https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key="$GEOIP2_LICENSE_KEY"&suffix=tar.gz" \
			"https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key="$GEOIP2_LICENSE_KEY"&suffix=tar.gz" \
			)
			if [[ ! -d /opt/geoip ]]; then
				for GEOIP2_URL in "${GEOIP2_URLS[@]}"; do
					echo "=== FETCHING ==="
					echo $GEOIP2_URL
					wget -O sha256 "$GEOIP2_URL.sha256"
					GEOIP2_FILENAME=$(cat sha256 | awk '{print $2}')
					mv sha256 "$GEOIP2_FILENAME.sha256"
					wget -O "$GEOIP2_FILENAME" "$GEOIP2_URL"
					echo "=== CHECKSUM ==="
					sha256sum -c "$GEOIP2_FILENAME.sha256"
				done
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
			# Download GeoIP.conf for use with geoipupdate
			if [[ ! -f /usr/local/etc/GeoIP.conf ]]; then
				cd /usr/local/etc || exit 1
				tee GeoIP.conf <<'EOF'
				# GeoIP.conf file for `geoipupdate` program, for versions >= 3.1.1.
				# Used to update GeoIP databases from https://www.maxmind.com.
				# For more information about this config file, visit the docs at
				# https://dev.maxmind.com/geoip/updating-databases?lang=en.

				# `AccountID` is from your MaxMind account.
				AccountID YOUR_ACCOUNT_ID_HERE

				# Replace YOUR_LICENSE_KEY_HERE with an active license key associated
				# with your MaxMind account.
				LicenseKey YOUR_LICENSE_KEY_HERE

				# `EditionIDs` is from your MaxMind account.
				EditionIDs GeoLite2-ASN GeoLite2-City GeoLite2-Country

EOF
				sed -i "s/YOUR_ACCOUNT_ID_HERE/${GEOIP2_ACCOUNT_ID}/g" GeoIP.conf
				sed -i "s/YOUR_LICENSE_KEY_HERE/${GEOIP2_LICENSE_KEY}/g" GeoIP.conf
			else
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
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		git clone --depth 1 https://github.com/FRiCKLE/ngx_cache_purge
	fi

	# Nginx Substitutions Filter
	if [[ $SUBFILTER == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module
	fi

	# Lua
	if [[ $LUA == 'y' ]]; then
		# LuaJIT download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/luajit2/archive/v${LUA_JIT_VER}.tar.gz
		tar xaf v${LUA_JIT_VER}.tar.gz
		cd luajit2-${LUA_JIT_VER} || exit 1
		make -j "$(nproc)"
		make install

		# ngx_devel_kit download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/simplresty/ngx_devel_kit/archive/v${NGINX_DEV_KIT}.tar.gz
		tar xaf v${NGINX_DEV_KIT}.tar.gz

		# lua-nginx-module download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VER}.tar.gz
		tar xaf v${LUA_NGINX_VER}.tar.gz

		# lua-resty-core download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/lua-resty-core/archive/v${LUA_RESTYCORE_VER}.tar.gz
		tar xaf v${LUA_RESTYCORE_VER}.tar.gz
		cd lua-resty-core-${LUA_RESTYCORE_VER} || exit 1
		make install PREFIX=/etc/nginx

		# lua-resty-lrucache download
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/lua-resty-lrucache/archive/v${LUA_RESTYLRUCACHE_VER}.tar.gz
		tar xaf v${LUA_RESTYLRUCACHE_VER}.tar.gz
		cd lua-resty-lrucache-${LUA_RESTYLRUCACHE_VER} || exit 1
		make install PREFIX=/etc/nginx
	fi

	# LibreSSL
	if [[ $LIBRESSL == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		mkdir libressl-${LIBRESSL_VER}
		cd libressl-${LIBRESSL_VER} || exit 1
		wget -qO- http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VER}.tar.gz | tar xz --strip 1

		./configure \
			LDFLAGS=-lrt \
			CFLAGS=-fstack-protector-strong \
			--prefix="$TEMP_INSTALL_DIR"/modules/libressl-${LIBRESSL_VER}/.openssl/ \
			--enable-shared=no

		make install-strip -j "$(nproc)"
	fi

	# OpenSSL
	if [[ $OPENSSL == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz
		tar xaf openssl-${OPENSSL_VER}.tar.gz
		cd openssl-${OPENSSL_VER} || exit 1

		./config
	fi

	# ModSecurity
	if [[ $MODSEC == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		git clone --depth 1 -b v3/master --single-branch https://github.com/SpiderLabs/ModSecurity
		cd ModSecurity || exit 1
		git submodule init
		git submodule update
		./build.sh
		./configure
		make -j "$(nproc)"
		make install
		mkdir $INSTALL_DIR/modsec
		wget -P $INSTALL_DIR/modsec/ https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended
		mv $INSTALL_DIR/modsec/modsecurity.conf-recommended $INSTALL_DIR/modsec/modsecurity.conf

		# Enable ModSecurity in Nginx
		if [[ $MODSEC_ENABLE == 'y' ]]; then
			sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' $INSTALL_DIR/modsec/modsecurity.conf
		fi
	fi

	# Download ngx_http_redis
	if [[ $HTTPREDIS == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://people.freebsd.org/~osa/ngx_http_redis-${HTTPREDIS_VER}.tar.gz
		tar xaf ngx_http_redis-${HTTPREDIS_VER}.tar.gz
	fi

	# Download ngx_devel_kit if LUA = no
	if [[ $SETMISC == 'y' && $LUA == 'n' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/simplresty/ngx_devel_kit/archive/v${NGINX_DEV_KIT}.tar.gz
		tar xaf v${NGINX_DEV_KIT}.tar.gz
	fi

	# Download echo-nginx-module
	if [[ $NGXECHO == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/openresty/echo-nginx-module/archive/refs/tags/v${NGXECHO_VER}.tar.gz
		tar xaf v${NGXECHO_VER}.tar.gz
	fi

	if [[ $ZSTD == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		wget https://github.com/tokers/zstd-nginx-module/archive/refs/tags/${ZSTD_VER}.tar.gz
		tar xaf ${ZSTD_VER}.tar.gz
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
		git clone --depth 1 --quiet https://github.com/aperezdc/ngx-fancyindex.git "$TEMP_INSTALL_DIR"/modules/fancyindex
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/fancyindex
		)
	fi

	if [[ $WEBDAV == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/arut/nginx-dav-ext-module.git "$TEMP_INSTALL_DIR"/modules/nginx-dav-ext-module
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --with-http_dav_module --add-module="$TEMP_INSTALL_DIR"/modules/nginx-dav-ext-module
		)
	fi

	if [[ $VTS == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/vozlt/nginx-module-vts.git "$TEMP_INSTALL_DIR"/modules/nginx-module-vts
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/nginx-module-vts
		)
	fi

	if [[ $RTMP == 'y' ]]; then
		git clone --quiet https://github.com/arut/nginx-rtmp-module.git "$TEMP_INSTALL_DIR"/modules/nginx-rtmp-module
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/nginx-rtmp-module
		)
	fi

	if [[ $TESTCOOKIE == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/kyprizel/testcookie-nginx-module.git "$TEMP_INSTALL_DIR"/modules/testcookie-nginx-module
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/testcookie-nginx-module
		)
	fi

	if [[ $MODSEC == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/SpiderLabs/ModSecurity-nginx.git "$TEMP_INSTALL_DIR"/modules/ModSecurity-nginx
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/ModSecurity-nginx
		)
	fi

	if [[ $REDIS2 == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/openresty/redis2-nginx-module.git "$TEMP_INSTALL_DIR"/modules/redis2-nginx-module
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
		git clone --depth 1 --quiet https://github.com/openresty/srcache-nginx-module.git "$TEMP_INSTALL_DIR"/modules/srcache-nginx-module
		NGINX_MODULES=$(
			echo "$NGINX_MODULES"
			echo --add-module="$TEMP_INSTALL_DIR"/modules/srcache-nginx-module
		)
	fi

	if [[ $SETMISC == 'y' ]]; then
		git clone --depth 1 --quiet https://github.com/openresty/set-misc-nginx-module.git "$TEMP_INSTALL_DIR"/modules/set-misc-nginx-module
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
		wget https://raw.githubusercontent.com/nginx-modules/ngx_http_tls_dyn_size/master/nginx__dynamic_tls_records_1.17.7%2B.patch -O tcp-tls.patch
		patch -p1 <tcp-tls.patch
	fi

	# HTTP3
	if [[ $HTTP3 == 'y' ]]; then
		cd "$TEMP_INSTALL_DIR"/modules || exit 1
		git clone --depth 1 --recursive https://github.com/cloudflare/quiche
		# Dependencies for BoringSSL and Quiche
		apt-get install -y golang
		# Rust is not packaged so that's the only way...
		curl -sSf https://sh.rustup.rs | sh -s -- -y
		source "$HOME/.cargo/env"

		cd "$TEMP_INSTALL_DIR"/nginx-${NGINX_VER} || exit 1
		# Apply actual patch
		patch -p01 <"$TEMP_INSTALL_DIR"/modules/quiche/nginx/nginx-1.16.patch

		# Apply patch for nginx > 1.19.7 (source: https://github.com/cloudflare/quiche/issues/936#issuecomment-857618081)
		wget https://raw.githubusercontent.com/angristan/nginx-autoinstall/master/patches/nginx-http3-1.19.7.patch -O nginx-http3.patch
		patch -p01 <nginx-http3.patch

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
			wget https://raw.githubusercontent.com/hakasenyang/openssl-patch/master/nginx_hpack_push_1.15.3.patch -O nginx_http2_hpack.patch

		else
			# Same patch as above but fixed conflicts with the HTTP/3 patch
			wget https://raw.githubusercontent.com/angristan/nginx-autoinstall/master/patches/nginx_hpack_push_with_http3.patch -O nginx_http2_hpack.patch
		fi
		patch -p1 <nginx_http2_hpack.patch

		NGINX_OPTIONS=$(
			echo "$NGINX_OPTIONS"
			echo --with-http_v2_hpack_enc
		)
	fi

}

configure() {
  auto/configure $NGINX_OPTIONS $NGINX_MODULES
  # --with-debug
}

bad_bot_blocker() {
	# Install Bad Bot Blocker
		wget https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker
		chmod +x /usr/local/sbin/install-ngxblocker
		cd /usr/local/sbin/ || exit 1
		./install-ngxblocker -x
		chmod +x /usr/local/sbin/setup-ngxblocker
		chmod +x /usr/local/sbin/update-ngxblocker
		cd /usr/local/sbin/ || exit 1
		./setup-ngxblocker -x -e conf
}

install_nginx() {
  clear
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing Nginx version:${NORMAL} $NGINX_VER_NAME: ${YELLOW}$NGINX_VER${NORMAL}"
  echo
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
  log_debug "Phase 2 of 5: Nginx source code download"
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}6${NORMAL}: Download Nginx source code"
  if [ ! -d "$TEMP_INSTALL_DIR" ]; then
    mkdir "$TEMP_INSTALL_DIR" 1>/dev/null 2>&1
  fi
  if [ -d "$TEMP_INSTALL_DIR" ]; then
    log_debug "Deleting old Nginx source code files in $TEMP_INSTALL_DIR"
    rm -rf "$TEMP_INSTALL_DIR" && mkdir -p "$TEMP_INSTALL_DIR"
    cd "$TEMP_INSTALL_DIR" || exit 1
    log_debug "Downloading Nginx source code"
    run_ok "git clone https://github.com/nginx/nginx.git \"$TEMP_INSTALL_DIR\"/nginx-\"${NGINX_VER}\" >>\"${RUN_LOG}\" 2>&1" "Downloading nginx..."
    log_success "Download finished"
		echo
    cd nginx-"${NGINX_VER}" || exit 0
    if [ $NGINX_VER_NAME = "stable" ]; then
			STABLE_VER="${STABLE_VER//.0/}"
      git checkout "$NGINX_VER_NAME"-"$STABLE_VER" >>"${RUN_LOG}" 2>&1
    fi
		log_debug "Phase 3 of 6: Nginx modules download"
	  printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}6${NORMAL}: Download Nginx modules"
		if [ ! -d "$TEMP_INSTALL_DIR"/modules ]; then
		  mkdir -p "$TEMP_INSTALL_DIR"/modules
		fi
		log_debug "Downloading Nginx modules"
		run_ok "download_modules" "Downloading modules..."
		log_success "Module download finished"
		
  fi
  if [ -d "$TEMP_INSTALL_DIR"/nginx-"${NGINX_VER}" ]; then
    (
      cd "$TEMP_INSTALL_DIR"/nginx-"${NGINX_VER}" || exit 1
      echo
      # Config
      log_debug "Phase 4 of 5: Configuration"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}6${NORMAL}: Setup nginx"
      log_debug "Configuring..."
			sed -i "435i\        ngx_write_stderr(\"built with Nginx Installer @tmiland\" NGX_LINEFEED);" src/core/nginx.c
			if [[ $LUA == 'y' ]]; then
				export LUAJIT_LIB=/usr/local/lib
				export LUAJIT_INC=/usr/local/include/luajit-2.1
			fi
      run_ok "configure" "Running configuration..."
			# Install default nginx server configuration
			mkdir -p $INSTALL_DIR
			tee $INSTALL_DIR/sites-available/default.conf <<EOF >>"${RUN_LOG}" 2>&1
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
			sed -n '13 s/[^0-9.]*\([0-9.]*\).*/\1/p' ./src/core/nginx.h > $INSTALL_DIR/installed_version >>"${RUN_LOG}" 2>&1
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
    )
  fi

  echo
  # Cleanup
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} Cleaning up"
  if [ "$TEMP_INSTALL_DIR" != "" ] && [ "$TEMP_INSTALL_DIR" != "/" ]; then
    log_debug "Cleaning up temporary files in $TEMP_INSTALL_DIR."
    find "$TEMP_INSTALL_DIR" -delete
  else
    log_error "Could not safely clean up temporary files because INSTALL DIR set to $TEMP_INSTALL_DIR."
  fi
  # Make sure the cursor is back (if spinners misbehaved)
  tput cnorm
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} All ${GREEN}6${NORMAL} phases finished successfully"
}

# Start Script
chk_permissions

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
  if [ -x "$TEMP_INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$TEMP_INSTALL_DIR"
  fi
fi

exit

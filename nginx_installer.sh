#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005

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
INSTALL_DIR=${INSTALL_DIR:-/opt/nginx}
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
CURRENT_VER=/etc/nginx/installed_version
# Repo name for this script
REPO_NAME="tmiland/nginx-installer"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/main/src/slib.sh

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
  if [ -x "$INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$INSTALL_DIR"
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
  echo "  If called without arguments, installs stable nginx ${YELLOW}${NGINX_VER}${NORMAL} using ${INSTALL_DIR}"
  echo
  printf "%s\\n" "  ${YELLOW}--help                 |-h${NORMAL}   display this help and exit"
  printf "%s\\n" "  ${YELLOW}--nginx                |-ng${NORMAL}  nginx version of choice"
  printf "%s\\n" "  ${YELLOW}--stable               |-s${NORMAL}   stable nginx version ${YELLOW}$STABLE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--mainline             |-m${NORMAL}   mainline nginx version ${YELLOW}$MAINLINE_VER${NORMAL}"
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
    --dir | -d) # Bash Space-Separated (e.g., --option argument)
      INSTALL_DIR="$2" # Source: https://stackoverflow.com/a/14203146
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
	if [ -d /etc/nginx ]
	then
	systemctl stop nginx && systemctl disable nginx
	systemctl daemon-reload
	rm -rf /etc/systemd/system/nginx.service
	rm -rf /etc/logrotate.d/nginx
  ! test -d '/etc/nginx' || rm -rf '/etc/nginx'
  ! test -f '/usr/sbin/nginx' \
          || rm -rf '/usr/sbin/nginx'
  ! test -d '/var/log/nginx' \
          || rm -rf '/var/log/nginx'
  ! test -d '/var/cache/nginx' \
          || rm -rf '/var/cache/nginx'
  ! test -f '/var/run/nginx.pid' \
          || rm -rf '/var/run/nginx.pid'
  ! test -f '/var/run/nginx.lock' \
          || rm -rf '/var/run/nginx.lock'
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
  INSTALL_PKGS="wget curl git libpcre3-dev zlib1g-dev libssl-dev apt-transport-https"
else
  echo -e "${RED}${BALLOT_X} Error: Sorry, your OS is not supported.${NORMAL}"
  exit 1;
fi

configure() {
  auto/configure \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --conf-path=/etc/nginx/nginx.conf \
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
  --with-cc-opt=-Wno-ignored-qualifiers \
  --with-ld-opt=-Wl,-rpath,/usr/local/lib/ \
  --with-select_module \
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
  --with-pcre-jit \
  --with-debug
}

install_nginx() {
  clear
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing Nginx version:${NORMAL} $NGINX_VER_NAME: ${YELLOW}$NGINX_VER${NORMAL}"
  echo
  printf "%s \\n" "${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}1${NORMAL} of ${GREEN}5${NORMAL}: Setup packages"
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
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}5${NORMAL}: Download Nginx source code"
  if [ ! -d "$INSTALL_DIR" ]; then
    mkdir "$INSTALL_DIR" 1>/dev/null 2>&1
  fi
  if [ -d "$INSTALL_DIR" ]; then
    log_debug "Deleting old Nginx source code files in $INSTALL_DIR"
    rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    log_debug "Downloading Nginx source code"
    run_ok "git clone https://github.com/nginx/nginx.git \"$INSTALL_DIR\"/nginx-\"${NGINX_VER}\" >>\"${RUN_LOG}\" 2>&1" "Downloading..."
    log_success "Download finished"
    cd nginx-"${NGINX_VER}" || exit 0
    if [ $NGINX_VER_NAME = "stable" ]; then
			STABLE_VER="${STABLE_VER//.0/}"
      git checkout "$NGINX_VER_NAME"-"$STABLE_VER" >>"${RUN_LOG}" 2>&1
    fi
  fi
  if [ -d "$INSTALL_DIR"/nginx-"${NGINX_VER}" ]; then
    (
      cd "$INSTALL_DIR"/nginx-"${NGINX_VER}" || exit 1
      echo
      # Config
      log_debug "Phase 3 of 5: Configuration"
      printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}5${NORMAL}: Setup nginx"
      log_debug "Configuring..."
			sed -i "435i\        ngx_write_stderr(\"Built by Nginx Installer @tmiland\" NGX_LINEFEED);" src/core/nginx.c
      run_ok "configure" "Running configuration..."
			# Install default nginx server configuration
			mkdir -p /etc/nginx
			tee /etc/nginx/sites-available/default.conf <<'EOF' >>"${RUN_LOG}" 2>&1
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _; # This is just an invalid value which will never trigger on a real hostname.
  #access_log logs/default.access.log main;

  server_name_in_redirect off;

  root  /etc/nginx/html;
}
EOF
			# Install systemd configuration
			tee /etc/systemd/system/nginx.service <<'EOF' >>"${RUN_LOG}" 2>&1
[Unit]
Description=nginx - high performance web server
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStart=/usr/sbin/nginx -c /etc/nginx/nginx.conf
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
			  ! test -d /etc/nginx || mkdir -p /etc/nginx/$f >>"${RUN_LOG}" 2>&1
			done
			mkdir -p /var/cache/nginx ||
			mkdir -p /var/cache/nginx/client_temp >>"${RUN_LOG}" 2>&1
			if ! id -u "nginx" >/dev/null 2>&1; then
    		run_ok "useradd --no-create-home nginx" "Adding nginx user"
			fi
      log_success "Configuration finished"
      read_sleep 1
      echo
      # Compilation
      log_debug "Phase 4 of 5: Compilation"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}5${NORMAL}: Nginx Compilation"
      log_debug "Compiling The Nginx source code"
      printf "%s \\n" "Go grab a coffee ☕ 😎 This may take a while..."
      run_ok "make -j${NPROC}" "Compiling Nginx source code..."
      log_success "Compiling finished"
      echo
      # Installation
      log_debug "Phase 5 of 5: Installation"
      printf "%s \\n" "${GREEN}▣▣▣▣${YELLOW}▣${NORMAL} Phase ${YELLOW}5${NORMAL} of ${GREEN}5${NORMAL}: Nginx Installation"
      log_debug "Installing Nginx source code"
      run_ok "make install" "Installing Nginx source code..."
			sed -n '13 s/[^0-9.]*\([0-9.]*\).*/\1/p' ./src/core/nginx.h > /etc/nginx/installed_version
			run_ok "nginx -t && systemctl restart nginx" "Restarting nginx..."
      log_success "Installation finished"
      cd - 1>/dev/null 2>&1 || exit 1
    )
  fi

  echo
  # Cleanup
  printf "%s \\n" "${GREEN}▣▣▣▣▣${NORMAL} Cleaning up"
  if [ "$INSTALL_DIR" != "" ] && [ "$INSTALL_DIR" != "/" ]; then
    log_debug "Cleaning up temporary files in $INSTALL_DIR."
    find "$INSTALL_DIR" -delete
  else
    log_error "Could not safely clean up temporary files because INSTALL DIR set to $INSTALL_DIR."
  fi
  # Make sure the cursor is back (if spinners misbehaved)
  tput cnorm
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} All ${GREEN}5${NORMAL} phases finished successfully"
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
  if [ -x "$INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$INSTALL_DIR"
  fi
fi

exit

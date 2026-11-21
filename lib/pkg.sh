# shellcheck shell=bash
# Package-manager abstraction. Modules ask for logical package names and this
# layer maps them to real names and commands for the current family:
#   apt     Ubuntu, Debian, Kali
#   dnf     Fedora, AlmaLinux (+ EPEL), Rocky, Oracle Linux
#   pacman  Arch Linux

SUPPORTED_FAMILIES='apt dnf pacman'

# Modules run in subshells, so "index already refreshed" is tracked with a
# marker file in RUN_DIR (set by install.sh) instead of a variable.
RUN_DIR=${RUN_DIR:-}
_pkg_index_marker() { printf '%s' "${RUN_DIR:-/nonexistent}/pkg-index-fresh"; }

# pkg_require_supported: abort when the detected family is not supported.
pkg_require_supported() {
  [[ " $SUPPORTED_FAMILIES " == *" $DISTRO_FAMILY "* ]] && return 0
  die "Detected $DISTRO_NAME (family: $DISTRO_FAMILY). wslforge supports apt, dnf and pacman distros (Ubuntu, Debian, Fedora, AlmaLinux, Arch)."
}

# pkg_map NAME: print the real package name(s) for a logical name, or "-"
# when the current family has no package for it.
pkg_map() {
  case "$1:$DISTRO_FAMILY" in
    build-tools:apt) echo build-essential ;;
    # libatomic: Node.js needs it at runtime and minimal RHEL images lack it.
    build-tools:dnf) echo gcc gcc-c++ make libatomic ;;
    build-tools:pacman) echo base-devel ;;
    gnupg:dnf) echo gnupg2 ;;
    fd:apt | fd:dnf) echo fd-find ;;
    ssh-client:apt) echo openssh-client ;;
    ssh-client:dnf) echo openssh-clients ;;
    ssh-client:pacman) echo openssh ;;
    gh:pacman) echo github-cli ;;
    *) echo "$1" ;;
  esac
}

# pkg_available NAME: true when the current family has a package for NAME.
pkg_available() {
  [[ $(pkg_map "$1") != - ]]
}

# pkg_is_installed REAL_NAME: true when the package (or something that
# provides it) is installed.
pkg_is_installed() {
  case $DISTRO_FAMILY in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    pacman) pacman -T "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# pkgs_installed NAME...: true when all logical packages are installed.
pkgs_installed() {
  local name real
  for name in "$@"; do
    for real in $(pkg_map "$name"); do
      [[ $real == - ]] && return 1
      pkg_is_installed "$real" || return 1
    done
  done
}

# _pkg_is_enterprise: RHEL rebuilds, which need EPEL for most CLI tools.
_pkg_is_enterprise() {
  [[ $DISTRO_FAMILY == dnf && $DISTRO_ID != fedora ]]
}

# _pkg_enable_epel: add EPEL (Extra Packages for Enterprise Linux) once.
_pkg_enable_epel() {
  local release=epel-release
  if [[ $DISTRO_ID == ol ]]; then
    release="oracle-epel-release-el${DISTRO_VERSION%%.*}"
  fi
  pkg_is_installed "$release" || as_root dnf install -y "$release"
}

# pkg_update: refresh the package index (at most once per run). On Arch this
# is a full upgrade: partial upgrades are not supported there.
pkg_update() {
  [[ -e $(_pkg_index_marker) ]] && return 0
  case $DISTRO_FAMILY in
    apt) as_root apt-get update -y ;;
    dnf)
      if _pkg_is_enterprise; then
        _pkg_enable_epel
      fi
      as_root dnf makecache -y
      ;;
    pacman) as_root pacman -Syu --noconfirm ;;
  esac
  if [[ -n $RUN_DIR ]]; then
    touch "$(_pkg_index_marker)"
  fi
}

# pkg_install NAME...: install the logical packages that are missing.
pkg_install() {
  local name real missing=()
  for name in "$@"; do
    for real in $(pkg_map "$name"); do
      [[ $real == - ]] && continue
      pkg_is_installed "$real" || missing+=("$real")
    done
  done
  ((${#missing[@]})) || return 0

  pkg_update
  pkg_install_real "${missing[@]}"
}

# pkg_install_real PACKAGE...: install real package names (no mapping).
pkg_install_real() {
  case $DISTRO_FAMILY in
    apt) as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) as_root dnf install -y "$@" ;;
    pacman) as_root pacman -S --needed --noconfirm "$@" ;;
  esac
}

# rpm_add_repo NAME URL: add a third-party dnf .repo file. Its
# signing key is imported on the first install from it.
rpm_add_repo() {
  local dir=/etc/yum.repos.d
  [[ -s $dir/$1.repo ]] && return 0
  as_root install -d -m 755 "$dir"
  download_root "$2" "$dir/$1.repo"
  rm -f "$(_pkg_index_marker)"
}

# apt_add_repo NAME KEY_URL "URI SUITE COMPONENTS": add a signed third-party
# apt repository. The key is stored in /etc/apt/keyrings (binary keys must end
# in .gpg; anything else is treated as an ASCII-armored .asc key).
apt_add_repo() {
  local name=$1 key_url=$2 source=$3 ext=asc
  [[ $key_url == *.gpg ]] && ext=gpg
  local keyring="/etc/apt/keyrings/$name.$ext"
  local list="/etc/apt/sources.list.d/$name.list"
  local arch
  arch=$(dpkg --print-architecture)

  as_root install -d -m 755 /etc/apt/keyrings
  [[ -s $keyring ]] || download_root "$key_url" "$keyring"
  write_root_file "$list" "deb [arch=$arch signed-by=$keyring] $source"
  rm -f "$(_pkg_index_marker)"
}

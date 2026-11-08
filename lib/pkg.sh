# shellcheck shell=bash
# Package-manager abstraction. Modules ask for logical package names and this
# layer maps them to real names for the current family. Only apt is
# implemented so far; other families are detected but not supported yet.

SUPPORTED_FAMILIES='apt'

# Modules run in subshells, so "index already refreshed" is tracked with a
# marker file in RUN_DIR (set by install.sh) instead of a variable.
RUN_DIR=${RUN_DIR:-}
_pkg_index_marker() { printf '%s' "${RUN_DIR:-/nonexistent}/pkg-index-fresh"; }

# pkg_require_supported: abort when the detected family is not supported.
pkg_require_supported() {
  [[ " $SUPPORTED_FAMILIES " == *" $DISTRO_FAMILY "* ]] && return 0
  die "Detected $DISTRO_NAME (family: $DISTRO_FAMILY). wslforge currently supports apt-based distros only (Ubuntu, Debian)."
}

# pkg_map NAME: print the real package name(s) for a logical name.
pkg_map() {
  case "$1:$DISTRO_FAMILY" in
    build-tools:apt) echo build-essential ;;
    build-tools:dnf) echo @development-tools ;;
    build-tools:pacman) echo base-devel ;;
    fd:apt | fd:dnf) echo fd-find ;;
    ssh-client:apt) echo openssh-client ;;
    ssh-client:dnf) echo openssh-clients ;;
    ssh-client:pacman) echo openssh ;;
    *) echo "$1" ;;
  esac
}

# pkg_is_installed REAL_NAME: true when the package is installed.
pkg_is_installed() {
  case $DISTRO_FAMILY in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    *) return 1 ;;
  esac
}

# pkgs_installed NAME...: true when all logical packages are installed.
pkgs_installed() {
  local name real
  for name in "$@"; do
    for real in $(pkg_map "$name"); do
      pkg_is_installed "$real" || return 1
    done
  done
}

# pkg_update: refresh the package index (at most once per run).
pkg_update() {
  [[ -e $(_pkg_index_marker) ]] && return 0
  case $DISTRO_FAMILY in
    apt) as_root apt-get update -y ;;
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
      pkg_is_installed "$real" || missing+=("$real")
    done
  done
  ((${#missing[@]})) || return 0

  pkg_update
  case $DISTRO_FAMILY in
    apt) as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
  esac
}

# apt_add_repo NAME KEY_URL "URI SUITE COMPONENTS": add a signed third-party
# apt repository. The key is stored in /etc/apt/keyrings.
apt_add_repo() {
  local name=$1 key_url=$2 source=$3
  local keyring="/etc/apt/keyrings/$name.${key_url##*.}"
  local list="/etc/apt/sources.list.d/$name.list"
  local arch
  arch=$(dpkg --print-architecture)

  as_root install -d -m 755 /etc/apt/keyrings
  [[ -s $keyring ]] || download_root "$key_url" "$keyring"
  write_root_file "$list" "deb [arch=$arch signed-by=$keyring] $source"
  rm -f "$(_pkg_index_marker)"
}

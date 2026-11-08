# shellcheck shell=bash disable=SC2034
# Distro detection: reads /etc/os-release and maps the distro to a
# package-manager family (apt, dnf, pacman, zypper).
# (SC2034: the DISTRO_* variables are read by install.sh and the modules.)

DISTRO_ID=''       # e.g. debian, ubuntu
DISTRO_NAME=''     # e.g. "Debian GNU/Linux 13 (trixie)"
DISTRO_VERSION=''  # e.g. 13, 24.04
DISTRO_CODENAME='' # e.g. trixie, noble (used by third-party apt repos)
DISTRO_FAMILY=''   # apt | dnf | pacman | zypper | unknown

# detect_distro: fill the DISTRO_* variables.
detect_distro() {
  local file=${OS_RELEASE_FILE:-/etc/os-release}
  [[ -r $file ]] || die "Cannot detect the distro: $file not found."

  local id like name version codename
  # Source in a subshell so os-release variables do not leak into ours.
  # Fields are split on \x1f (not a tab) so empty values are preserved.
  # shellcheck disable=SC1090
  IFS=$'\x1f' read -r id like name version codename < <(
    . "$file"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-${NAME:-}}" \
      "${VERSION_ID:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  )

  DISTRO_ID=$id
  DISTRO_NAME=${name:-$id}
  DISTRO_VERSION=$version
  DISTRO_CODENAME=$codename
  DISTRO_FAMILY=$(distro_family "$id" "$like")
}

# distro_family ID [ID_LIKE]: print the package-manager family.
distro_family() {
  local candidate
  # ID_LIKE is a space-separated list, so word splitting is intended.
  # shellcheck disable=SC2086
  for candidate in $1 ${2:-}; do
    case $candidate in
      debian | ubuntu | kali | linuxmint | pop) echo apt; return ;;
      fedora | rhel | centos | almalinux | rocky | ol) echo dnf; return ;;
      arch | archlinux | manjaro | endeavouros) echo pacman; return ;;
      opensuse* | suse | sles) echo zypper; return ;;
    esac
  done
  echo unknown
}

# is_wsl: true when running in a WSL distro. The kernel name is not enough:
# Docker containers on a WSL host share the same "microsoft" kernel.
is_wsl() {
  [[ -n ${WSL_DISTRO_NAME:-} || -d /run/WSL ]]
}

# shellcheck shell=bash disable=SC2034
# Base packages every other module relies on (compilers, curl, gnupg, ...).

MODULE_NAME='Base packages'
MODULE_DESC='Build tools, curl, wget, gnupg, zip/unzip, jq, htop, tree'
MODULE_ORDER=10
MODULE_DEFAULT=on
MODULE_REQUIRED=yes
MODULE_FAMILIES='apt'

BASE_PACKAGES=(build-tools ca-certificates curl wget gnupg zip unzip jq htop tree less)

is_installed() {
  pkgs_installed "${BASE_PACKAGES[@]}"
}

do_install() {
  pkg_install "${BASE_PACKAGES[@]}"
}

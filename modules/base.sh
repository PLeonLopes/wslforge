# shellcheck shell=bash disable=SC2034
# Base packages every other module relies on (compilers, curl, gnupg, ...).

MODULE_NAME='Base packages'
MODULE_ORDER=10
MODULE_DEFAULT=on
MODULE_REQUIRED=yes
MODULE_FAMILIES='apt'

# "id|description". Item ids are logical package names (see lib/pkg.sh).
MODULE_ITEMS=(
  'build-tools|Compilers and make (build-essential)'
  'ca-certificates|Trusted certificates for HTTPS'
  'curl|Transfer data from URLs'
  'gnupg|Verify signatures of third-party repositories'
  'wget|Download files from the web'
  'zip|Create .zip archives'
  'unzip|Extract .zip archives'
  'jq|Query and edit JSON on the command line'
  'htop|Interactive process viewer'
  'tree|Show directories as a tree'
  'less|Scroll through long output and files'
)

is_installed() {
  pkgs_installed "$1"
}

do_install() {
  pkg_install "$@"
}

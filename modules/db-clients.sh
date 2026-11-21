# shellcheck shell=bash disable=SC2034
# Command-line clients for common databases (no servers are installed).

MODULE_NAME='Database clients'
MODULE_ORDER=67
MODULE_GROUP='Databases'
MODULE_DEFAULT=off
MODULE_FAMILIES='apt dnf pacman'

MODULE_ITEMS=(
  'psql|PostgreSQL client'
  'mysql|MySQL and MariaDB client (from MariaDB)'
  'redis-cli|Redis client (valkey-cli where the distro ships Valkey)'
  'sqlite3|SQLite shell'
)

# Item id -> logical package name (see pkg_map in lib/pkg.sh).
_db_package() {
  case $1 in
    psql) echo postgresql-client ;;
    mysql) echo mariadb-client ;;
    *) echo "$1" ;;
  esac
}

is_available() {
  pkg_available "$(_db_package "$1")"
}

is_installed() {
  case $1 in
    mysql) has_cmd mysql || has_cmd mariadb ;;
    redis-cli) has_cmd redis-cli || has_cmd valkey-cli ;;
    *) has_cmd "$1" ;;
  esac
}

do_install() {
  local item packages=()
  for item in "$@"; do
    packages+=("$(_db_package "$item")")
  done
  pkg_install "${packages[@]}"
}

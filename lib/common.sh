# shellcheck shell=bash
# Shared helpers: logging, prompts, and command execution with dry-run support.

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

DRY_RUN=0     # 1 = only print commands that would change the system
ASSUME_YES=0  # 1 = never prompt; use defaults and skip confirmations

# ---------------------------------------------------------------- logging

log_step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
log_info()  { printf '    %s\n' "$*"; }
log_ok()    { printf '    %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ---------------------------------------------------------------- checks

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# in_list NEEDLE ITEM...: true when NEEDLE is one of the items.
in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- execution

_print_dry() { printf '    %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

# run CMD...: execute a command, or only print it in dry-run mode.
run() {
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "$*"
    return 0
  fi
  "$@"
}

# as_root CMD...: like run, but as root (via sudo unless already root).
as_root() {
  if [[ $EUID -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

# write_root_file PATH CONTENT: create or replace a root-owned file.
write_root_file() {
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "write $1: $2"
    return 0
  fi
  printf '%s\n' "$2" | as_root tee "$1" >/dev/null
}

# download_root URL PATH: download URL into a root-owned file (mode 644).
download_root() {
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "download $1 -> $2"
    return 0
  fi
  local tmp rc=0
  tmp=$(mktemp)
  if ! curl -fsSL "$1" -o "$tmp" || ! as_root install -m 644 "$tmp" "$2"; then
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------- prompts
# Prompts read from /dev/tty so they also work when the script is piped
# (curl | bash). They fail when there is no terminal or --yes was given.

# confirm QUESTION: true when the user answers yes (Enter means yes).
confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  local reply
  { exec 3</dev/tty; } 2>/dev/null || return 1
  read -r -u 3 -p "$1 [Y/n] " reply || reply=n
  exec 3<&-
  [[ -z $reply || $reply =~ ^[Yy] ]]
}

# ask QUESTION [DEFAULT]: print the user's answer (or DEFAULT on Enter).
ask() {
  [[ $ASSUME_YES == 1 ]] && return 1
  local reply
  { exec 3</dev/tty; } 2>/dev/null || return 1
  read -r -u 3 -p "    $1${2:+ [$2]}: " reply || reply=
  exec 3<&-
  printf '%s' "${reply:-${2:-}}"
}

# shellcheck shell=bash
# Shared helpers: logging, prompts, and command execution with dry-run support.

# Forge: wslforge's visual identity. Every color in the UI comes from here.
#   ember     accent: cursor, selection, borders, "+" marks
#   amber     headings and step titles
#   ash       secondary text and hints
#   text      body text on dark backgrounds
#   moss      success
#   charcoal  text on ember buttons
#   iron      inactive buttons
# Hex values feed gum (it adapts them to the terminal); the C_* codes below
# are their closest 256-color ANSI matches for plain output.
# shellcheck disable=SC2034  # the hex values are read by lib/ui.sh
FORGE_EMBER='#FF8A3D' FORGE_AMBER='#FFC857' FORGE_ASH='#8A817A' \
  FORGE_TEXT='#E8E2DA' FORGE_MOSS='#9CCC65' FORGE_CHARCOAL='#1A1410' FORGE_IRON='#2B2622'

# Colors only on a terminal, and never when NO_COLOR is set (no-color.org).
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
  C_EMBER=$'\033[38;5;209m' C_AMBER=$'\033[38;5;221m' C_ASH=$'\033[38;5;245m'
  C_MOSS=$'\033[38;5;149m' C_RED=$'\033[38;5;203m'
else
  C_RESET='' C_BOLD='' C_EMBER='' C_AMBER='' C_ASH='' C_MOSS='' C_RED=''
fi

DRY_RUN=0     # 1 = only print commands that would change the system
ASSUME_YES=0  # 1 = never prompt; use defaults and skip confirmations

# ---------------------------------------------------------------- logging

log_step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_AMBER" "$*" "$C_RESET"; }
log_info()  { printf '    %s\n' "$*"; }
log_ok()    { printf '    %s✔%s %s\n' "$C_MOSS" "$C_RESET" "$*"; }
log_warn()  { printf '    %s!%s %s\n' "$C_EMBER" "$C_RESET" "$*" >&2; }
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

# join_by SEPARATOR ITEM...: print the items joined by SEPARATOR.
join_by() {
  local sep=$1 out='' item
  shift
  [[ $# -gt 0 ]] || return 0
  out=$1
  shift
  for item in "$@"; do
    out+="$sep$item"
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------- execution

_print_dry() { printf '    %s[dry-run]%s %s\n' "$C_ASH" "$C_RESET" "$*"; }

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

# run_installer URL PROGRAM [ARGS...]: download an official install script and
# run it with PROGRAM (sh or bash). The script is saved first, so a partial
# download is never executed.
run_installer() {
  local url=$1 program=$2
  shift 2
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "curl -fsSL $url | $program${*:+ -s -- $*}"
    return 0
  fi
  local tmp rc=0
  tmp=$(mktemp)
  if curl -fsSL "$url" -o "$tmp"; then
    SHELL=${SHELL:-/bin/bash} "$program" "$tmp" "$@" || rc=$?
  else
    rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}

# need_new_shell REASON [GROUP]: record that the user needs a fresh shell
# (e.g. new PATH entries or a new group). install.sh offers one at the end
# instead of every module printing its own "open a new terminal" note.
need_new_shell() {
  [[ -n ${RUN_DIR:-} ]] || return 0
  printf '%s|%s\n' "$1" "${2:-}" >>"$RUN_DIR/new-shell"
}

# ---------------------------------------------------------------- ini files

# ini_get FILE SECTION KEY: print the value of KEY in [SECTION].
ini_get() {
  [[ -r $1 ]] || return 1
  awk -v s="$2" -v k="$3" '
    /^[[:space:]]*\[/ { sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); next }
    sec == s && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; found = 1; exit
    }
    END { exit !found }' "$1"
}

# ensure_ini_key FILE SECTION KEY VALUE: set KEY=VALUE in [SECTION] of a
# root-owned INI file (e.g. /etc/wsl.conf), keeping every other line intact.
ensure_ini_key() {
  local file=$1 section=$2 key=$3 value=$4 content=''
  [[ $(ini_get "$file" "$section" "$key" 2>/dev/null) == "$value" ]] && return 0

  if [[ -r $file ]]; then
    # Blank lines are held back so a new key lands right after the section's
    # last entry, not after the empty line that separates sections.
    content=$(awk -v s="$section" -v k="$key" -v v="$value" '
      function blanks() { while (pending > 0) { print ""; pending-- } }
      function add() { if (in_sec && !done) { print k "=" v; done = 1 } }
      /^[[:space:]]*$/ { pending++; next }
      /^[[:space:]]*\[/ {
        add(); blanks(); sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
        in_sec = (sec == s); print; next
      }
      in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { blanks(); if (!done) { print k "=" v; done = 1 }; next }
      { blanks(); print }
      END { add(); blanks(); if (!done) { if (NR) print ""; print "[" s "]"; print k "=" v } }' "$file")
  else
    content=$(printf '[%s]\n%s=%s' "$section" "$key" "$value")
  fi
  write_root_file "$file" "$content"
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

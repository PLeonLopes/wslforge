#!/usr/bin/env bash
# wslforge: set up a WSL distro with common development tools.
# Run inside the distro as your normal user: ./install.sh --help
# Idempotent: safe to re-run; modules that are already installed are skipped.
set -euo pipefail

WSLFORGE_VERSION='0.1.0-dev'
WSLFORGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$WSLFORGE_DIR/modules"

# shellcheck source=lib/common.sh
source "$WSLFORGE_DIR/lib/common.sh"
# shellcheck source=lib/distro.sh
source "$WSLFORGE_DIR/lib/distro.sh"
# shellcheck source=lib/pkg.sh
source "$WSLFORGE_DIR/lib/pkg.sh"

# Settings. Precedence: command-line flags > config file > defaults.
ACTION=install
CONFIG_FILE=''
ONLY=''
MODULES=''    # comma-separated module ids; empty = modules enabled by default
GIT_NAME=''
GIT_EMAIL=''
CONFIG_KEYS=(MODULES GIT_NAME GIT_EMAIL)

# Runtime state.
SELECTED=()
RESULTS=()
FAILED=0
RUN_DIR=''    # temporary files for this run (notes, package index marker)
NOTES_FILE=''
SUDO_KEEPALIVE_PID=''

usage() {
  cat <<EOF
wslforge $WSLFORGE_VERSION: set up this WSL distro with common development tools.

Usage: ./install.sh [options]

Options:
  --list           List the available modules and whether they are installed
  --only LIST      Install only these modules (comma-separated, e.g. git,cli)
  --config FILE    Read settings from a wslforge.conf file
  --dry-run        Show what would be done without changing anything
  -y, --yes        Never prompt (no confirmation, no questions)
  -h, --help       Show this help
  --version        Show the version

Without --only (or MODULES in the config), the default modules are installed.
The "base" module is always included.
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      --list) ACTION=list ;;
      --only)
        [[ $# -ge 2 ]] || die "--only needs a value (e.g. --only git,cli)"
        ONLY=$2
        shift
        ;;
      --only=*) ONLY=${1#*=} ;;
      --config)
        [[ $# -ge 2 ]] || die "--config needs a file path"
        CONFIG_FILE=$2
        shift
        ;;
      --config=*) CONFIG_FILE=${1#*=} ;;
      --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      --version) echo "wslforge $WSLFORGE_VERSION"; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
}

# load_config FILE: read KEY=value lines. The file is parsed, never executed.
load_config() {
  local file=$1 line key value
  [[ -r $file ]] || die "Config file not found: $file"

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      log_warn "Ignoring invalid config line: $line"
      continue
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    if in_list "$key" "${CONFIG_KEYS[@]}"; then
      printf -v "$key" '%s' "$value"
    else
      log_warn "Ignoring unknown config key: $key"
    fi
  done <"$file"
}

# ---------------------------------------------------------------- modules
# Each modules/<id>.sh defines MODULE_* metadata plus is_installed and
# do_install (configure and notes are optional). Modules are always sourced in
# a subshell so their functions and variables never clash.

module_field() {
  (
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1.sh"
    printf '%s' "${!2:-}"
  )
}

module_is_installed() {
  (
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1.sh"
    is_installed
  ) >/dev/null 2>&1
}

module_supported() {
  [[ " $(module_field "$1" MODULE_FAMILIES) " == *" $DISTRO_FAMILY "* ]]
}

# module_ids: print every module id, sorted by MODULE_ORDER.
module_ids() {
  local file id
  for file in "$MODULES_DIR"/*.sh; do
    id=$(basename "$file" .sh)
    printf '%s %s\n' "$(module_field "$id" MODULE_ORDER)" "$id"
  done | sort -n | cut -d' ' -f2
}

# select_modules: fill SELECTED from MODULES (or the defaults), keeping order.
select_modules() {
  local all=() requested=() id
  mapfile -t all < <(module_ids)

  if [[ -n $MODULES ]]; then
    IFS=',' read -ra requested <<<"${MODULES// /}"
    for id in "${requested[@]}"; do
      in_list "$id" "${all[@]}" || die "Unknown module: $id (available: ${all[*]})"
    done
  fi

  for id in "${all[@]}"; do
    if [[ $(module_field "$id" MODULE_REQUIRED) == yes ]]; then
      SELECTED+=("$id")
    elif ((${#requested[@]})); then
      if in_list "$id" "${requested[@]}"; then
        SELECTED+=("$id")
      fi
    elif [[ $(module_field "$id" MODULE_DEFAULT) == on ]]; then
      SELECTED+=("$id")
    fi
  done
}

# run_module ID: install one module and record its result.
run_module() {
  local id=$1 rc
  log_step "$(module_field "$id" MODULE_NAME) ($id)"

  if ! module_supported "$id"; then
    log_warn "Not supported on $DISTRO_FAMILY-based distros, skipping."
    RESULTS+=("○|$id|not supported")
    return 0
  fi

  # Run in a subshell with errexit on, so a failing module stops itself
  # without stopping the others. Exit 10 means "already installed".
  set +e
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$id.sh"
    status=0
    if is_installed; then
      log_info "↷ Already installed"
      status=10
    else
      do_install
      if [[ $DRY_RUN != 1 ]] && ! is_installed; then
        log_error "Installed, but verification failed."
        exit 2
      fi
    fi
    if declare -F configure >/dev/null; then
      configure
    fi
    if declare -F notes >/dev/null; then
      notes >>"$NOTES_FILE"
    fi
    exit "$status"
  )
  rc=$?
  set -e

  case $rc in
    0)
      if [[ $DRY_RUN == 1 ]]; then
        RESULTS+=("•|$id|would be installed")
      else
        log_ok "Done"
        RESULTS+=("✔|$id|installed")
      fi
      ;;
    10) RESULTS+=("↷|$id|already installed") ;;
    *)
      log_error "Module '$id' failed (exit code $rc)."
      RESULTS+=("✖|$id|failed")
      FAILED=$((FAILED + 1))
      ;;
  esac
}

# ---------------------------------------------------------------- output

print_header() {
  printf '%swslforge %s%s on %s (%s)\n' "$C_BOLD" "$WSLFORGE_VERSION" "$C_RESET" "$DISTRO_NAME" "$DISTRO_FAMILY"
}

list_modules() {
  local id status default
  printf '\n  %-10s %-15s %-9s %s\n' MODULE STATUS DEFAULT DESCRIPTION
  while IFS= read -r id; do
    if ! module_supported "$id"; then
      status='not supported'
    elif module_is_installed "$id"; then
      status='installed'
    else
      status='not installed'
    fi
    default=$(module_field "$id" MODULE_DEFAULT)
    [[ $(module_field "$id" MODULE_REQUIRED) == yes ]] && default='always'
    printf '  %-10s %-15s %-9s %s\n' "$id" "$status" "$default" "$(module_field "$id" MODULE_DESC)"
  done < <(module_ids)
  echo
}

print_plan() {
  local id
  log_step "Plan"
  for id in "${SELECTED[@]}"; do
    if ! module_supported "$id"; then
      log_info "○ $id (not supported here)"
    elif module_is_installed "$id"; then
      log_info "↷ $id (already installed)"
    else
      log_info "• $id"
    fi
  done
}

print_summary() {
  local entry symbol id text
  log_step "Summary"
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r symbol id text <<<"$entry"
    case $symbol in
      ✔) symbol="$C_GREEN$symbol$C_RESET" ;;
      ✖) symbol="$C_RED$symbol$C_RESET" ;;
    esac
    printf '    %s %-10s %s\n' "$symbol" "$id" "$text"
  done
}

print_notes() {
  [[ -s $NOTES_FILE ]] || return 0
  log_step "Next steps (manual)"
  awk '!seen[$0]++ { printf "    %d. %s\n", ++n, $0 }' "$NOTES_FILE"
}

# ---------------------------------------------------------------- sudo

# start_sudo: ask for the sudo password once and keep it fresh during the run.
start_sudo() {
  [[ $EUID -eq 0 || $DRY_RUN == 1 ]] && return 0
  has_cmd sudo || die "sudo is required (or run as root)."
  log_info "Some steps need administrator rights; sudo may ask for your password."
  sudo -v || die "Could not get sudo rights."
  (while kill -0 "$$" 2>/dev/null; do
    sudo -n true 2>/dev/null
    sleep 50
  done) &
  SUDO_KEEPALIVE_PID=$!
}

# Invoked through "trap cleanup EXIT".
# shellcheck disable=SC2317
cleanup() {
  [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  [[ -n $RUN_DIR ]] && rm -rf "$RUN_DIR"
  return 0
}

# ---------------------------------------------------------------- main

main() {
  parse_args "$@"
  [[ -n $CONFIG_FILE ]] && load_config "$CONFIG_FILE"
  [[ -n $ONLY ]] && MODULES=$ONLY

  detect_distro
  print_header

  if [[ $ACTION == list ]]; then
    list_modules
    return 0
  fi

  pkg_require_supported
  is_wsl || log_warn "This does not look like WSL; continuing anyway."

  select_modules
  print_plan

  echo
  if [[ $DRY_RUN == 1 ]]; then
    log_info "Dry run: nothing will be changed."
  else
    confirm "Proceed?" || die "Aborted. Use --yes to run without prompts."
  fi

  trap cleanup EXIT
  RUN_DIR=$(mktemp -d)
  NOTES_FILE="$RUN_DIR/notes"
  touch "$NOTES_FILE"
  start_sudo

  local id
  for id in "${SELECTED[@]}"; do
    run_module "$id"
  done

  print_summary
  print_notes
  echo
  ((FAILED == 0))
}

main "$@"

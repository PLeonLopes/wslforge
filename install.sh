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
SKIP_ARG=''
MODULES=''    # comma-separated module ids; empty = modules enabled by default
SKIP=''       # comma-separated module or tool ids to leave out
# GIT_NAME and GIT_EMAIL are read by modules/git.sh.
# shellcheck disable=SC2034
GIT_NAME=''
# shellcheck disable=SC2034
GIT_EMAIL=''
CONFIG_KEYS=(MODULES SKIP GIT_NAME GIT_EMAIL)

# Runtime state.
SKIP_LIST=()
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
  --skip LIST      Leave out modules or single tools (e.g. --skip tmux,htop)
  --config FILE    Read settings from a wslforge.conf file
  --dry-run        Show what would be done without changing anything
  -y, --yes        Never prompt (no confirmation, no questions)
  -h, --help       Show this help
  --version        Show the version

Without --only (or MODULES in the config), the default modules are installed.
The "base" module and the tools other modules depend on are always included.

Examples:
  ./install.sh --list                   # see every module and tool
  ./install.sh --skip tmux,htop         # default modules, minus two tools
  ./install.sh --only cli --skip bat    # just the CLI tools, without bat
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
      --skip)
        [[ $# -ge 2 ]] || die "--skip needs a value (e.g. --skip tmux,htop)"
        SKIP_ARG=$2
        shift
        ;;
      --skip=*) SKIP_ARG=${1#*=} ;;
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
# Each modules/<id>.sh defines MODULE_* metadata, a MODULE_ITEMS list of
# "id|description" tools, is_installed ITEM and do_install ITEM...
# (configure and notes are optional). Modules are always sourced in a
# subshell so their functions and variables never clash.

module_field() {
  (
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1.sh"
    printf '%s' "${!2:-}"
  )
}

# module_items ID: print one "item|state|description|flags" line per tool,
# where state is "installed", "missing" or "skipped".
module_items() {
  (
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1.sh"
    local entry item desc flags state supported=0
    if module_supported "$1"; then
      supported=1
    fi
    for entry in "${MODULE_ITEMS[@]}"; do
      IFS='|' read -r item desc flags <<<"$entry"
      if item_skipped "$item"; then
        state=skipped
      elif ((supported)) && is_installed "$item" >/dev/null 2>&1; then
        state=installed
      else
        state=missing
      fi
      printf '%s|%s|%s|%s\n' "$item" "$state" "$desc" "$flags"
    done
  )
}

# module_item_flags ID: print "item|flags" per tool (no install checks).
module_item_flags() {
  (
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$1.sh"
    local entry item desc flags
    for entry in "${MODULE_ITEMS[@]}"; do
      IFS='|' read -r item desc flags <<<"$entry"
      printf '%s|%s\n' "$item" "$flags"
    done
  )
}

item_skipped() {
  ((${#SKIP_LIST[@]})) && in_list "$1" "${SKIP_LIST[@]}"
}

# validate_skips: every --skip name must be a known module or tool, and
# required modules/tools cannot be skipped.
validate_skips() {
  local name id item flags found
  for name in "${SKIP_LIST[@]}"; do
    if [[ -f $MODULES_DIR/$name.sh ]]; then
      [[ $(module_field "$name" MODULE_REQUIRED) == yes ]] &&
        die "The '$name' module is required and cannot be skipped."
      continue
    fi
    found=0
    while IFS= read -r id; do
      while IFS='|' read -r item flags; do
        [[ $item == "$name" ]] || continue
        [[ $flags == *required* ]] &&
          die "'$name' is needed by other modules and cannot be skipped."
        found=1
      done < <(module_item_flags "$id")
    done < <(module_ids)
    ((found)) || die "Unknown module or tool in --skip: $name (see ./install.sh --list)"
  done
}

# module_tag ID: short label for how a module gets selected.
module_tag() {
  if ! module_supported "$1"; then
    echo "not supported on $DISTRO_FAMILY"
  elif [[ $(module_field "$1" MODULE_REQUIRED) == yes ]]; then
    echo always
  elif [[ $(module_field "$1" MODULE_DEFAULT) == on ]]; then
    echo default
  else
    echo optional
  fi
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
    if item_skipped "$id"; then
      continue
    elif [[ $(module_field "$id" MODULE_REQUIRED) == yes ]]; then
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
  # The subshell writes a one-line summary to $RUN_DIR/<id>.result.
  local result_file="$RUN_DIR/$id.result" text
  set +e
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$MODULES_DIR/$id.sh"
    entry='' item='' missing=() failed=() skipped=() status=0
    for entry in "${MODULE_ITEMS[@]}"; do
      item=${entry%%|*}
      if item_skipped "$item"; then
        skipped+=("$item")
      elif ! is_installed "$item" >/dev/null 2>&1; then
        missing+=("$item")
      fi
    done
    suffix=''
    if ((${#skipped[@]})); then
      suffix=" (skipped: $(join_by ', ' "${skipped[@]}"))"
      log_info "- Skipping: $(join_by ', ' "${skipped[@]}")"
    fi

    if ((${#skipped[@]} == ${#MODULE_ITEMS[@]})); then
      echo "skipped" >"$result_file"
      exit 11
    elif ((${#missing[@]} == 0)); then
      log_info "↷ Already installed"
      echo "already installed$suffix" >"$result_file"
      status=10
    else
      log_info "Installing: $(join_by ', ' "${missing[@]}")"
      do_install "${missing[@]}"
      if [[ $DRY_RUN == 1 ]]; then
        echo "would install: $(join_by ', ' "${missing[@]}")$suffix" >"$result_file"
      else
        for item in "${missing[@]}"; do
          is_installed "$item" >/dev/null 2>&1 || failed+=("$item")
        done
        if ((${#failed[@]})); then
          echo "verification failed: $(join_by ', ' "${failed[@]}")" >"$result_file"
          log_error "Installed, but verification failed for: $(join_by ', ' "${failed[@]}")"
          exit 2
        fi
        echo "installed: $(join_by ', ' "${missing[@]}")$suffix" >"$result_file"
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

  text=$(cat "$result_file" 2>/dev/null || true)
  case $rc in
    0)
      if [[ $DRY_RUN == 1 ]]; then
        RESULTS+=("•|$id|$text")
      else
        log_ok "Done"
        RESULTS+=("✔|$id|$text")
      fi
      ;;
    10) RESULTS+=("↷|$id|$text") ;;
    11) RESULTS+=("-|$id|skipped (all tools)") ;;
    *)
      log_error "Module '$id' failed (exit code $rc)."
      RESULTS+=("✖|$id|${text:-failed}")
      FAILED=$((FAILED + 1))
      ;;
  esac
}

# ---------------------------------------------------------------- output

print_header() {
  printf '%swslforge %s%s on %s (%s)\n' "$C_BOLD" "$WSLFORGE_VERSION" "$C_RESET" "$DISTRO_NAME" "$DISTRO_FAMILY"
}

# print_module_title ID: "id  Module name  [tag]"
print_module_title() {
  printf '\n  %s%-6s%s %s  %s[%s]%s\n' "$C_BOLD" "$1" "$C_RESET" \
    "$(module_field "$1" MODULE_NAME)" "$C_DIM" "$(module_tag "$1")" "$C_RESET"
}

list_modules() {
  local id item state desc flags mark extra
  while IFS= read -r id; do
    print_module_title "$id"
    while IFS='|' read -r item state desc flags; do
      mark='·'
      [[ $state == installed ]] && mark="$C_GREEN✔$C_RESET"
      extra=''
      [[ $flags == *required* ]] && extra=" $C_DIM(required)$C_RESET"
      printf '    %s %-16s %s%s\n' "$mark" "$item" "$desc" "$extra"
    done < <(module_items "$id")
  done < <(module_ids)
  printf '\n  %s✔%s installed   · not installed\n' "$C_GREEN" "$C_RESET"
  printf '  Leave tools or modules out with --skip, e.g. ./install.sh --skip tmux,htop\n\n'
}

print_plan() {
  local id item state desc flags installed skipped modules_skipped=()
  log_step "Plan"
  for id in "${SELECTED[@]}"; do
    print_module_title "$id"
    if ! module_supported "$id"; then
      log_info "  ○ skipped: not supported on $DISTRO_FAMILY-based distros"
      continue
    fi
    installed=()
    skipped=()
    while IFS='|' read -r item state desc flags; do
      case $state in
        installed) installed+=("$item") ;;
        skipped) skipped+=("$item") ;;
        *) printf '      + %-16s %s\n' "$item" "$desc" ;;
      esac
    done < <(module_items "$id")
    if ((${#installed[@]})); then
      printf '      %s↷ already installed: %s%s\n' "$C_DIM" "$(join_by ', ' "${installed[@]}")" "$C_RESET"
    fi
    if ((${#skipped[@]})); then
      printf '      %s- skipped: %s%s\n' "$C_DIM" "$(join_by ', ' "${skipped[@]}")" "$C_RESET"
    fi
  done

  for id in "${SKIP_LIST[@]}"; do
    if [[ -f $MODULES_DIR/$id.sh ]]; then
      modules_skipped+=("$id")
    fi
  done
  if ((${#modules_skipped[@]})); then
    printf '\n  - skipped modules: %s\n' "$(join_by ', ' "${modules_skipped[@]}")"
  fi

  printf '\n  + will be installed   ↷ already installed   - skipped\n'
  printf '  See every module and tool with --list; leave some out with --skip.\n'
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
  [[ -n $SKIP_ARG ]] && SKIP=$SKIP_ARG
  if [[ -n $SKIP ]]; then
    IFS=',' read -ra SKIP_LIST <<<"${SKIP// /}"
  fi

  detect_distro
  print_header

  if [[ $ACTION == list ]]; then
    list_modules
    return 0
  fi

  validate_skips
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

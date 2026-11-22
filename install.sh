#!/usr/bin/env bash
# wslforge: set up a WSL distro with common development tools.
# Run inside the distro as your normal user: ./install.sh --help
# Idempotent: safe to re-run; modules that are already installed are skipped.
set -euo pipefail

WSLFORGE_VERSION='1.0.0'
WSLFORGE_REPO_URL=${WSLFORGE_REPO_URL:-https://github.com/PLeonLopes/wslforge}

# bootstrap_remote ARGS...: under "curl ... | bash" there is no lib/ or
# modules/ next to this script. Download the matching version and run the
# real install.sh from it. Self-contained: lib/ is not available yet.
#   -dev versions use the main branch, releases use the tag v<version>,
#   and --ref <branch|tag> overrides both.
bootstrap_remote() {
  local ref='' args=() tmp
  while (($#)); do
    case $1 in
      --ref) ref=${2:-}; shift ;;
      --ref=*) ref=${1#*=} ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  if [[ -z $ref ]]; then
    if [[ $WSLFORGE_VERSION == *-dev ]]; then ref=main; else ref="v$WSLFORGE_VERSION"; fi
  fi
  if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo 'ERROR: wslforge needs curl and tar.' >&2
    exit 1
  fi

  tmp=$(mktemp -d)
  echo "==> Downloading wslforge ($ref)..."
  if ! curl -fsSL "$WSLFORGE_REPO_URL/archive/$ref.tar.gz" | tar -xz -C "$tmp" --strip-components=1; then
    echo "ERROR: could not download wslforge from $WSLFORGE_REPO_URL ($ref)." >&2
    rm -rf "$tmp"
    exit 1
  fi
  # stdin is still the rest of the piped script: never let anything read it.
  # (Menus and prompts use /dev/tty.)
  WSLFORGE_CLEANUP_DIR=$tmp exec bash "$tmp/install.sh" "${args[@]}" </dev/null
}

if [[ -z ${BASH_SOURCE[0]:-} || ! -f $(dirname "${BASH_SOURCE[0]}")/lib/common.sh ]]; then
  bootstrap_remote "$@"
fi

WSLFORGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$WSLFORGE_DIR/modules"

# shellcheck source=lib/common.sh
source "$WSLFORGE_DIR/lib/common.sh"
# shellcheck source=lib/distro.sh
source "$WSLFORGE_DIR/lib/distro.sh"
# shellcheck source=lib/pkg.sh
source "$WSLFORGE_DIR/lib/pkg.sh"
# shellcheck source=lib/ui.sh
source "$WSLFORGE_DIR/lib/ui.sh"

# Settings. Precedence: command-line flags > config file > defaults.
ACTION=install
LIST_MODULE=''  # --list MODULE: show one module in detail
CONFIG_FILE=''
ONLY=''
SKIP_ARG=''
MODULES=''    # comma-separated module ids; empty = modules enabled by default
SKIP=''       # comma-separated module or tool ids to leave out
PROFILE=''    # minimal | dev | full (empty = dev)
PROFILE_ARG=''
REF=''        # only used by bootstrap_remote
FROM_WINDOWS=0  # 1 = started by install.ps1 (answers already confirmed there)
# install.ps1 grants passwordless sudo through this file while the installer
# runs, so nobody has to type a password; it is removed when the run ends.
WINDOWS_SUDOERS=/etc/sudoers.d/wslforge-setup
# GIT_NAME and GIT_EMAIL are read by modules/git.sh.
# shellcheck disable=SC2034
GIT_NAME=''
# shellcheck disable=SC2034
GIT_EMAIL=''
CONFIG_KEYS=(PROFILE MODULES SKIP GIT_NAME GIT_EMAIL)
# Keys written by install.ps1 for the Windows side; ignored here.
WINDOWS_KEYS=(WSL_DISTRO WSL_NAME WSL_LOCATION WSL_USER WSL_MEMORY_GB WSL_CPUS)
PROFILES=(dev minimal full)

# Runtime state.
SKIP_LIST=()
SELECTED=()
RESULTS=()
FAILED=0
RUN_DIR=''    # temporary files for this run (notes, package index marker)
NOTES_FILE=''
SUDO_KEEPALIVE_PID=''
INTERACTIVE=0 # 1 = a terminal is available and --yes was not given
LOG_FILE="$HOME/.wslforge/install.log"
LOG_PID=''
FOLLOW_ACTIONS=() # "label|command[|last]" offered at the end
FOLLOW_REASONS=() # why a fresh shell is needed
FOLLOW_GROUPS=()  # new groups the fresh shell should pick up

usage() {
  cat <<EOF
wslforge $WSLFORGE_VERSION: set up this WSL distro with common development tools.

Usage: ./install.sh [options]
       curl -fsSL https://raw.githubusercontent.com/PLeonLopes/wslforge/main/install.sh | bash

Without options, an interactive menu asks what to install.

Options:
  --list [MODULE]  List the modules and what is installed (MODULE: in detail)
  --profile NAME   Install a preset: dev (default), minimal or full
  --only LIST      Install only these modules (comma-separated, e.g. git,cli)
  --skip LIST      Leave out modules or single tools (e.g. --skip tmux,htop)
  --config FILE    Read settings from a wslforge.conf file
  --dry-run        Show what would be done without changing anything
  -y, --yes        Never prompt: no menu, no questions, no confirmation
  --ui NAME        Menu style: gum (default), whiptail or text
  --ref REF        With curl | bash: install this branch or tag instead
  --from-windows   Used by install.ps1: the answers were confirmed on Windows
  -h, --help       Show this help
  --version        Show the version

The "base" module and the tools other modules depend on are always included.
A log of each run is saved to ~/.wslforge/install.log.

Examples:
  ./install.sh                          # interactive menu
  ./install.sh --list                   # see every module and tool
  ./install.sh --list cloud             # one module, with descriptions
  ./install.sh --profile minimal -y     # essentials only, no questions
  ./install.sh --skip tmux,htop         # default modules, minus two tools
  ./install.sh --only cli --skip bat    # just the CLI tools, without bat
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      --list)
        ACTION=list
        if [[ $# -ge 2 && $2 != -* ]]; then
          LIST_MODULE=$2
          shift
        fi
        ;;
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
      --profile)
        [[ $# -ge 2 ]] || die "--profile needs a value (${PROFILES[*]})"
        PROFILE_ARG=$2
        shift
        ;;
      --profile=*) PROFILE_ARG=${1#*=} ;;
      --ui)
        [[ $# -ge 2 ]] || die "--ui needs a value (gum, whiptail or text)"
        WSLFORGE_UI=$2
        shift
        ;;
      --ui=*) WSLFORGE_UI=${1#*=} ;;
      --ref)
        [[ $# -ge 2 ]] || die "--ref needs a branch or tag"
        REF=$2
        shift
        ;;
      --ref=*) REF=${1#*=} ;;
      --from-windows) FROM_WINDOWS=1 ;;
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
    elif in_list "$key" "${WINDOWS_KEYS[@]}"; then
      continue
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
# where state is "installed", "missing", "skipped" or "unavailable" (no
# package for it on this distro).
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
      elif ((supported)) && ! item_available "$item"; then
        state=unavailable
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

# item_available ITEM: modules may define is_available ITEM for tools that
# some distros do not package. Call only with the module sourced.
item_available() {
  if declare -F is_available >/dev/null; then
    is_available "$1"
  fi
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

# profile_includes PROFILE ID: true when the preset installs the module.
profile_includes() {
  if [[ $(module_field "$2" MODULE_REQUIRED) == yes ]]; then
    return 0
  fi
  case $1 in
    full) return 0 ;;
    minimal) [[ $2 == git ]] ;;
    *) [[ $(module_field "$2" MODULE_DEFAULT) == on ]] ;;
  esac
}

# profile_list PROFILE: the preset's modules, space-separated.
profile_list() {
  local id list=()
  while IFS= read -r id; do
    if module_supported "$id" && profile_includes "$1" "$id"; then
      list+=("$id")
    fi
  done < <(module_ids)
  printf '%s' "${list[*]}"
}

# select_modules: fill SELECTED from MODULES (or the profile), keeping order.
select_modules() {
  local all=() requested=() id
  SELECTED=()
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
    elif profile_includes "${PROFILE:-dev}" "$id"; then
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
    entry='' item='' missing=() failed=() skipped=() unavailable=() status=0
    for entry in "${MODULE_ITEMS[@]}"; do
      item=${entry%%|*}
      if item_skipped "$item"; then
        skipped+=("$item")
      elif ! item_available "$item"; then
        unavailable+=("$item")
      elif ! is_installed "$item" >/dev/null 2>&1; then
        missing+=("$item")
      fi
    done
    suffix=''
    if ((${#skipped[@]})); then
      suffix=" (skipped: $(join_by ', ' "${skipped[@]}"))"
      log_info "- Skipping: $(join_by ', ' "${skipped[@]}")"
    fi
    if ((${#unavailable[@]})); then
      suffix+=" (unavailable on $DISTRO_ID: $(join_by ', ' "${unavailable[@]}"))"
      log_info "○ Not packaged for $DISTRO_ID: $(join_by ', ' "${unavailable[@]}")"
    fi

    if ((${#skipped[@]} + ${#unavailable[@]} == ${#MODULE_ITEMS[@]})); then
      echo "skipped$suffix" >"$result_file"
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
    if declare -F actions >/dev/null; then
      actions >>"$RUN_DIR/actions"
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
    11) RESULTS+=("-|$id|${text:-skipped}") ;;
    *)
      log_error "Module '$id' failed (exit code $rc)."
      RESULTS+=("✖|$id|${text:-failed}")
      FAILED=$((FAILED + 1))
      ;;
  esac
}

# ---------------------------------------------------------------- output

print_header() {
  printf '%swslforge%s %s on %s (%s)\n' "$C_BOLD$C_EMBER" "$C_RESET" "$WSLFORGE_VERSION" "$DISTRO_NAME" "$DISTRO_FAMILY"
}

# print_module_title ID: "id  Module name  [tag]"
print_module_title() {
  printf '\n  %s%-10s%s %s  %s[%s]%s\n' "$C_BOLD" "$1" "$C_RESET" \
    "$(module_field "$1" MODULE_NAME)" "$C_ASH" "$(module_tag "$1")" "$C_RESET"
}

# item_mark STATE: the symbol --list shows for a tool.
item_mark() {
  case $1 in
    installed) printf '%s✔%s' "$C_MOSS" "$C_RESET" ;;
    unavailable) printf '%s○%s' "$C_ASH" "$C_RESET" ;;
    *) printf '·' ;;
  esac
}

list_legend() {
  printf '\n  %s✔%s installed   · not installed   ○ unavailable on this distro\n' "$C_MOSS" "$C_RESET"
}

# list_modules: one line per module (tools wrapped), grouped. With
# --list MODULE, every tool of that module with its description.
list_modules() {
  local id group last='' item state desc flags word len indent=27 width=78
  if [[ -n $LIST_MODULE ]]; then
    list_module "$LIST_MODULE"
    return 0
  fi
  while IFS= read -r id; do
    group=$(module_field "$id" MODULE_GROUP)
    if [[ $group != "$last" ]]; then
      printf '\n  %s%s%s\n' "$C_BOLD$C_AMBER" "$group" "$C_RESET"
      last=$group
    fi
    printf '    %s%-10s%s %s%-12s%s' "$C_BOLD" "$id" "$C_RESET" "$C_ASH" "$(module_tag "$id")" "$C_RESET"
    len=$indent
    while IFS='|' read -r item state desc flags; do
      word="$(item_mark "$state") $item"
      if ((len + ${#item} + 4 > width && len > indent)); then
        printf '\n%*s' "$indent" ''
        len=$indent
      fi
      printf '%s  ' "$word"
      len=$((len + ${#item} + 4))
    done < <(module_items "$id")
    printf '\n'
  done < <(module_ids)
  list_legend
  printf '  Details: ./install.sh --list <module>   Leave tools out: --skip tmux,htop\n\n'
}

# list_module ID: every tool of one module, with its description.
list_module() {
  local item state desc flags extra
  [[ -f $MODULES_DIR/$1.sh ]] || die "Unknown module: $1 (see ./install.sh --list)"
  print_module_title "$1"
  while IFS='|' read -r item state desc flags; do
    extra=''
    [[ $flags == *required* ]] && extra=" $C_ASH(required)$C_RESET"
    [[ $state == unavailable ]] && extra=" $C_ASH(unavailable on $DISTRO_ID)$C_RESET"
    printf '    %s %-24s %s%s\n' "$(item_mark "$state")" "$item" "$desc" "$extra"
  done < <(module_items "$1")
  list_legend
  echo
}

# print_wrapped MARK TEXT: an indented plan line, wrapped to the terminal.
print_wrapped() {
  printf '%s\n' "$2" | fold -s -w 66 | awk -v m="$1" '{ printf "      %s %s\n", (NR == 1 ? m : " "), $0 }'
}

print_plan() {
  local id item state desc flags installed skipped unavailable missing modules_skipped=()
  log_step "Plan"
  for id in "${SELECTED[@]}"; do
    print_module_title "$id"
    if ! module_supported "$id"; then
      log_info "  ○ skipped: not supported on $DISTRO_FAMILY-based distros"
      continue
    fi
    installed=()
    skipped=()
    unavailable=()
    missing=()
    while IFS='|' read -r item state desc flags; do
      case $state in
        installed) installed+=("$item") ;;
        skipped) skipped+=("$item") ;;
        unavailable) unavailable+=("$item") ;;
        *) missing+=("$item") ;;
      esac
    done < <(module_items "$id")
    if ((${#missing[@]})); then
      print_wrapped "$C_EMBER+$C_RESET" "$(join_by ', ' "${missing[@]}")"
    fi
    if ((${#installed[@]})); then
      print_wrapped "$C_ASH↷$C_RESET" "already installed: $(join_by ', ' "${installed[@]}")"
    fi
    if ((${#skipped[@]})); then
      print_wrapped "$C_ASH-$C_RESET" "skipped: $(join_by ', ' "${skipped[@]}")"
    fi
    if ((${#unavailable[@]})); then
      print_wrapped "$C_ASH○$C_RESET" "unavailable on $DISTRO_ID: $(join_by ', ' "${unavailable[@]}")"
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

  printf '\n  %s+%s will be installed   ↷ already installed   - skipped\n' "$C_EMBER" "$C_RESET"
  printf '  See every module and tool with --list; leave some out with --skip.\n'
}

print_summary() {
  local entry symbol id text
  log_step "Summary"
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r symbol id text <<<"$entry"
    case $symbol in
      ✔) symbol="$C_MOSS$symbol$C_RESET" ;;
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

# ---------------------------------------------------------------- menu

# interactive_menu: ask what to install (profile or tool by tool) and the git
# identity, then fill PROFILE / MODULES / SKIP.
interactive_menu() {
  local choice
  ui_init
  ui_header "wslforge $WSLFORGE_VERSION" "Set up $DISTRO_NAME for development"
  choice=$(ui_choose_one 'What would you like to install?' dev \
    "dev|dev       Recommended: $(profile_list dev)" \
    "minimal|minimal   Just the essentials: $(profile_list minimal)" \
    "full|full      Everything: all $(wc -w <<<"$(profile_list full)") modules (optional ones included)" \
    "custom|custom    Choose the modules and optionally single tools") || die 'Cancelled.'
  [[ -n $choice ]] || die 'Cancelled.'

  if [[ $choice == custom ]]; then
    _menu_custom
  else
    PROFILE=$choice
  fi
  select_modules
  if in_list git "${SELECTED[@]}"; then
    _menu_git_identity
  fi
}

# _menu_custom: a checklist of modules, grouped, then (only if asked) a
# checklist with the tools of the picked modules. Fills MODULES and SKIP.
_menu_custom() {
  local id group last='' label on answer
  local opts=() picked=() modules=()
  while IFS= read -r id; do
    module_supported "$id" || continue
    if [[ $(module_field "$id" MODULE_REQUIRED) == yes ]]; then
      modules+=("$id")
      continue
    fi
    group=$(module_field "$id" MODULE_GROUP)
    [[ $group == "$last" ]] && group=''
    [[ -n $group ]] && last=$group
    label=$(printf '%-18s %-10s %s' "$group" "$id" "$(module_field "$id" MODULE_NAME)")
    # (Not "| grep -q": with pipefail, grep exiting early fails the pipe.)
    [[ $(module_items "$id") == *'|missing|'* ]] || label+='  (installed)'
    on=off
    if profile_includes dev "$id"; then
      on=on
    fi
    opts+=("$id|$label|$on")
  done < <(module_ids)

  answer=$(ui_choose_many "Pick the modules. Base packages are always installed." "${opts[@]}") ||
    die 'Cancelled.'
  mapfile -t picked <<<"$answer"
  for id in "${picked[@]}"; do
    [[ -n $id ]] && modules+=("$id")
  done

  SKIP=''
  SKIP_LIST=()
  if ((${#modules[@]} > 1)) && ui_confirm 'Fine-tune single tools of these modules?' no; then
    _menu_pick_tools "${modules[@]}"
  fi
  MODULES=$(join_by ',' "${modules[@]}")
}

# _menu_pick_tools MODULE...: one checklist with the optional tools of the
# given modules, all on. Unpicked tools go to SKIP; modules left with no tool
# are dropped from the "modules" array of _menu_custom.
_menu_pick_tools() {
  local id item state desc flags label first answer
  local opts=() picked=() kept=() skips=()
  for id in "$@"; do
    first=$id
    while IFS='|' read -r item state desc flags; do
      [[ $flags == *required* || $state == unavailable ]] && continue
      label=$(printf '%-10s %-24s %s' "$first" "$item" "$desc")
      first=''
      opts+=("$id:$item|$label|on")
    done < <(module_items "$id")
  done
  ((${#opts[@]})) || return 0

  answer=$(ui_choose_many 'Unselect the tools you do not want' "${opts[@]}") || die 'Cancelled.'
  mapfile -t picked <<<"$answer"

  for id in "$@"; do
    local any=0 module_skips=()
    while IFS='|' read -r item state desc flags; do
      [[ $flags == *required* || $state == unavailable ]] && continue
      if in_list "$id:$item" "${picked[@]}"; then
        any=1
      else
        module_skips+=("$item")
      fi
    done < <(module_items "$id")
    if ((any)) || [[ $(module_field "$id" MODULE_REQUIRED) == yes ]]; then
      kept+=("$id")
      skips+=("${module_skips[@]}")
    fi
  done
  modules=("${kept[@]}")
  SKIP=$(join_by ',' "${skips[@]}")
  SKIP_LIST=("${skips[@]}")
}

_menu_git_identity() {
  local name email
  name=${GIT_NAME:-$(git config --global --get user.name 2>/dev/null || true)}
  email=${GIT_EMAIL:-$(git config --global --get user.email 2>/dev/null || true)}
  GIT_NAME=$(ui_input 'Git user name' "$name") || die 'Cancelled.'
  GIT_EMAIL=$(ui_input 'Git email' "$email") || die 'Cancelled.'
}

# ---------------------------------------------------------------- sudo

# plan_needs_root: true when a selected module has something to install and
# does not declare MODULE_ROOT=no (home-only installers).
plan_needs_root() {
  local id
  for id in "${SELECTED[@]}"; do
    module_supported "$id" || continue
    [[ $(module_field "$id" MODULE_ROOT) == no ]] && continue
    if [[ $(module_items "$id") == *'|missing|'* ]]; then
      return 0
    fi
  done
  return 1
}

# start_sudo: ask for the sudo password once, up front, and keep it fresh,
# so the rest of the run needs no attention. Skipped when nothing needs root.
start_sudo() {
  [[ $EUID -eq 0 || $DRY_RUN == 1 ]] && return 0
  plan_needs_root || return 0
  has_cmd sudo || die "sudo is required (or run as root)."
  log_info "Some steps need administrator rights; sudo may ask for your password."
  sudo -v || die "Could not get sudo rights."
  (while kill -0 "$$" 2>/dev/null; do
    sudo -n true 2>/dev/null
    sleep 50
  done) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
}

# ---------------------------------------------------------------- log

# start_log: copy everything printed from now on to ~/.wslforge/install.log
# (without colors). Started after the menu, which needs the terminal.
start_log() {
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$(dirname "$LOG_FILE")"
  exec 5>&1 6>&2
  exec > >(tee >(sed -u -E 's/\x1b\[[0-9;]*[A-Za-z]//g' >>"$LOG_FILE")) 2>&1
  LOG_PID=$!
  printf '\n===== wslforge %s | %s | %s =====\nModules: %s\nSkipped: %s\n' \
    "$WSLFORGE_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$DISTRO_NAME" \
    "${SELECTED[*]}" "${SKIP_LIST[*]:-none}" >>"$LOG_FILE"
}

stop_log() {
  [[ -n $LOG_PID ]] || return 0
  exec 1>&5 2>&6 5>&- 6>&-
  # Let tee flush the last lines, but never hang if something kept the pipe.
  for _ in {1..50}; do
    kill -0 "$LOG_PID" 2>/dev/null || break
    sleep 0.1
  done
  LOG_PID=''
}

# ---------------------------------------------------------------- follow-ups

# collect_followups: read the actions and fresh-shell reasons the modules
# recorded. Without a terminal (or with --yes / --dry-run) they become notes.
collect_followups() {
  local reason group line label cmd
  if [[ -s $RUN_DIR/actions ]]; then
    mapfile -t FOLLOW_ACTIONS < <(awk '!seen[$0]++' "$RUN_DIR/actions")
  fi
  if [[ -s $RUN_DIR/new-shell ]]; then
    while IFS='|' read -r reason group; do
      in_list "$reason" "${FOLLOW_REASONS[@]}" || FOLLOW_REASONS+=("$reason")
      if [[ -n $group ]] && ! in_list "$group" "${FOLLOW_GROUPS[@]}"; then
        FOLLOW_GROUPS+=("$group")
      fi
    done <"$RUN_DIR/new-shell"
  fi

  if ((INTERACTIVE)) && [[ $DRY_RUN != 1 ]]; then
    return 0
  fi
  for line in "${FOLLOW_ACTIONS[@]}"; do
    IFS='|' read -r label cmd _ <<<"$line"
    echo "$label: $cmd" >>"$NOTES_FILE"
  done
  if ((${#FOLLOW_REASONS[@]})); then
    echo "Open a new terminal to use $(join_by ', ' "${FOLLOW_REASONS[@]}")." >>"$NOTES_FILE"
  fi
  FOLLOW_ACTIONS=()
  FOLLOW_REASONS=()
}

# offer_followups: let the user run the actions now, then offer a fresh shell.
offer_followups() {
  local opts=() chosen=() answer n label cmd flag pass
  ((${#FOLLOW_ACTIONS[@]} + ${#FOLLOW_REASONS[@]})) || return 0
  ui_init

  if ((${#FOLLOW_ACTIONS[@]})); then
    for n in "${!FOLLOW_ACTIONS[@]}"; do
      IFS='|' read -r label cmd flag <<<"${FOLLOW_ACTIONS[$n]}"
      opts+=("$n|$label|on")
    done
    answer=$(ui_choose_many 'Finish setting up now? (unselected steps are listed for later)' "${opts[@]}") || answer=''
    mapfile -t chosen <<<"$answer"

    for n in "${!FOLLOW_ACTIONS[@]}"; do
      IFS='|' read -r label cmd flag <<<"${FOLLOW_ACTIONS[$n]}"
      in_list "$n" "${chosen[@]}" || log_info "Later: $label: $cmd"
    done
    # "last" actions (like restarting the distro) end the session.
    for pass in normal last; do
      for n in "${chosen[@]}"; do
        [[ -n $n ]] || continue
        IFS='|' read -r label cmd flag <<<"${FOLLOW_ACTIONS[$n]}"
        [[ ${flag:-normal} == "$pass" ]] || continue
        log_step "$label"
        if ! bash -c "$cmd" </dev/tty >/dev/tty 2>&1; then
          log_warn "That did not finish; run it later with: $cmd"
        fi
      done
    done
  fi

  if ((${#FOLLOW_REASONS[@]})); then
    if ui_confirm "Open a fresh shell now to use $(join_by ', ' "${FOLLOW_REASONS[@]}")?"; then
      start_fresh_shell
    fi
    log_info "Open a new terminal to use $(join_by ', ' "${FOLLOW_REASONS[@]}")."
  fi
}

# start_fresh_shell: replace this script with a login shell that has the new
# PATH entries and groups. Typing "exit" returns to the previous shell.
start_fresh_shell() {
  local shell
  # The login shell may have just changed (the shell module can switch to zsh).
  shell=$(getent passwd "$(id -un)" | cut -d: -f7)
  [[ -x $shell ]] || shell=${SHELL:-/bin/bash}
  cleanup
  trap - EXIT
  log_info "Starting a fresh shell (type 'exit' to go back to the previous one)."
  if ((${#FOLLOW_GROUPS[@]})) && has_cmd sg; then
    exec sg "${FOLLOW_GROUPS[0]}" -c "exec $(printf '%q' "$shell") -l" </dev/tty >/dev/tty 2>&1
  fi
  exec "$shell" -l </dev/tty >/dev/tty 2>&1
}

# Invoked through "trap cleanup EXIT" (and before starting a fresh shell).
# shellcheck disable=SC2317
cleanup() {
  stop_log
  [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  [[ -n $RUN_DIR ]] && rm -rf "$RUN_DIR"
  # Drop install.ps1's temporary passwordless sudo before handing over a shell.
  if [[ $FROM_WINDOWS == 1 && -e $WINDOWS_SUDOERS ]]; then
    sudo -n rm -f "$WINDOWS_SUDOERS" 2>/dev/null
  fi
  # Remove the copy downloaded by bootstrap_remote (only if it is this one).
  if [[ -n ${WSLFORGE_CLEANUP_DIR:-} && $WSLFORGE_CLEANUP_DIR == "$WSLFORGE_DIR" ]]; then
    rm -rf "$WSLFORGE_CLEANUP_DIR"
  fi
  return 0
}

# ---------------------------------------------------------------- main

main() {
  trap cleanup EXIT
  parse_args "$@"
  [[ -n $CONFIG_FILE ]] && load_config "$CONFIG_FILE"
  [[ -n $ONLY ]] && MODULES=$ONLY
  [[ -n $SKIP_ARG ]] && SKIP=$SKIP_ARG
  [[ -n $PROFILE_ARG ]] && PROFILE=$PROFILE_ARG
  if [[ -n $PROFILE ]] && ! in_list "$PROFILE" "${PROFILES[@]}"; then
    die "Unknown profile: $PROFILE (use ${PROFILES[*]})"
  fi
  if [[ -n $SKIP ]]; then
    IFS=',' read -ra SKIP_LIST <<<"${SKIP// /}"
  fi
  if [[ $ASSUME_YES != 1 ]] && has_tty; then
    INTERACTIVE=1
  fi

  detect_distro
  print_header
  if [[ -n $REF ]]; then
    log_warn "--ref only applies to curl | bash; using the local files."
  fi

  if [[ $ACTION == list ]]; then
    list_modules
    return 0
  fi

  validate_skips
  pkg_require_supported
  is_wsl || log_info "Not running in WSL: the WSL-specific steps are skipped."

  # The menu shows up when nothing was chosen through flags or a config file.
  if ((INTERACTIVE)) && [[ -z $ONLY$SKIP_ARG$PROFILE_ARG$CONFIG_FILE ]]; then
    interactive_menu
  fi

  select_modules
  print_plan

  echo
  if [[ $DRY_RUN == 1 ]]; then
    log_info "Dry run: nothing will be changed."
  elif [[ $FROM_WINDOWS == 1 ]]; then
    : # already confirmed in install.ps1
  elif [[ -n $UI_BACKEND ]]; then
    ui_confirm 'Install now?' || die 'Cancelled.'
  else
    confirm "Proceed?" || die "Aborted. Use --yes to run without prompts."
  fi

  RUN_DIR=$(mktemp -d)
  NOTES_FILE="$RUN_DIR/notes"
  touch "$NOTES_FILE"
  start_sudo
  start_log

  local id
  for id in "${SELECTED[@]}"; do
    run_module "$id"
  done

  print_summary
  collect_followups
  print_notes
  if [[ -n $LOG_PID ]]; then
    log_info "Full log: $LOG_FILE"
  fi
  echo
  stop_log

  if ((INTERACTIVE)) && [[ $DRY_RUN != 1 ]]; then
    offer_followups
  fi
  ((FAILED == 0))
}

main "$@"

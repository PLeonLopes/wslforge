# shellcheck shell=bash
# Interactive UI behind a small API (ui_header, ui_choose_one, ui_choose_many,
# ui_input, ui_confirm). ui_init picks one backend, in this order:
#   gum       modern UI; a pinned release is downloaded to ~/.wslforge/bin
#             and its checksum verified (no sudo, nothing installed system-wide)
#   whiptail  classic dialogs with a dark theme (preinstalled on Ubuntu/Debian)
#   text      plain prompts, always available
# Force one with --ui or WSLFORGE_UI=gum|whiptail|text.
# Everything reads from and draws on /dev/tty, so it also works under
# curl | bash.

GUM_VERSION='2.0.2'
GUM_DIR="$HOME/.wslforge/bin"
UI_BACKEND=''
UI_GUM=''

# The Forge palette (lib/common.sh) for whiptail. newt only has 16 colors:
# "brown" is the dark yellow most terminals draw as ochre, the closest to
# ember; "yellow" is the bright one, closest to amber.
UI_WHIPTAIL_THEME='root=white,black border=brown,black window=white,black shadow=black,black
title=yellow,black roottext=yellow,black textbox=white,black label=white,black
button=white,black actbutton=black,yellow compactbutton=white,black
checkbox=white,black actcheckbox=black,brown listbox=white,black actlistbox=black,brown
sellistbox=yellow,black actsellistbox=black,brown entry=white,black helpline=white,black'

# has_tty: true when an interactive terminal is available.
has_tty() {
  { : </dev/tty; } 2>/dev/null
}

# ui_init: pick the backend (once).
ui_init() {
  [[ -n $UI_BACKEND ]] && return 0
  case ${WSLFORGE_UI:-auto} in
    gum | auto)
      if _ui_find_gum; then
        UI_BACKEND=gum
      elif has_cmd whiptail; then
        UI_BACKEND=whiptail
      else
        UI_BACKEND=text
      fi
      ;;
    whiptail)
      if has_cmd whiptail; then UI_BACKEND=whiptail; else UI_BACKEND=text; fi
      ;;
    text) UI_BACKEND=text ;;
    *) die "Unknown UI: $WSLFORGE_UI (use gum, whiptail or text)" ;;
  esac
}

_ui_find_gum() {
  if [[ -x $GUM_DIR/gum ]] || _ui_fetch_gum; then
    UI_GUM="$GUM_DIR/gum"
    _ui_gum_theme
    return 0
  fi
  return 1
}

# _ui_gum_theme: paint gum with the Forge palette. Plain item text keeps the
# terminal's own color, so it stays readable on light terminals too.
_ui_gum_theme() {
  export GUM_CHOOSE_CURSOR_FOREGROUND=$FORGE_EMBER
  export GUM_CHOOSE_SELECTED_FOREGROUND=$FORGE_EMBER
  export GUM_CHOOSE_HEADER_FOREGROUND=$FORGE_AMBER
  export GUM_INPUT_HEADER_FOREGROUND=$FORGE_AMBER
  export GUM_INPUT_PROMPT_FOREGROUND=$FORGE_EMBER
  export GUM_INPUT_CURSOR_FOREGROUND=$FORGE_EMBER
  export GUM_INPUT_PLACEHOLDER_FOREGROUND=$FORGE_ASH
  export GUM_CONFIRM_PROMPT_FOREGROUND=$FORGE_AMBER
  export GUM_CONFIRM_SELECTED_BACKGROUND=$FORGE_EMBER
  export GUM_CONFIRM_SELECTED_FOREGROUND=$FORGE_CHARCOAL
  export GUM_CONFIRM_UNSELECTED_BACKGROUND=$FORGE_IRON
  export GUM_CONFIRM_UNSELECTED_FOREGROUND=$FORGE_TEXT
}

# _ui_fetch_gum: download the pinned gum release and verify its checksum.
_ui_fetch_gum() {
  local arch base url tmp bin rc=1
  case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  if ! has_cmd curl || ! has_cmd tar || ! has_cmd sha256sum; then
    return 1
  fi

  base="gum_${GUM_VERSION}_Linux_${arch}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"
  tmp=$(mktemp -d)
  printf '    Downloading gum %s for the interactive menu...\n' "$GUM_VERSION" >/dev/tty
  if curl -fsSL --max-time 60 -o "$tmp/$base" "$url/$base" &&
    curl -fsSL --max-time 30 -o "$tmp/checksums.txt" "$url/checksums.txt" &&
    (cd "$tmp" && grep " $base\$" checksums.txt | sha256sum -c --status) &&
    tar -xzf "$tmp/$base" -C "$tmp"; then
    bin=$(find "$tmp" -type f -name gum -perm -u+x | head -n 1)
    if [[ -n $bin ]] && mkdir -p "$GUM_DIR" && cp "$bin" "$GUM_DIR/gum" && chmod 755 "$GUM_DIR/gum"; then
      rc=0
    fi
  fi
  rm -rf "$tmp"
  ((rc == 0)) || printf '    Could not get gum; using a simpler interface.\n' >/dev/tty
  return "$rc"
}

# Terminal size, for whiptail dialogs.
_ui_size() {
  local size
  size=$(stty size </dev/tty 2>/dev/null) || size='24 80'
  UI_ROWS=${size% *}
  UI_COLS=${size#* }
}

_whiptail() {
  NEWT_COLORS=$UI_WHIPTAIL_THEME whiptail --title ' wslforge ' "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
}

# gum renders on stderr and prints the answer on stdout.
_gum() {
  "$UI_GUM" "$@" </dev/tty 2>/dev/tty
}

# gum splits --selected on commas, so labels must not contain any.
_ui_label() {
  local text=$1
  printf '%s' "${text//,/ ·}"
}

# ui_header TITLE [SUBTITLE]: a banner at the top of the menu.
ui_header() {
  case $UI_BACKEND in
    gum)
      _gum style --border rounded --border-foreground "$FORGE_EMBER" --padding '0 2' --margin '1 0 0 0' \
        "$(_gum style --bold --foreground "$FORGE_EMBER" "$1")" ${2:+"$2"} >/dev/tty
      ;;
    *) printf '\n%s%s%s\n%s\n' "$C_BOLD$C_EMBER" "$1" "$C_RESET" "${2:-}" >/dev/tty ;;
  esac
}

# ui_choose_one TITLE DEFAULT_KEY "key|label"...: print the chosen key.
ui_choose_one() {
  local title=$1 default=$2 entry key label deflabel='' n=0 reply
  shift 2
  local keys=() labels=() opts=()
  for entry in "$@"; do
    key=${entry%%|*}
    label=$(_ui_label "${entry#*|}")
    keys+=("$key")
    labels+=("$label")
    opts+=("$label"$'\x1f'"$key")
    [[ $key == "$default" ]] && deflabel=$label
  done

  case $UI_BACKEND in
    gum)
      _gum choose --header "$title" --label-delimiter $'\x1f' --selected "$deflabel" "${opts[@]}"
      ;;
    whiptail)
      _ui_size
      local args=()
      for n in "${!keys[@]}"; do
        args+=("${keys[$n]}" "${labels[$n]}")
      done
      _whiptail --notags --default-item "$default" --menu "$title" $((${#keys[@]} + 8)) $((UI_COLS - 4)) "${#keys[@]}" "${args[@]}"
      ;;
    *)
      printf '\n%s\n' "$title" >/dev/tty
      for n in "${!keys[@]}"; do
        printf '  %d) %s\n' $((n + 1)) "${labels[$n]}" >/dev/tty
      done
      while true; do
        read -r -p "  Choose [default: $default]: " reply </dev/tty || return 1
        if [[ -z $reply ]]; then
          printf '%s\n' "$default"
          return 0
        elif [[ $reply =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#keys[@]})); then
          printf '%s\n' "${keys[$((reply - 1))]}"
          return 0
        fi
      done
      ;;
  esac
}

# ui_choose_many TITLE "key|label|on|off"...: print the chosen keys, one per line.
ui_choose_many() {
  local title=$1 entry key rest label state n reply num nums
  shift
  local keys=() labels=() states=() opts=() selected=()
  for entry in "$@"; do
    key=${entry%%|*}
    rest=${entry#*|}
    label=$(_ui_label "${rest%|*}")
    state=${rest##*|}
    keys+=("$key")
    labels+=("$label")
    states+=("$state")
    opts+=("$label"$'\x1f'"$key")
    [[ $state == on ]] && selected+=("$label")
  done

  case $UI_BACKEND in
    gum)
      _ui_size
      local height=$((${#keys[@]} < UI_ROWS - 8 ? ${#keys[@]} : UI_ROWS - 8))
      local sel_args=()
      ((${#selected[@]})) && sel_args=(--selected "$(join_by ',' "${selected[@]}")")
      _gum choose --no-limit --header "$title" --label-delimiter $'\x1f' \
        --height "$height" "${sel_args[@]}" "${opts[@]}"
      ;;
    whiptail)
      _ui_size
      local args=() list_h
      for n in "${!keys[@]}"; do
        args+=("${keys[$n]}" "${labels[$n]}" "$([[ ${states[$n]} == on ]] && echo ON || echo OFF)")
      done
      list_h=$((${#keys[@]} < UI_ROWS - 10 ? ${#keys[@]} : UI_ROWS - 10))
      _whiptail --notags --separate-output --checklist "$title\n(space toggles, enter confirms)" \
        $((list_h + 9)) $((UI_COLS - 4)) "$list_h" "${args[@]}"
      ;;
    *)
      while true; do
        printf '\n%s\n' "$title" >/dev/tty
        for n in "${!keys[@]}"; do
          printf '  %2d) [%s] %s\n' $((n + 1)) "$([[ ${states[$n]} == on ]] && echo x || echo ' ')" "${labels[$n]}" >/dev/tty
        done
        read -r -p "  Numbers to toggle (e.g. 3 5), or Enter to continue: " reply </dev/tty || return 1
        [[ -z $reply ]] && break
        read -ra nums <<<"${reply//,/ }"
        for num in "${nums[@]}"; do
          if [[ $num =~ ^[0-9]+$ ]] && ((num >= 1 && num <= ${#keys[@]})); then
            n=$((num - 1))
            if [[ ${states[$n]} == on ]]; then states[n]=off; else states[n]=on; fi
          fi
        done
      done
      for n in "${!keys[@]}"; do
        [[ ${states[$n]} == on ]] && printf '%s\n' "${keys[$n]}"
      done
      return 0
      ;;
  esac
}

# ui_input PROMPT [DEFAULT]: print the answer.
ui_input() {
  case $UI_BACKEND in
    gum) _gum input --header "$1" --value "${2:-}" --placeholder "$1" ;;
    whiptail)
      _ui_size
      _whiptail --inputbox "$1" 9 $((UI_COLS - 4)) "${2:-}"
      ;;
    *)
      local reply
      read -r -p "  $1${2:+ [$2]}: " reply </dev/tty || return 1
      printf '%s\n' "${reply:-${2:-}}"
      ;;
  esac
}

# ui_confirm QUESTION [no]: true on yes. The default answer is yes unless
# the second argument is "no".
ui_confirm() {
  local default=${2:-yes} reply
  case $UI_BACKEND in
    gum) _gum confirm --default="$([[ $default == yes ]] && echo true || echo false)" "$1" ;;
    whiptail)
      _ui_size
      local args=()
      [[ $default == no ]] && args=(--defaultno)
      _whiptail "${args[@]}" --yesno "$1" 9 $((UI_COLS - 4))
      ;;
    *)
      if [[ $default == yes ]]; then
        read -r -p "$1 [Y/n] " reply </dev/tty || return 1
        [[ -z $reply || $reply =~ ^[Yy] ]]
      else
        read -r -p "$1 [y/N] " reply </dev/tty || return 1
        [[ $reply =~ ^[Yy] ]]
      fi
      ;;
  esac
}

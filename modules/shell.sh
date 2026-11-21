# shellcheck shell=bash disable=SC2034
# zsh with the starship prompt and two popular plugins. The tools installed
# by the other modules keep working in zsh: both shells read the same
# ~/.wslforge/env.sh (see shell_env_setup in lib/common.sh).

MODULE_NAME='zsh + starship'
MODULE_ORDER=80
MODULE_GROUP='Shell'
MODULE_DEFAULT=off
MODULE_FAMILIES='apt dnf pacman'

MODULE_ITEMS=(
  'zsh|Z shell, set up with history, completion and a few aliases'
  'starship|Fast, informative prompt (also used in bash)'
  'zsh-autosuggestions|Suggests commands as you type, from your history'
  'zsh-syntax-highlighting|Colors commands as you type them'
  'default-shell|Make zsh your login shell (instead of bash)'
)

# Pinned plugin releases, downloaded from GitHub (some distros, like
# AlmaLinux, do not package them).
ZSH_PLUGINS_DIR="$HOME/.local/share/wslforge/zsh"
ZSH_PLUGIN_VERSIONS=(
  'zsh-autosuggestions|v0.7.1'
  'zsh-syntax-highlighting|0.8.0'
)
STARSHIP_BIN="$HOME/.local/bin/starship"
SHELL_USER=${USER:-$(id -un)}

_login_shell() {
  getent passwd "$SHELL_USER" | cut -d: -f7
}

is_installed() {
  case $1 in
    zsh) has_cmd zsh ;;
    starship) [[ -x $STARSHIP_BIN ]] || has_cmd starship ;;
    default-shell) [[ $(_login_shell) == */zsh ]] ;;
    *) [[ -f $ZSH_PLUGINS_DIR/$1/$1.zsh ]] ;;
  esac
}

do_install() {
  local item
  if in_list zsh "$@"; then
    pkg_install zsh
  fi
  if in_list starship "$@"; then
    run mkdir -p "$(dirname "$STARSHIP_BIN")"
    run_installer https://starship.rs/install.sh sh -y -b "$(dirname "$STARSHIP_BIN")"
  fi
  for item in zsh-autosuggestions zsh-syntax-highlighting; do
    if in_list "$item" "$@"; then
      _shell_plugin "$item"
    fi
  done
  if in_list default-shell "$@"; then
    _shell_make_default
  fi
}

# _shell_plugin NAME: download the pinned release of a zsh plugin.
_shell_plugin() {
  local name=$1 entry version='' tmp rc=0
  for entry in "${ZSH_PLUGIN_VERSIONS[@]}"; do
    [[ ${entry%%|*} == "$name" ]] && version=${entry#*|}
  done
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "download $name $version into $ZSH_PLUGINS_DIR/$name"
    return 0
  fi
  tmp=$(mktemp -d)
  if fetch_verified "https://github.com/zsh-users/$name/archive/refs/tags/$version.tar.gz" "$tmp/plugin.tar.gz" &&
    tar -xzf "$tmp/plugin.tar.gz" -C "$tmp"; then
    mkdir -p "$ZSH_PLUGINS_DIR"
    rm -rf "${ZSH_PLUGINS_DIR:?}/$name"
    mv "$tmp/$name-${version#v}" "$ZSH_PLUGINS_DIR/$name" || rc=1
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

_shell_make_default() {
  local zsh
  zsh=$(command -v zsh || true)
  if [[ -z $zsh ]]; then
    if [[ $DRY_RUN == 1 ]]; then
      zsh=/usr/bin/zsh
    else
      log_error "'default-shell' needs zsh; do not skip zsh."
      return 1
    fi
  fi
  if ! grep -qx "$zsh" /etc/shells 2>/dev/null; then
    write_root_file /etc/shells "$(cat /etc/shells 2>/dev/null)
$zsh"
  fi
  as_root usermod -s "$zsh" "$SHELL_USER"
}

configure() {
  shell_env_setup
  has_cmd zsh || return 0
  # shellcheck disable=SC2016  # expanded by zsh, not here
  rc_block "$HOME/.zshrc" '# zsh settings from wslforge (rewritten on every run; add yours outside).
[ -f "$HOME/.wslforge/env.sh" ] && . "$HOME/.wslforge/env.sh"
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_all_dups hist_reduce_blanks auto_cd interactive_comments
bindkey -e
autoload -Uz compinit && compinit
zstyle ":completion:*" menu select
zstyle ":completion:*" matcher-list "m:{a-z}={A-Za-z}"
alias ls="ls --color=auto" ll="ls -lAh" la="ls -A" grep="grep --color=auto"
for _p in zsh-autosuggestions zsh-syntax-highlighting; do
  [ -f "$HOME/.local/share/wslforge/zsh/$_p/$_p.zsh" ] && . "$HOME/.local/share/wslforge/zsh/$_p/$_p.zsh"
done
unset _p'
}

notes() {
  if is_installed default-shell && [[ ${SHELL:-} != */zsh ]]; then
    need_new_shell 'zsh'
  elif is_installed zsh && ! is_installed default-shell; then
    # shellcheck disable=SC2016  # for the user to type
    echo 'Try zsh by typing zsh; make it your login shell with: chsh -s "$(command -v zsh)"'
  fi
}

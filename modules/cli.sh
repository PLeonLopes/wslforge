# shellcheck shell=bash disable=SC2034
# Modern command-line tools.

MODULE_NAME='Modern CLI tools'
MODULE_ORDER=20
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  'ripgrep|rg: very fast text search (grep alternative)'
  'fd|Fast, simple alternative to find'
  'bat|cat with syntax highlighting and line numbers'
  'fzf|Fuzzy finder for files, history and more'
  'tmux|Terminal multiplexer: split panes, keep sessions'
)

# Debian and Ubuntu ship fd and bat as "fdfind" and "batcat"; we expose the
# usual names through symlinks in ~/.local/bin.
CLI_BIN_DIR="$HOME/.local/bin"

_cli_alias_ok() {
  has_cmd "$1" || [[ -e $CLI_BIN_DIR/$1 ]]
}

# _cli_link SOURCE NAME: expose the SOURCE command as NAME.
_cli_link() {
  local src=$1 name=$2 target
  _cli_alias_ok "$name" && return 0
  target=$(command -v "$src" || echo "/usr/bin/$src")
  run mkdir -p "$CLI_BIN_DIR"
  run ln -s "$target" "$CLI_BIN_DIR/$name"
}

is_installed() {
  pkgs_installed "$1" || return 1
  case $1 in
    fd) _cli_alias_ok fd ;;
    bat) _cli_alias_ok bat ;;
  esac
}

do_install() {
  pkg_install "$@"
  if in_list fd "$@"; then
    _cli_link fdfind fd
  fi
  if in_list bat "$@"; then
    _cli_link batcat bat
  fi
}

notes() {
  if [[ -L $CLI_BIN_DIR/fd || -L $CLI_BIN_DIR/bat ]] && [[ ":$PATH:" != *":$CLI_BIN_DIR:"* ]]; then
    echo "Open a new terminal so ~/.local/bin is on your PATH (needed for fd and bat)."
  fi
}

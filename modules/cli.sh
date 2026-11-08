# shellcheck shell=bash disable=SC2034
# Modern command-line tools.

MODULE_NAME='Modern CLI tools'
MODULE_DESC='ripgrep, fd, bat, fzf, tmux'
MODULE_ORDER=20
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

CLI_PACKAGES=(ripgrep fd bat fzf tmux)

# Debian and Ubuntu ship fd and bat as "fdfind" and "batcat"; we expose the
# usual names through symlinks in ~/.local/bin.
CLI_ALIASES=(fdfind:fd batcat:bat)
CLI_BIN_DIR="$HOME/.local/bin"

_cli_alias_ok() {
  has_cmd "$1" || [[ -e $CLI_BIN_DIR/$1 ]]
}

is_installed() {
  local pair
  pkgs_installed "${CLI_PACKAGES[@]}" || return 1
  for pair in "${CLI_ALIASES[@]}"; do
    _cli_alias_ok "${pair#*:}" || return 1
  done
}

do_install() {
  local pair src name target
  pkg_install "${CLI_PACKAGES[@]}"

  for pair in "${CLI_ALIASES[@]}"; do
    src=${pair%%:*}
    name=${pair#*:}
    _cli_alias_ok "$name" && continue
    target=$(command -v "$src" || echo "/usr/bin/$src")
    run mkdir -p "$CLI_BIN_DIR"
    run ln -s "$target" "$CLI_BIN_DIR/$name"
  done
}

notes() {
  if [[ ":$PATH:" != *":$CLI_BIN_DIR:"* ]]; then
    echo "Open a new terminal so ~/.local/bin is on your PATH (needed for fd and bat)."
  fi
}

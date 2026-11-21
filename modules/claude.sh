# shellcheck shell=bash disable=SC2034
# Claude Code, through Anthropic's native installer (no Node.js needed).

MODULE_NAME='Claude Code'
MODULE_ORDER=70
MODULE_DEFAULT=on
MODULE_FAMILIES='apt dnf pacman'
MODULE_ROOT=no      # installs into the home directory only

MODULE_ITEMS=(
  "claude|Claude Code, Anthropic's AI coding assistant for the terminal"
)

is_installed() {
  has_cmd claude || [[ -x $HOME/.local/bin/claude ]]
}

do_install() {
  run_installer https://claude.ai/install.sh bash
}

# ~/.claude.json only exists after Claude Code has been started once.
actions() {
  local claude
  if [[ ! -f $HOME/.claude.json ]]; then
    claude=$(command -v claude || echo "$HOME/.local/bin/claude")
    printf 'Log in to Claude Code (type /exit when done)|%q\n' "$claude"
  fi
}

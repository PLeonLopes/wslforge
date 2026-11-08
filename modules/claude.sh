# shellcheck shell=bash disable=SC2034
# Claude Code, through Anthropic's native installer (no Node.js needed).

MODULE_NAME='Claude Code'
MODULE_ORDER=70
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  "claude|Claude Code, Anthropic's AI coding assistant for the terminal"
)

is_installed() {
  has_cmd claude || [[ -x $HOME/.local/bin/claude ]]
}

do_install() {
  run_installer https://claude.ai/install.sh bash
}

notes() {
  # ~/.claude.json only exists after Claude Code has been started once.
  if [[ ! -f $HOME/.claude.json ]]; then
    echo 'Start Claude Code and log in: claude'
  fi
}

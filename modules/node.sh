# shellcheck shell=bash disable=SC2034
# Node.js through fnm (https://github.com/Schniz/fnm), plus pnpm.

MODULE_NAME='Node.js (fnm) + pnpm'
MODULE_ORDER=50
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  'node|Node.js LTS, managed by fnm (switch versions per project)'
  'pnpm|Fast, disk-efficient package manager for Node.js'
)

FNM_DIR="$HOME/.local/share/fnm"
PNPM_DIR="$HOME/.local/share/pnpm"

is_installed() {
  case $1 in
    node) [[ -x $FNM_DIR/fnm ]] && "$FNM_DIR/fnm" exec --using=default node --version ;;
    # Newer pnpm versions install into $PNPM_HOME/bin; older ones into $PNPM_HOME.
    pnpm) has_cmd pnpm || [[ -x $PNPM_DIR/bin/pnpm || -x $PNPM_DIR/pnpm ]] ;;
  esac
}

do_install() {
  if in_list node "$@"; then
    if [[ ! -x $FNM_DIR/fnm ]]; then
      # The installer also adds fnm to ~/.bashrc.
      run_installer https://fnm.vercel.app/install bash --install-dir "$FNM_DIR"
    fi
    run "$FNM_DIR/fnm" install --lts
    run "$FNM_DIR/fnm" default lts-latest
  fi
  if in_list pnpm "$@"; then
    # Standalone pnpm (no corepack, which Node 25+ no longer ships). The
    # installer also adds PNPM_HOME to ~/.bashrc.
    run_installer https://get.pnpm.io/install.sh sh
  fi
}

notes() {
  if [[ -x $FNM_DIR/fnm ]] && ! has_cmd fnm; then
    echo 'Open a new terminal to load fnm and pnpm (node, npm and pnpm will then be on your PATH).'
  fi
}

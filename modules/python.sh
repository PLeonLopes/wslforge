# shellcheck shell=bash disable=SC2034
# Python tooling through uv (https://docs.astral.sh/uv/).

MODULE_NAME='Python (uv)'
MODULE_ORDER=40
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  'uv|Fast Python package and project manager (replaces pip, venv, pyenv)'
  'python|Latest Python, managed by uv (the system python3 is left untouched)'
)

# The uv installer puts the binary in ~/.local/bin, which may not be on the
# PATH of this session yet.
_uv_bin() {
  command -v uv || echo "$HOME/.local/bin/uv"
}

is_installed() {
  case $1 in
    uv) has_cmd uv || [[ -x $HOME/.local/bin/uv ]] ;;
    python) compgen -G "$("$(_uv_bin)" python dir 2>/dev/null)/cpython-*" >/dev/null ;;
  esac
}

do_install() {
  if in_list uv "$@"; then
    run_installer https://astral.sh/uv/install.sh sh
  fi
  if in_list python "$@"; then
    if ! is_installed uv && [[ $DRY_RUN != 1 ]]; then
      log_error "'python' is installed through uv; do not skip uv."
      return 1
    fi
    run "$(_uv_bin)" python install
  fi
}

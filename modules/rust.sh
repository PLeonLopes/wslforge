# shellcheck shell=bash disable=SC2034
# Rust through rustup (https://rustup.rs), the official toolchain installer.

MODULE_NAME='Rust (rustup)'
MODULE_ORDER=54
MODULE_GROUP='Languages'
MODULE_DEFAULT=off
MODULE_FAMILIES='apt dnf pacman'
MODULE_ROOT=no      # installs into the home directory only

MODULE_ITEMS=(
  'rust|Stable Rust (rustc, cargo, clippy, rustfmt), managed by rustup'
)

CARGO_BIN="$HOME/.cargo/bin"

is_installed() {
  [[ -x $CARGO_BIN/rustc ]] && "$CARGO_BIN/rustc" --version
}

do_install() {
  # The PATH entry comes from wslforge's env file, not from rustup.
  run_installer https://sh.rustup.rs sh -y --no-modify-path --profile default
}

configure() {
  shell_env_setup
}

notes() {
  if [[ -x $CARGO_BIN/cargo ]] && ! has_cmd cargo; then
    need_new_shell 'cargo'
  fi
}

# shellcheck shell=bash disable=SC2034
# Go from the official go.dev release (distro packages are often outdated).

MODULE_NAME='Go'
MODULE_ORDER=52
MODULE_GROUP='Languages'
MODULE_DEFAULT=off
MODULE_FAMILIES='apt dnf pacman'

MODULE_ITEMS=(
  'go|Latest Go toolchain from go.dev, in /usr/local/go'
)

GO_ROOT=/usr/local/go

is_installed() {
  [[ -x $GO_ROOT/bin/go ]] && "$GO_ROOT/bin/go" version
}

do_install() {
  local release version file sha tmp rc=0
  if [[ $DRY_RUN == 1 ]]; then
    _print_dry "download the latest Go from go.dev into $GO_ROOT"
    return 0
  fi
  has_cmd jq || pkg_install jq
  # The first stable release in the list is the newest one.
  release=$(fetch_url 'https://go.dev/dl/?mode=json') || return 1
  version=$(jq -r '.[0].version' <<<"$release")
  file="$version.linux-$(cpu_arch).tar.gz"
  sha=$(jq -r --arg f "$file" '.[0].files[] | select(.filename == $f) | .sha256' <<<"$release")
  [[ -n $sha ]] || die "No Go download for $(cpu_arch)."

  log_info "Go $version"
  tmp=$(mktemp -d)
  if fetch_verified "https://go.dev/dl/$file" "$tmp/$file" "$sha"; then
    as_root rm -rf "$GO_ROOT"
    as_root tar -C "$(dirname "$GO_ROOT")" -xzf "$tmp/$file" || rc=1
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

configure() {
  shell_env_setup
}

notes() {
  if [[ -x $GO_ROOT/bin/go ]] && ! has_cmd go; then
    need_new_shell 'go'
  fi
}

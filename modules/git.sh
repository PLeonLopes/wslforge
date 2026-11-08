# shellcheck shell=bash disable=SC2034
# Git, Git LFS, GitHub CLI and the global git identity.

MODULE_NAME='Git + GitHub CLI'
MODULE_ORDER=30
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  'git|Version control, plus your git identity (name/email)'
  'git-lfs|Git extension for large files'
  'ssh-client|SSH client, used to push and pull over SSH'
  'gh|GitHub CLI: login, pull requests, issues'
)

is_installed() {
  case $1 in
    gh) has_cmd gh ;;
    *) pkgs_installed "$1" ;;
  esac
}

do_install() {
  local item packages=()
  for item in "$@"; do
    [[ $item == gh ]] || packages+=("$item")
  done
  if ((${#packages[@]})); then
    pkg_install "${packages[@]}"
  fi

  # The distro gh packages lag behind, so use GitHub's official repository.
  if in_list gh "$@"; then
    apt_add_repo github-cli \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      'https://cli.github.com/packages stable main'
    pkg_install gh
  fi

  if in_list git-lfs "$@"; then
    run git lfs install --skip-repo
  fi
}

# Runs on every execution, so the identity can be set or changed later.
configure() {
  if ! has_cmd git && [[ $DRY_RUN != 1 ]]; then
    return 0
  fi
  if [[ -z $(git config --global --get init.defaultBranch 2>/dev/null) ]]; then
    run git config --global init.defaultBranch main
  fi
  _git_identity user.name "$GIT_NAME" 'Git user name'
  _git_identity user.email "$GIT_EMAIL" 'Git email'
}

# _git_identity KEY VALUE LABEL: set KEY from VALUE (config), or ask the user
# when it is still empty.
_git_identity() {
  local key=$1 value=$2 label=$3 current
  current=$(git config --global --get "$key" 2>/dev/null || true)

  if [[ -z $value && -z $current && $DRY_RUN != 1 ]]; then
    value=$(ask "$label") || value=''
  fi
  if [[ -n $value && $value != "$current" ]]; then
    run git config --global "$key" "$value"
    log_ok "git $key = $value"
  fi
}

notes() {
  if has_cmd git && [[ -z $(git config --global --get user.name) || -z $(git config --global --get user.email) ]]; then
    echo 'Set your git identity: git config --global user.name "Your Name" && git config --global user.email "you@example.com"'
  fi
  if has_cmd gh && ! gh auth status >/dev/null 2>&1; then
    echo 'Log in to GitHub: gh auth login (choose SSH; it can create and upload a key for you)'
  fi
}

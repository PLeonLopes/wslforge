# shellcheck shell=bash disable=SC2034
# Git, Git LFS, GitHub CLI and the global git identity.

MODULE_NAME='Git + GitHub CLI'
MODULE_DESC='git, git-lfs, gh and your git identity (name/email)'
MODULE_ORDER=30
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

GIT_PACKAGES=(git git-lfs ssh-client)

is_installed() {
  pkgs_installed "${GIT_PACKAGES[@]}" && has_cmd gh
}

do_install() {
  pkg_install "${GIT_PACKAGES[@]}"

  # The distro gh packages lag behind, so use GitHub's official repository.
  if ! has_cmd gh; then
    apt_add_repo github-cli \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      'https://cli.github.com/packages stable main'
    pkg_install gh
  fi

  run git lfs install --skip-repo
}

# Runs on every execution, so the identity can be set or changed later.
configure() {
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
  if [[ -z $(git config --global --get user.name 2>/dev/null) || -z $(git config --global --get user.email 2>/dev/null) ]]; then
    echo 'Set your git identity: git config --global user.name "Your Name" && git config --global user.email "you@example.com"'
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo 'Log in to GitHub: gh auth login (choose SSH; it can create and upload a key for you)'
  fi
}

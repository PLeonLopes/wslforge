# shellcheck shell=bash disable=SC2034
# Docker Engine running inside WSL (no Docker Desktop needed).

MODULE_NAME='Docker Engine'
MODULE_ORDER=60
MODULE_DEFAULT=on
MODULE_FAMILIES='apt'

MODULE_ITEMS=(
  'docker|Docker Engine with Compose and Buildx, running inside WSL'
)

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_USER=${USER:-$(id -un)}

_systemd_running() {
  [[ -d /run/systemd/system ]]
}

# Docker's repository only has ubuntu and debian trees.
_docker_repo_distro() {
  if [[ $DISTRO_ID == ubuntu ]]; then echo ubuntu; else echo debian; fi
}

# Checks packages, not the "docker" command: Docker Desktop's WSL integration
# puts its own docker binary (from /mnt/c) on the PATH.
is_installed() {
  pkgs_installed "${DOCKER_PACKAGES[@]}" || return 1
  if is_wsl; then
    [[ $(ini_get /etc/wsl.conf boot systemd) == true ]] || return 1
  fi
  if [[ $EUID -ne 0 ]]; then
    id -nG "$DOCKER_USER" | grep -qw docker || return 1
  fi
}

do_install() {
  local distro
  distro=$(_docker_repo_distro)
  apt_add_repo docker \
    "https://download.docker.com/linux/$distro/gpg" \
    "https://download.docker.com/linux/$distro $DISTRO_CODENAME stable"
  pkg_install "${DOCKER_PACKAGES[@]}"

  # Run docker without sudo (takes effect in a new login shell).
  if [[ $EUID -ne 0 ]] && ! id -nG "$DOCKER_USER" | grep -qw docker; then
    as_root usermod -aG docker "$DOCKER_USER"
  fi

  # Docker runs as a systemd service, and WSL only starts systemd when
  # /etc/wsl.conf asks for it.
  if is_wsl; then
    ensure_ini_key /etc/wsl.conf boot systemd true
  fi
  if _systemd_running; then
    as_root systemctl enable --now docker
  fi
}

notes() {
  if is_wsl && ! _systemd_running; then
    echo 'Restart WSL to start systemd (needed by Docker): run "wsl --shutdown" in Windows PowerShell, then reopen this terminal.'
  fi
  if [[ $EUID -ne 0 ]] && ! id -nG | grep -qw docker; then
    echo 'Open a new terminal (or run "newgrp docker") to use docker without sudo.'
  fi
  # Docker Desktop mounts this directory in distros where its WSL integration
  # is on. (A docker.exe shim from the Windows PATH alone is harmless:
  # /usr/bin/docker comes first on the PATH.)
  if [[ -d /mnt/wsl/docker-desktop ]]; then
    echo 'Docker Desktop integration is also enabled for this distro; turn it off in Docker Desktop > Settings > Resources > WSL integration to use the engine installed here.'
  fi
}

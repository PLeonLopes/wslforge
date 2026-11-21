# shellcheck shell=bash disable=SC2034
# Cloud and infrastructure CLIs. Each one comes from its vendor: release
# binaries with a checksum where they exist (the same on every distro),
# otherwise the vendor's package repository or the distro's own package.

MODULE_NAME='Cloud CLIs'
MODULE_ORDER=65
MODULE_GROUP='Containers & Cloud'
MODULE_DEFAULT=off
MODULE_FAMILIES='apt dnf pacman'

MODULE_ITEMS=(
  'aws|AWS CLI v2'
  'azure|Azure CLI (az)'
  'gcloud|Google Cloud CLI, in ~/.local/share/google-cloud-sdk'
  'terraform|Terraform, infrastructure as code'
  'kubectl|Kubernetes command-line tool'
  'helm|Kubernetes package manager'
)

BIN_DIR=/usr/local/bin
GCLOUD_DIR="$HOME/.local/share/google-cloud-sdk"

is_installed() {
  case $1 in
    aws) [[ -x $BIN_DIR/aws ]] || has_cmd aws ;;
    azure) has_cmd az ;;
    gcloud) [[ -x $GCLOUD_DIR/bin/gcloud ]] ;;
    *) [[ -x $BIN_DIR/$1 ]] || has_cmd "$1" ;;
  esac
}

do_install() {
  local item
  if [[ $DRY_RUN == 1 ]]; then
    for item in "$@"; do
      _print_dry "install $item from its vendor"
    done
    return 0
  fi
  has_cmd unzip || pkg_install unzip
  has_cmd jq || pkg_install jq
  # One failure does not stop the others; the summary lists what failed.
  for item in "$@"; do
    log_info "$item"
    "_cloud_$item" || log_error "Could not install $item."
  done
}

configure() {
  shell_env_setup
}

notes() {
  local logins=()
  is_installed aws && logins+=('aws configure')
  is_installed azure && logins+=('az login')
  is_installed gcloud && logins+=('gcloud init')
  if ((${#logins[@]})); then
    echo "Sign in to your clouds: $(join_by ', ' "${logins[@]}")"
  fi
  if is_installed gcloud && ! has_cmd gcloud; then
    need_new_shell 'gcloud'
  fi
}

# _cloud_in_tmp FUNCTION: run FUNCTION inside a fresh temporary directory.
_cloud_in_tmp() {
  local tmp rc=0
  tmp=$(mktemp -d)
  (cd "$tmp" && "$1") || rc=1
  rm -rf "$tmp"
  return "$rc"
}

_cloud_aws() { _cloud_in_tmp _cloud_aws_tmp; }
_cloud_aws_tmp() {
  fetch_verified "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" aws.zip &&
    unzip -q aws.zip &&
    as_root ./aws/install --update --bin-dir "$BIN_DIR"
}

_cloud_azure() {
  case $DISTRO_FAMILY in
    apt)
      # Microsoft publishes for some releases only; others use the closest.
      local suite=$DISTRO_CODENAME
      if ! curl -fsI "https://packages.microsoft.com/repos/azure-cli/dists/$suite/Release" >/dev/null 2>&1; then
        suite=bookworm
        [[ $DISTRO_ID == ubuntu ]] && suite=noble
      fi
      apt_add_repo azure-cli https://packages.microsoft.com/keys/microsoft.asc \
        "https://packages.microsoft.com/repos/azure-cli/ $suite main"
      ;;
    dnf)
      # Fedora packages it; RHEL rebuilds use Microsoft's repository.
      if [[ $DISTRO_ID != fedora ]]; then
        rpm_add_repo microsoft-prod "https://packages.microsoft.com/config/rhel/${DISTRO_VERSION%%.*}/prod.repo"
      fi
      ;;
  esac
  pkg_install azure-cli
}

_cloud_gcloud() { _cloud_in_tmp _cloud_gcloud_tmp; }
_cloud_gcloud_tmp() {
  local arch=x86_64
  [[ $(cpu_arch) == arm64 ]] && arch=arm
  # The archive brings its own Python, so nothing else is needed.
  fetch_verified "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-$arch.tar.gz" gcloud.tar.gz &&
    tar -xzf gcloud.tar.gz &&
    rm -rf "$GCLOUD_DIR" &&
    mkdir -p "$(dirname "$GCLOUD_DIR")" &&
    mv google-cloud-sdk "$GCLOUD_DIR"
}

_cloud_terraform() { _cloud_in_tmp _cloud_terraform_tmp; }
_cloud_terraform_tmp() {
  local version file base sha
  version=$(fetch_url https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version) || return 1
  base="https://releases.hashicorp.com/terraform/$version"
  file="terraform_${version}_linux_$(cpu_arch).zip"
  sha=$(fetch_url "$base/terraform_${version}_SHA256SUMS" | awk -v f="$file" '$2 == f { print $1 }')
  [[ -n $sha ]] || return 1
  fetch_verified "$base/$file" "$file" "$sha" &&
    unzip -q "$file" terraform &&
    as_root install -m 755 terraform "$BIN_DIR/terraform"
}

_cloud_kubectl() { _cloud_in_tmp _cloud_kubectl_tmp; }
_cloud_kubectl_tmp() {
  local version url sha
  version=$(fetch_url https://dl.k8s.io/release/stable.txt) || return 1
  url="https://dl.k8s.io/release/$version/bin/linux/$(cpu_arch)/kubectl"
  sha=$(fetch_url "$url.sha256") || return 1
  fetch_verified "$url" kubectl "$sha" &&
    as_root install -m 755 kubectl "$BIN_DIR/kubectl"
}

_cloud_helm() { _cloud_in_tmp _cloud_helm_tmp; }
_cloud_helm_tmp() {
  local version file sha
  version=$(fetch_url https://get.helm.sh/helm-latest-version) || return 1
  file="helm-$version-linux-$(cpu_arch).tar.gz"
  sha=$(fetch_url "https://get.helm.sh/$file.sha256sum" | awk '{ print $1 }')
  [[ -n $sha ]] || return 1
  fetch_verified "https://get.helm.sh/$file" "$file" "$sha" &&
    tar -xzf "$file" &&
    as_root install -m 755 "linux-$(cpu_arch)/helm" "$BIN_DIR/helm"
}

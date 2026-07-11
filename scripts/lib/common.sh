#!/usr/bin/env bash

DOCKMASTER_K3S_VERSION="${DOCKMASTER_K3S_VERSION:-v1.33.13+k3s1}"
DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256="${DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256:-9ca7930c31179d83bc13de20078fd8ad3e1ee00875b31f39a7e524ca4ef7d9de}"
DOCKMASTER_FLUX_VERSION="${DOCKMASTER_FLUX_VERSION:-v2.8.3}"
DOCKMASTER_FLUX_SHA256_AMD64="${DOCKMASTER_FLUX_SHA256_AMD64:-e8b3f87ae73f37656af087cec1bd82ce9034860c2a5d427042d2ee9135fcc8bc}"
DOCKMASTER_FLUX_SHA256_ARM64="${DOCKMASTER_FLUX_SHA256_ARM64:-8f02cd3c2f058434b40cb264d4f3d961a3d5bc7c4985cc4544946f9b8224632b}"

log_step() {
  echo "[..] $1"
}

log_ok() {
  echo "[OK] $1"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$cmd' is not available"
    exit 1
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (use sudo)"
    exit 1
  fi
}

install_apt_packages_if_missing() {
  local missing_packages=()
  local package

  for package in "$@"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      missing_packages+=("$package")
    fi
  done

  if ((${#missing_packages[@]} == 0)); then
    log_ok "Required apt packages already installed"
    return
  fi

  log_step "Installing required apt packages: ${missing_packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing_packages[@]}"
  log_ok "Required apt packages installed"
}

allow_ufw_rule_if_missing() {
  local rule="$1"
  if ufw status | grep -Fq "$rule"; then
    log_ok "ufw rule already present for $rule"
  else
    log_step "Allowing $rule through ufw..."
    ufw allow "$rule"
  fi
}

configure_ufw() {
  local rule

  for rule in OpenSSH 80/tcp 443/tcp; do
    allow_ufw_rule_if_missing "$rule"
  done

  if [[ -n "${K8S_API_ALLOW_CIDR:-}" ]]; then
    allow_ufw_rule_if_missing "from ${K8S_API_ALLOW_CIDR} to any port 6443 proto tcp"
    log_ok "Restricted Kubernetes API access enabled for ${K8S_API_ALLOW_CIDR}"
  else
    echo "[OK] Kubernetes API port 6443 remains closed in ufw by default"
  fi

  if ufw status | grep -Fq "Status: active"; then
    log_ok "ufw already enabled"
  else
    log_step "Enabling ufw..."
    ufw --force enable
    log_ok "ufw enabled"
  fi
}

setup_traefik_log_dir() {
  mkdir -p /var/log/traefik
  chown 65532:65532 /var/log/traefik
  log_ok "Traefik access log directory ready"
}

configure_journald_retention() {
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/dockmaster.conf <<'CONF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=14day
CONF
  systemctl restart systemd-journald
  log_ok "journald retention configured"
}

configure_inotify_limits() {
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-dockmaster-inotify.conf <<'CONF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 262144
fs.inotify.max_queued_events = 32768
CONF
  sysctl --system >/dev/null
  log_ok "inotify sysctl limits configured"
}

configure_k3s_base_config() {
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml <<'CONF'
kubelet-arg:
  - "container-log-max-files=3"
  - "container-log-max-size=10Mi"
CONF
  log_ok "k3s config written"
}

lookup_passwd_field() {
  local user_name="$1"
  local field_index="$2"

  awk -F: -v user_name="$user_name" -v field_index="$field_index" '$1 == user_name { print $field_index; exit }' /etc/passwd
}

setup_user_kubeconfig() {
  local target_user="$1"
  local home_dir
  local login_shell
  local shell_rc

  home_dir="$(lookup_passwd_field "$target_user" 6)"
  login_shell="$(lookup_passwd_field "$target_user" 7)"

  if [[ -z "$home_dir" ]]; then
    echo "[ERROR] Could not determine home directory for user '$target_user'"
    exit 1
  fi

  install -d -m 700 -o "$target_user" -g "$target_user" "$home_dir/.kube"
  install -m 600 -o "$target_user" -g "$target_user" /etc/rancher/k3s/k3s.yaml "$home_dir/.kube/config"

  case "${login_shell##*/}" in
    zsh)
      shell_rc="$home_dir/.zshrc"
      ;;
    bash)
      shell_rc="$home_dir/.bashrc"
      ;;
    *)
      shell_rc="$home_dir/.profile"
      ;;
  esac

  touch "$shell_rc"
  chown "$target_user:$target_user" "$shell_rc"
  if ! grep -q 'export KUBECONFIG=\$HOME/.kube/config' "$shell_rc" 2>/dev/null; then
    echo 'export KUBECONFIG=$HOME/.kube/config' >> "$shell_rc"
  fi

  export KUBECONFIG="$home_dir/.kube/config"
  log_ok "kubeconfig installed for user '$target_user' at $KUBECONFIG"
}

local_node_name() {
  if [[ -n "${K3S_NODE_NAME:-}" ]]; then
    echo "$K3S_NODE_NAME"
  else
    hostname
  fi
}

wait_for_local_node_ready() {
  local node_name
  node_name="$(local_node_name)"

  log_step "Waiting for node '$node_name' to register..."
  until kubectl get node "$node_name" >/dev/null 2>&1; do
    sleep 2
  done

  log_step "Waiting for node '$node_name' to be ready..."
  kubectl wait --for=condition=Ready "node/$node_name" --timeout=180s
  log_ok "Node '$node_name' ready"
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo "[ERROR] Neither sha256sum nor shasum is available"
    exit 1
  fi
}

verify_sha256() {
  local file="$1"
  local expected_sha256="$2"
  local actual_sha256

  actual_sha256="$(sha256_file "$file")"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "[ERROR] SHA256 mismatch for $file"
    echo "  expected: $expected_sha256"
    echo "  actual:   $actual_sha256"
    exit 1
  fi
}

download_verified_k3s_install_script() {
  local install_script
  install_script="$(mktemp)"

  curl -fsSL "https://raw.githubusercontent.com/k3s-io/k3s/${DOCKMASTER_K3S_VERSION}/install.sh" -o "$install_script"
  verify_sha256 "$install_script" "$DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256"
  chmod 700 "$install_script"
  echo "$install_script"
}

run_verified_k3s_installer() {
  local install_script
  local status=0
  install_script="$(download_verified_k3s_install_script)"

  INSTALL_K3S_VERSION="$DOCKMASTER_K3S_VERSION" "$install_script" "$@" || status=$?
  rm -f "$install_script"
  return "$status"
}

detect_linux_arch() {
  case "$(uname -m)" in
    x86_64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      echo "[ERROR] Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

flux_sha256_for_arch() {
  case "$1" in
    amd64)
      echo "$DOCKMASTER_FLUX_SHA256_AMD64"
      ;;
    arm64)
      echo "$DOCKMASTER_FLUX_SHA256_ARM64"
      ;;
    *)
      echo "[ERROR] Unsupported Flux architecture: $1" >&2
      exit 1
      ;;
  esac
}

ensure_flux_cli_installed() {
  local desired_version="${DOCKMASTER_FLUX_VERSION#v}"
  local current_version=""
  local arch
  local tarball
  local tmp_dir
  local status=0

  require_command tar

  if command -v flux >/dev/null 2>&1; then
    current_version="$(flux --version 2>/dev/null | awk '{print $3}')"
  fi

  if [[ "$current_version" == "$desired_version" ]]; then
    log_ok "Flux CLI ${DOCKMASTER_FLUX_VERSION} already installed"
    return
  fi

  arch="$(detect_linux_arch)"
  tarball="flux_${desired_version}_linux_${arch}.tar.gz"
  tmp_dir="$(mktemp -d)"

  log_step "Installing Flux CLI ${DOCKMASTER_FLUX_VERSION}..."
  curl -fsSL "https://github.com/fluxcd/flux2/releases/download/${DOCKMASTER_FLUX_VERSION}/${tarball}" -o "${tmp_dir}/${tarball}"
  verify_sha256 "${tmp_dir}/${tarball}" "$(flux_sha256_for_arch "$arch")"
  tar -xzf "${tmp_dir}/${tarball}" -C "$tmp_dir" flux || status=$?
  if ((status == 0)); then
    install -m 755 "${tmp_dir}/flux" /usr/local/bin/flux || status=$?
  fi
  rm -rf "$tmp_dir"
  if ((status != 0)); then
    return "$status"
  fi
  log_ok "Flux CLI ${DOCKMASTER_FLUX_VERSION} installed"
}

perform_common_node_setup() {
  install_apt_packages_if_missing "$@"
  require_command awk
  require_command grep
  require_command sed
  require_command systemctl
  require_command curl
  require_command git

  systemctl enable --now iscsid >/dev/null 2>&1 || true
  log_ok "iscsid service enabled"

  configure_journald_retention
  configure_inotify_limits
  configure_ufw
  setup_traefik_log_dir
  configure_k3s_base_config
}

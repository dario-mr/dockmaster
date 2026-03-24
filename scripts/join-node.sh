#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

echo "=== Dockmaster Node Join ==="

REQUIRED_APT_PACKAGES=(curl git open-iscsi ufw)
MODE="server"
K3S_SERVER_URL="${K3S_SERVER_URL:-}"
K3S_JOIN_TOKEN="${K3S_TOKEN:-}"

usage() {
  cat <<'EOF'
Usage:
  sudo -E bash scripts/join-node.sh --server-url https://<server>:6443 --token <token>
    Join an additional server node to an existing cluster.

  sudo -E bash scripts/join-node.sh --agent --server-url https://<server>:6443 --token <token>
    Join a worker-only agent node to an existing cluster.
EOF
}

log_step() {
  echo "[..] $1"
}

log_ok() {
  echo "[OK] $1"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command '$cmd' is not available"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        MODE="agent"
        shift
        ;;
      --server-url)
        [[ $# -ge 2 ]] || {
          echo "[ERROR] --server-url requires a value"
          usage
          exit 1
        }
        K3S_SERVER_URL="$2"
        shift 2
        ;;
      --token)
        [[ $# -ge 2 ]] || {
          echo "[ERROR] --token requires a value"
          usage
          exit 1
        }
        K3S_JOIN_TOKEN="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "[ERROR] Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$K3S_SERVER_URL" || -z "$K3S_JOIN_TOKEN" ]]; then
    echo "[ERROR] Join mode requires both --server-url and --token"
    usage
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

setup_traefik_log_dir() {
  mkdir -p /var/log/traefik
  chown 65532:65532 /var/log/traefik
  log_ok "Traefik access log directory ready"
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

install_k3s() {
  local install_type="k3s"
  local install_args=(server)

  if [[ "$MODE" == "agent" ]]; then
    install_type="k3s-agent"
    install_args=(agent)
  fi

  if systemctl is-enabled "$install_type" >/dev/null 2>&1 || systemctl is-active "$install_type" >/dev/null 2>&1; then
    log_ok "$install_type already installed"
    return
  fi

  log_step "Installing $install_type ($MODE mode)..."
  curl -sfL https://get.k3s.io | K3S_URL="$K3S_SERVER_URL" K3S_TOKEN="$K3S_JOIN_TOKEN" sh -s - "${install_args[@]}"
  log_ok "$install_type installed"
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

  if [ -z "$home_dir" ]; then
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
  echo "[OK] kubeconfig installed for user '$target_user' at $KUBECONFIG"
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

parse_args "$@"
require_root

install_apt_packages_if_missing "${REQUIRED_APT_PACKAGES[@]}"
require_command awk
require_command grep
require_command sed
require_command systemctl
require_command curl
require_command git

log_ok "Join mode: $MODE"

systemctl enable --now iscsid >/dev/null 2>&1 || true
log_ok "iscsid service enabled"

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/dockmaster.conf <<'CONF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=14day
CONF
systemctl restart systemd-journald
echo "[OK] journald retention configured"

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-dockmaster-inotify.conf <<'CONF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 262144
fs.inotify.max_queued_events = 32768
CONF
sysctl --system >/dev/null
echo "[OK] inotify sysctl limits configured"

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

setup_traefik_log_dir
configure_k3s_base_config
install_k3s

if [[ "$MODE" == "server" ]]; then
  TARGET_USER="${SUDO_USER:-$(id -un)}"
  setup_user_kubeconfig "$TARGET_USER"
  wait_for_local_node_ready
else
  log_ok "Agent node joined; skipping kubeconfig and kubectl verification"
fi

echo
echo "=== Join Complete ==="
if [[ "$MODE" == "agent" ]]; then
  echo "This worker node has joined the cluster."
else
  echo "This server node has joined the cluster."
fi
echo "Flux bootstrap is intentionally skipped on joined nodes."

echo
echo "=== Verification ==="
echo "Run these commands to verify the setup:"
if [[ "$MODE" == "agent" ]]; then
  echo "  systemctl status k3s-agent --no-pager"
else
  echo "  kubectl get nodes"
  echo "  kubectl get node $(local_node_name)"
fi
echo "  sudo ufw status"

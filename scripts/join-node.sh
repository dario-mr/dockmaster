#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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

Environment overrides:
  DOCKMASTER_K3S_VERSION                Override pinned k3s version (default: v1.36.2+k3s1)
  DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256  Override pinned k3s installer SHA256
EOF
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

install_k3s() {
  local install_type="k3s"
  local install_args=(server)

  if [[ "$MODE" == "agent" ]]; then
    install_type="k3s-agent"
    install_args=(agent)
  fi

  if systemctl is-enabled "$install_type" >/dev/null 2>&1 || systemctl is-active "$install_type" >/dev/null 2>&1; then
    log_ok "$install_type ${DOCKMASTER_K3S_VERSION} already installed"
    return
  fi

  log_step "Installing pinned $install_type ${DOCKMASTER_K3S_VERSION} ($MODE mode)..."
  K3S_URL="$K3S_SERVER_URL" K3S_TOKEN="$K3S_JOIN_TOKEN" run_verified_k3s_installer "${install_args[@]}"
  log_ok "$install_type ${DOCKMASTER_K3S_VERSION} installed"
}

parse_args "$@"
require_root

perform_common_node_setup "${REQUIRED_APT_PACKAGES[@]}"

log_ok "Join mode: $MODE"
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

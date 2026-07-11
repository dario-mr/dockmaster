#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

echo "=== Dockmaster Bootstrap ==="

REQUIRED_APT_PACKAGES=(curl git open-iscsi ufw)

usage() {
  cat <<'EOF'
Usage:
  sudo -E bash scripts/bootstrap.sh
    Install the first server for the cluster with embedded etcd and bootstrap Flux.

Environment overrides:
  DOCKMASTER_K3S_VERSION                Override pinned k3s version (default: v1.36.2+k3s1)
  DOCKMASTER_K3S_INSTALL_SCRIPT_SHA256  Override pinned k3s installer SHA256
  DOCKMASTER_FLUX_VERSION               Override pinned Flux CLI version (default: v2.9.1)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
}

wait_for_kustomization_ready() {
  local name="$1"
  log_step "Waiting for Flux kustomization '$name'..."
  flux reconcile kustomization "$name" -n flux-system --with-source
  kubectl wait kustomization/"$name" -n flux-system --for=condition=Ready=True --timeout=10m
  log_ok "Flux kustomization '$name' is ready"
}

install_k3s() {
  if systemctl is-enabled k3s >/dev/null 2>&1 || systemctl is-active k3s >/dev/null 2>&1; then
    log_ok "k3s ${DOCKMASTER_K3S_VERSION} already installed"
    return
  fi

  log_step "Installing pinned k3s ${DOCKMASTER_K3S_VERSION} (first server / embedded etcd)..."
  run_verified_k3s_installer server --cluster-init
  log_ok "k3s ${DOCKMASTER_K3S_VERSION} installed"
}

parse_args "$@"
require_root

perform_common_node_setup "${REQUIRED_APT_PACKAGES[@]}"
install_k3s

TARGET_USER="${SUDO_USER:-$(id -un)}"
setup_user_kubeconfig "$TARGET_USER"

wait_for_local_node_ready

log_step "Waiting for Traefik..."
kubectl wait --for=condition=Available deployment/traefik -n kube-system --timeout=180s
log_ok "Traefik running"

# Create apps namespace (so secrets can be applied before Flux runs)
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
echo "[OK] Namespaces 'apps' and 'observability' ensured"

ensure_flux_cli_installed

# Check GITHUB_TOKEN
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[ERROR] GITHUB_TOKEN environment variable is not set."
  echo "  Export it before running this script:"
  echo "  export GITHUB_TOKEN=ghp_your_token_here"
  exit 1
fi

# Bootstrap Flux only on the first server.
log_step "Bootstrapping Flux..."
flux bootstrap github \
  --owner=dario-mr \
  --repository=dockmaster \
  --branch=main \
  --path=clusters/production \
  --components-extra=image-reflector-controller,image-automation-controller \
  --read-write-key \
  --personal
kubectl wait --for=condition=Available deployment --all -n flux-system --timeout=180s
flux check --pre=false
log_ok "Flux bootstrapped"

log_step "Suspending app-facing Flux kustomizations until required secrets are applied..."
flux suspend kustomization observability -n flux-system || true
flux suspend kustomization apps -n flux-system || true
log_ok "Observability and apps kustomizations suspended"

wait_for_kustomization_ready infrastructure

echo
echo "=== Next Step Required ==="
echo "Observability and apps are intentionally suspended until secrets are present."
echo "1. Create and apply required secret files."
echo "   sudo bash scripts/apply-secrets.sh"
echo "2. Resume staged reconciliation."
echo "   sudo bash scripts/reconcile-apps.sh"

# Verification
echo ""
echo "=== Verification ==="
echo "Run these commands to verify the setup:"
echo "  kubectl get nodes"
echo "  kubectl get pods -n kube-system"
echo "  flux check"
echo "  flux get kustomizations"
echo "  kubectl get pods -n apps"
echo "  sudo ufw status"

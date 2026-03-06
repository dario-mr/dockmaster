#!/usr/bin/env bash
set -euo pipefail

echo "=== Dockmaster Bootstrap ==="

# 1. Install k3s (idempotent)
if command -v k3s &>/dev/null; then
  echo "[OK] k3s already installed"
else
  echo "[..] Installing k3s..."
  curl -sfL https://get.k3s.io | sh -
  echo "[OK] k3s installed"
fi

# Make kubeconfig available (persist for future shells)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! grep -q 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml' ~/.bashrc 2>/dev/null; then
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
fi

# 2. Wait for node to be ready
echo "[..] Waiting for node to be ready..."
until kubectl get nodes &>/dev/null; do
  sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=120s
echo "[OK] Node ready"

# 3. Wait for Traefik to be running
echo "[..] Waiting for Traefik..."
kubectl wait --for=condition=Available deployment/traefik -n kube-system --timeout=180s
echo "[OK] Traefik running"

# 4. Prepare Traefik access log directory (Traefik runs as UID 65532)
mkdir -p /var/log/traefik
chown 65532:65532 /var/log/traefik
echo "[OK] Traefik access log directory ready"

# 5. Create apps namespace (so secrets can be applied before Flux runs)
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
echo "[OK] Namespace 'apps' ensured"

# 6. Install Flux CLI (idempotent)
if command -v flux &>/dev/null; then
  echo "[OK] Flux CLI already installed"
else
  echo "[..] Installing Flux CLI..."
  curl -s https://fluxcd.io/install.sh | bash
  echo "[OK] Flux CLI installed"
fi

# 7. Check GITHUB_TOKEN
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[ERROR] GITHUB_TOKEN environment variable is not set."
  echo "  Export it before running this script:"
  echo "  export GITHUB_TOKEN=ghp_your_token_here"
  exit 1
fi

# 8. Bootstrap Flux
echo "[..] Bootstrapping Flux..."
flux bootstrap github \
  --owner=dario-mr \
  --repository=dockmaster \
  --branch=main \
  --path=clusters/production \
  --personal
echo "[OK] Flux bootstrapped"

# 9. Verification
echo ""
echo "=== Verification ==="
echo "Run these commands to verify the setup:"
echo "  kubectl get nodes"
echo "  kubectl get pods -n kube-system"
echo "  flux check"
echo "  flux get kustomizations"
echo "  kubectl get pods -n apps"

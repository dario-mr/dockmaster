#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

REQUIRED_SECRETS=(
  "crowdsec:crowdsec-secrets"
  "kube-system:crowdsec-bouncer-key"
  "kube-system:geoipupdate-secret"
  "observability:grafana-admin-secret"
  "apps:wordle-duel-service-secrets"
)

log_step() {
  echo "[..] $1"
}

log_ok() {
  echo "[OK] $1"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$cmd' is not installed"
    exit 1
  fi
}

ensure_secret_exists() {
  local namespace="$1"
  local secret_name="$2"

  if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    log_ok "Required secret '$namespace/$secret_name' exists"
  else
    echo "[ERROR] Required secret '$namespace/$secret_name' is missing"
    exit 1
  fi
}

wait_for_kustomization_ready() {
  local name="$1"
  log_step "Reconciling Flux kustomization '$name'..."
  flux resume kustomization "$name" -n flux-system
  flux reconcile kustomization "$name" -n flux-system --with-source
  kubectl wait kustomization/"$name" -n flux-system --for=condition=Ready=True --timeout=10m
  log_ok "Flux kustomization '$name' is ready"
}

echo "=== Dockmaster Staged Reconciliation ==="

require_command kubectl
require_command flux

for ref in "${REQUIRED_SECRETS[@]}"; do
  ensure_secret_exists "${ref%%:*}" "${ref##*:}"
done

wait_for_kustomization_ready observability
wait_for_kustomization_ready apps

echo
echo "[OK] Observability and apps reconciled successfully"

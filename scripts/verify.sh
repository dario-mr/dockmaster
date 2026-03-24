#!/usr/bin/env bash
set -euo pipefail

FAILURES=0
WARNINGS=0
SUDO=""

if [[ "${EUID}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

print_header() {
  echo
  echo "=== $1 ==="
}

pass() {
  echo "[OK] $1"
}

warn() {
  echo "[WARN] $1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo "[ERROR] $1"
  FAILURES=$((FAILURES + 1))
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Required command '$cmd' is not installed"
    return 1
  fi
}

print_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    ${SUDO} cat "$path"
  else
    warn "File not found: $path"
  fi
}

check_systemd_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    pass "$unit is active"
  else
    fail "$unit is not active"
  fi
}

check_node_ready() {
  local not_ready
  not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" { print $1 }')"
  if [[ -z "$not_ready" ]]; then
    pass "All Kubernetes nodes are Ready"
  else
    fail "Nodes not Ready: ${not_ready//$'\n'/, }"
  fi
}

check_non_running_pods() {
  local bad_pods
  bad_pods="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 !~ /^(Running|Completed)$/ { print $1 "/" $2 " (" $4 ")" }')"
  if [[ -z "$bad_pods" ]]; then
    pass "All pods are Running or Completed"
  else
    fail "Pods not healthy:"
    echo "$bad_pods"
  fi
}

check_flux_ready() {
  local bad_kustomizations bad_helmreleases

  bad_kustomizations="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers 2>/dev/null | awk '$4 != "True" { print $1 "/" $2 " (" $4 ")" }')"
  bad_helmreleases="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | awk '$4 != "True" { print $1 "/" $2 " (" $4 ")" }')"

  if [[ -z "$bad_kustomizations" ]]; then
    pass "All Flux kustomizations are Ready"
  else
    fail "Flux kustomizations not ready:"
    echo "$bad_kustomizations"
  fi

  if [[ -z "$bad_helmreleases" ]]; then
    pass "All Flux HelmReleases are Ready"
  else
    fail "Flux HelmReleases not ready:"
    echo "$bad_helmreleases"
  fi
}

check_disk_usage() {
  local root_use
  root_use="$(df --output=pcent / | tail -n 1 | tr -dc '0-9')"
  if [[ -n "$root_use" ]] && (( root_use >= 90 )); then
    fail "Root filesystem usage is ${root_use}%"
  elif [[ -n "$root_use" ]] && (( root_use >= 80 )); then
    warn "Root filesystem usage is ${root_use}%"
  else
    pass "Root filesystem usage is ${root_use}%"
  fi
}

check_journald_limits() {
  local journald_conf="/etc/systemd/journald.conf.d/dockmaster.conf"
  if [[ -f "$journald_conf" ]] &&
     ${SUDO} grep -Fq 'SystemMaxUse=500M' "$journald_conf" &&
     ${SUDO} grep -Fq 'SystemKeepFree=1G' "$journald_conf" &&
     ${SUDO} grep -Fq 'MaxRetentionSec=14day' "$journald_conf"; then
    pass "Journald retention config is present"
  else
    fail "Journald retention config is missing or incomplete"
  fi
}

check_k3s_log_limits() {
  local k3s_conf="/etc/rancher/k3s/config.yaml"
  if [[ -f "$k3s_conf" ]] &&
     ${SUDO} grep -Fq 'container-log-max-files=3' "$k3s_conf" &&
     ${SUDO} grep -Fq 'container-log-max-size=10Mi' "$k3s_conf"; then
    pass "k3s container log rotation config is present"
  else
    fail "k3s container log rotation config is missing or incomplete"
  fi
}

require_command kubectl
require_command systemctl
require_command df

if command -v flux >/dev/null 2>&1; then
  HAVE_FLUX=1
else
  HAVE_FLUX=0
  warn "flux CLI is not installed; skipping 'flux check'"
fi

print_header "System"
hostnamectl || true
uptime || true
free -h || true
df -h || true
df -i || true
lsblk || true

check_systemd_active k3s
check_disk_usage

print_header "Retention"
check_journald_limits
check_k3s_log_limits
${SUDO} journalctl --disk-usage || warn "Could not read journald disk usage"
echo
echo "--- /etc/systemd/journald.conf.d/dockmaster.conf ---"
print_if_exists /etc/systemd/journald.conf.d/dockmaster.conf
echo
echo "--- /etc/rancher/k3s/config.yaml ---"
print_if_exists /etc/rancher/k3s/config.yaml
echo
echo "--- Space Hotspots ---"
${SUDO} du -sh /var/log/traefik /var/lib/rancher/k3s /var/log 2>/dev/null || true

print_header "Network"
${SUDO} ufw status verbose || warn "Could not read ufw status"
ss -lntp | egrep ':80 |:443 |:6443 ' || true

print_header "Kubernetes"
kubectl get nodes -o wide || fail "Failed to query Kubernetes nodes"
kubectl top nodes 2>/dev/null || warn "Metrics server not ready or kubectl top unavailable"
kubectl get pvc -A || true
kubectl get ingressroute -A 2>/dev/null || warn "IngressRoute CRD not available"
check_node_ready
check_non_running_pods

print_header "Flux"
if (( HAVE_FLUX == 1 )); then
  flux check || fail "flux check failed"
  flux get all -A || fail "Failed to read Flux objects"
else
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A || warn "Flux kustomizations unavailable"
  kubectl get helmreleases.helm.toolkit.fluxcd.io -A || warn "Flux HelmReleases unavailable"
fi
check_flux_ready

print_header "Recent Events"
kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true

echo
if (( FAILURES > 0 )); then
  echo "[ERROR] Verification finished with ${FAILURES} failure(s) and ${WARNINGS} warning(s)"
  exit 1
fi

if (( WARNINGS > 0 )); then
  echo "[WARN] Verification finished with ${WARNINGS} warning(s)"
else
  echo "[OK] Verification finished with no issues detected"
fi

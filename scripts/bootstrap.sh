#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

echo "=== Dockmaster Bootstrap ==="

REQUIRED_APT_PACKAGES=(curl git open-iscsi ufw)

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

wait_for_kustomization_ready() {
  local name="$1"
  log_step "Waiting for Flux kustomization '$name'..."
  flux reconcile kustomization "$name" -n flux-system --with-source
  kubectl wait kustomization/"$name" -n flux-system --for=condition=Ready=True --timeout=10m
  log_ok "Flux kustomization '$name' is ready"
}

ensure_secret_exists() {
  local namespace="$1"
  local secret_name="$2"

  if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    log_ok "Required secret '$namespace/$secret_name' exists"
  else
    echo "[ERROR] Required secret '$namespace/$secret_name' is missing."
    echo "  Apply secrets first with: sudo bash scripts/apply-secrets.sh"
    echo "  Then continue with: sudo bash scripts/reconcile-apps.sh"
    exit 1
  fi
}

install_apt_packages_if_missing "${REQUIRED_APT_PACKAGES[@]}"
require_command awk
require_command grep
require_command sed
require_command systemctl
require_command curl
require_command git

# Longhorn requires the host iSCSI daemon on every node.
systemctl enable --now iscsid >/dev/null 2>&1 || true
log_ok "iscsid service enabled"

# Configure journald retention
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/dockmaster.conf <<'CONF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=14day
CONF
systemctl restart systemd-journald
echo "[OK] journald retention configured"

# Raise inotify limits to avoid watcher exhaustion in Crowdsec and storage sidecars.
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-dockmaster-inotify.conf <<'CONF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 262144
fs.inotify.max_queued_events = 32768
CONF
sysctl --system >/dev/null
echo "[OK] inotify sysctl limits configured"

# Install and configure UFW
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

# Configure k3s (kubelet container log rotation)
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'CONF'
kubelet-arg:
  - "container-log-max-files=3"
  - "container-log-max-size=10Mi"
CONF
echo "[OK] k3s config written"

# Install k3s
if command -v k3s &>/dev/null; then
  echo "[OK] k3s already installed"
else
  echo "[..] Installing k3s..."
  curl -sfL https://get.k3s.io | sh -
  echo "[OK] k3s installed"
fi

# Make kubeconfig available for the current shell and the invoking user.
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

TARGET_USER="${SUDO_USER:-$(id -un)}"
setup_user_kubeconfig "$TARGET_USER"

# Wait for node to be ready
log_step "Waiting for node to be ready..."
until kubectl get nodes &>/dev/null; do
  sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=120s
log_ok "Node ready"

# Wait for Traefik to be running
log_step "Waiting for Traefik..."
kubectl wait --for=condition=Available deployment/traefik -n kube-system --timeout=180s
log_ok "Traefik running"

# Prepare Traefik access log directory (Traefik runs as UID 65532)
mkdir -p /var/log/traefik
chown 65532:65532 /var/log/traefik
echo "[OK] Traefik access log directory ready"

# Create apps namespace (so secrets can be applied before Flux runs)
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
echo "[OK] Namespaces 'apps' and 'observability' ensured"

# Install Flux CLI
if command -v flux &>/dev/null; then
  log_ok "Flux CLI already installed"
else
  log_step "Installing Flux CLI..."
  curl -s https://fluxcd.io/install.sh | bash
  log_ok "Flux CLI installed"
fi

# Check GITHUB_TOKEN
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[ERROR] GITHUB_TOKEN environment variable is not set."
  echo "  Export it before running this script:"
  echo "  export GITHUB_TOKEN=ghp_your_token_here"
  exit 1
fi

# Bootstrap Flux
log_step "Bootstrapping Flux..."
flux bootstrap github \
  --owner=dario-mr \
  --repository=dockmaster \
  --branch=main \
  --path=clusters/production \
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

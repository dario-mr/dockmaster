#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

echo "=== Dockmaster Bootstrap ==="

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

# Install and configure UFW
if command -v ufw &>/dev/null; then
  echo "[OK] ufw already installed"
else
  echo "[..] Installing ufw..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ufw
  echo "[OK] ufw installed"
fi

for rule in OpenSSH 80/tcp 443/tcp; do
  if ufw status | grep -Fq "$rule"; then
    echo "[OK] ufw rule already present for $rule"
  else
    echo "[..] Allowing $rule through ufw..."
    ufw allow "$rule"
  fi
done

if ufw status | grep -Fq "Status: active"; then
  echo "[OK] ufw already enabled"
else
  echo "[..] Enabling ufw..."
  ufw --force enable
  echo "[OK] ufw enabled"
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
echo "[..] Waiting for node to be ready..."
until kubectl get nodes &>/dev/null; do
  sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=120s
echo "[OK] Node ready"

# Wait for Traefik to be running
echo "[..] Waiting for Traefik..."
kubectl wait --for=condition=Available deployment/traefik -n kube-system --timeout=180s
echo "[OK] Traefik running"

# Prepare Traefik access log directory (Traefik runs as UID 65532)
mkdir -p /var/log/traefik
chown 65532:65532 /var/log/traefik
echo "[OK] Traefik access log directory ready"

# Create apps namespace (so secrets can be applied before Flux runs)
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
echo "[OK] Namespace 'apps' ensured"

# Install Flux CLI
if command -v flux &>/dev/null; then
  echo "[OK] Flux CLI already installed"
else
  echo "[..] Installing Flux CLI..."
  curl -s https://fluxcd.io/install.sh | bash
  echo "[OK] Flux CLI installed"
fi

# Check GITHUB_TOKEN
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[ERROR] GITHUB_TOKEN environment variable is not set."
  echo "  Export it before running this script:"
  echo "  export GITHUB_TOKEN=ghp_your_token_here"
  exit 1
fi

# Bootstrap Flux
echo "[..] Bootstrapping Flux..."
flux bootstrap github \
  --owner=dario-mr \
  --repository=dockmaster \
  --branch=main \
  --path=clusters/production \
  --personal
kubectl wait --for=condition=Available deployment --all -n flux-system --timeout=180s
flux check --pre=false
echo "[OK] Flux bootstrapped"

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

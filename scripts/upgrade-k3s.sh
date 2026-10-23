#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root
require_command systemctl
require_command k3s
require_command awk
require_command date

if ! systemctl is-active --quiet k3s; then
  echo "[ERROR] k3s must be active before an upgrade."
  exit 1
fi

parse_k3s_version() {
  local version="$1"

  if [[ ! "$version" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)\+k3s([0-9]+)$ ]]; then
    echo "[ERROR] Unsupported k3s version format: $version" >&2
    return 1
  fi

  PARSED_MAJOR="${BASH_REMATCH[1]}"
  PARSED_MINOR="${BASH_REMATCH[2]}"
  PARSED_PATCH="${BASH_REMATCH[3]}"
  PARSED_REVISION="${BASH_REMATCH[4]}"
}

installed_version="$(k3s --version | awk 'NR == 1 { print $3 }')"
target_version="$DOCKMASTER_K3S_VERSION"
parse_k3s_version "$installed_version"
current_major=$((10#${PARSED_MAJOR}))
current_minor=$((10#${PARSED_MINOR}))
current_patch=$((10#${PARSED_PATCH}))
current_revision=$((10#${PARSED_REVISION}))
parse_k3s_version "$target_version"
target_major=$((10#${PARSED_MAJOR}))
target_minor=$((10#${PARSED_MINOR}))
target_patch=$((10#${PARSED_PATCH}))
target_revision=$((10#${PARSED_REVISION}))

if [[ "$installed_version" == "$target_version" ]]; then
  log_ok "k3s is already at the tracked version ${target_version}"
  exit 0
fi

if (( target_major != current_major )); then
  echo "[ERROR] Refusing a Kubernetes major-version change (${installed_version} -> ${target_version})."
  exit 1
elif (( target_minor == current_minor )); then
  if (( target_patch < current_patch || (target_patch == current_patch && target_revision < current_revision) )); then
    echo "[ERROR] Refusing a k3s downgrade (${installed_version} -> ${target_version})."
    exit 1
  fi
elif (( target_minor != current_minor + 1 )); then
  echo "[ERROR] Upgrade one Kubernetes minor version at a time (${installed_version} -> ${target_version})."
  exit 1
fi

service_exec_start="$(systemctl show k3s --property=ExecStart --value)"
# shortcut: supports this host's plain server unit; extend if tracked service options change.
case "$service_exec_start" in
  '{ path=/usr/local/bin/k3s ; argv[]=/usr/local/bin/k3s server ; '*)
    ;;
  *)
    echo "[ERROR] The current k3s service has extra or different options; refusing to replace its unit."
    exit 1
    ;;
esac

if [[ -n "$(systemctl show k3s --property=Environment --value)" ]] ||
   [[ -n "$(systemctl show k3s --property=DropInPaths --value)" ]]; then
  echo "[ERROR] The k3s service has custom environment or drop-ins; inspect and preserve them before upgrading."
  exit 1
fi

for env_file in /etc/default/k3s /etc/sysconfig/k3s /etc/systemd/system/k3s.service.env; do
  if [[ -s "$env_file" ]]; then
    echo "[ERROR] $env_file contains custom settings; inspect and preserve them before upgrading."
    exit 1
  fi
done

if [[ ! -r /etc/rancher/k3s/config.yaml ]]; then
  echo "[ERROR] Expected k3s configuration /etc/rancher/k3s/config.yaml is missing or unreadable."
  exit 1
fi

k3s kubectl wait --for=condition=Ready nodes --all --timeout=5m

snapshot_name="dockmaster-pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
log_step "Saving embedded-etcd snapshot ${snapshot_name}..."
k3s etcd-snapshot save --name "$snapshot_name"

log_step "Installing pinned k3s ${target_version}..."
run_verified_k3s_installer server

installed_version="$(k3s --version | awk 'NR == 1 { print $3 }')"
if [[ "$installed_version" != "$target_version" ]]; then
  echo "[ERROR] Expected ${target_version} after upgrade, found ${installed_version}."
  exit 1
fi

systemctl is-active --quiet k3s
k3s kubectl wait --for=condition=Ready nodes --all --timeout=5m
log_ok "k3s upgraded to ${target_version}; all nodes are Ready"

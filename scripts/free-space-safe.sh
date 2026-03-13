#!/usr/bin/env bash
set -euo pipefail

JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE:-500M}"

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi

  echo "[ERROR] Run this script as root or install sudo."
  exit 1
fi

print_header() {
  echo
  echo "=== $1 ==="
}

print_disk_report() {
  df -h /

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --disk-usage || true
  fi

  du -sh /var/log /var/lib/rancher/k3s/agent /var/lib/rancher/k3s/storage 2>/dev/null || true
}

print_header "Disk Before"
print_disk_report

if command -v journalctl >/dev/null 2>&1; then
  print_header "Vacuum Journald"
  journalctl --vacuum-size="${JOURNAL_MAX_SIZE}"
fi

if command -v k3s >/dev/null 2>&1; then
  print_header "Prune Unused K3s Images"
  k3s crictl rmi --prune || true
fi

if command -v apt-get >/dev/null 2>&1; then
  print_header "Clean Apt Cache"
  apt-get clean
  apt-get autoclean -y || true
fi

print_header "Disk After"
print_disk_report

echo
echo "[OK] Safe cleanup finished"

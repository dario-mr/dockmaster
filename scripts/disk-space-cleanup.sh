#!/usr/bin/env bash
set -euo pipefail

JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE:-500M}"
MODE="dry-run"

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [--dry-run|--cleanup]"
  exit 2
fi

case "${1:-}" in
  ""|--dry-run)
    ;;
  --cleanup)
    MODE="cleanup"
    ;;
  -h|--help)
    echo "Usage: $0 [--dry-run|--cleanup]"
    echo "  --dry-run  Report and print cleanup commands without running them (default)."
    echo "  --cleanup  Run the cleanup commands as root."
    exit 0
    ;;
  *)
    echo "Usage: $0 [--dry-run|--cleanup]"
    exit 2
    ;;
esac

if [[ "${MODE}" == "cleanup" && "${EUID}" -ne 0 ]]; then
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

run_cleanup() {
  if [[ "${MODE}" == "dry-run" ]]; then
    printf "[DRY RUN] Would run:"
    printf " %q" "$@"
    printf "\n"
    return 0
  fi

  "$@"
}

print_header "Disk Before"
print_disk_report

if command -v journalctl >/dev/null 2>&1; then
  print_header "Vacuum Journald"
  run_cleanup journalctl --vacuum-size="${JOURNAL_MAX_SIZE}"
fi

if command -v k3s >/dev/null 2>&1; then
  print_header "Prune Unused K3s Images"
  run_cleanup k3s crictl rmi --prune || true
fi

if command -v apt-get >/dev/null 2>&1; then
  print_header "Clean Apt Cache"
  run_cleanup apt-get clean
  run_cleanup apt-get autoclean -y || true
fi

echo
if [[ "${MODE}" == "cleanup" ]]; then
  print_header "Disk After"
  print_disk_report
  echo "[OK] Safe cleanup finished"
else
  echo "[OK] Dry run finished; no cleanup performed"
fi

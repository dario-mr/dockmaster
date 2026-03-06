#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../secrets"

echo "=== Applying Secrets ==="

for file in "$SECRETS_DIR"/*.yaml; do
  # Skip templates
  if [[ "$file" == *.template.yaml ]]; then
    continue
  fi

  if [ -f "$file" ]; then
    echo "[..] Applying $(basename "$file")..."
    kubectl apply -f "$file"
    echo "[OK] Applied $(basename "$file")"
  fi
done

echo "[OK] All secrets applied"

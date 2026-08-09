#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../secrets"
shopt -s nullglob

echo "=== Applying Secrets ==="

ensure_namespaces_for_file() {
  local file="$1"
  local namespace

  while IFS= read -r namespace; do
    [ -z "$namespace" ] && continue
    if [ "$namespace" = "default" ]; then
      continue
    fi

    echo "[..] Ensuring namespace '$namespace' exists..."
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
  done < <(awk '
    /^metadata:[[:space:]]*$/ { in_metadata=1; next }
    in_metadata && /^[^[:space:]]/ { in_metadata=0 }
    in_metadata && /^[[:space:]]+namespace:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]+namespace:[[:space:]]*/, "", value)
      gsub(/"/, "", value)
      print value
    }
  ' "$file" | sort -u)
}

templates=("$SECRETS_DIR"/*.template.yaml)
missing=0

for template in "${templates[@]}"; do
  file="${template%.template.yaml}.yaml"
  if [ ! -f "$file" ]; then
    echo "[ERROR] Missing required secret file: $(basename "$file")"
    echo "        Create it from $(basename "$template") before continuing."
    missing=1
  fi
done

if ((missing)); then
  exit 1
fi

for file in "$SECRETS_DIR"/*.yaml; do
  if [[ "$file" == *.template.yaml ]]; then
    continue
  fi

  if [ -f "$file" ]; then
    echo "[..] Applying $(basename "$file")..."
    ensure_namespaces_for_file "$file"
    kubectl apply -f "$file"
  fi
done

echo "[OK] All secrets applied"

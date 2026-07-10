#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/check-outdated-apps.sh

Lists outdated Helm-managed components outside /apps by comparing the pinned
chart version in git with the latest version currently available upstream.

Requirements:
  - helm
  - awk
  - sort
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$cmd' is not installed" >&2
    exit 1
  fi
}

version_gt() {
  local left="$1"
  local right="$2"
  [[ "$left" != "$right" ]] && [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n 1)" == "$left" ]]
}

extract_helm_repositories() {
  awk '
    function emit() {
      if (name != "" && namespace != "" && url != "") {
        print namespace "|" name "|" url
      }
      name = ""
      namespace = ""
      url = ""
      block = ""
    }

    FNR == 1 {
      if (NR > 1) {
        emit()
      }
    }

    /^---$/ {
      emit()
      next
    }

    /^metadata:$/ {
      block = "metadata"
      next
    }

    /^spec:$/ {
      block = "spec"
      next
    }

    block == "metadata" && /^  name:/ {
      name = $2
      next
    }

    block == "metadata" && /^  namespace:/ {
      namespace = $2
      next
    }

    block == "spec" && /^  url:/ {
      url = $2
      next
    }

    END {
      emit()
    }
  ' "$@"
}

extract_helm_releases() {
  awk '
    function emit() {
      if (release_name != "" && release_namespace != "" && chart_name != "" &&
          chart_version != "" && source_name != "" && source_namespace != "") {
        print current_file "|" release_namespace "|" release_name "|" chart_name "|" chart_version "|" source_name "|" source_namespace
      }
      release_name = ""
      release_namespace = ""
      chart_name = ""
      chart_version = ""
      source_name = ""
      source_namespace = ""
      block = ""
    }

    FNR == 1 {
      if (NR > 1) {
        emit()
      }
      current_file = FILENAME
    }

    /^metadata:$/ {
      block = "metadata"
      next
    }

    /^spec:$/ {
      if (block != "chart") {
        block = "spec_root"
      }
      next
    }

    block == "spec_root" && /^  chart:$/ {
      block = "chart"
      next
    }

    block == "chart" && /^    spec:$/ {
      block = "chart_spec"
      next
    }

    block == "chart_spec" && /^      sourceRef:$/ {
      block = "source_ref"
      next
    }

    block == "metadata" && /^  name:/ {
      release_name = $2
      next
    }

    block == "metadata" && /^  namespace:/ {
      release_namespace = $2
      next
    }

    block == "chart_spec" && /^      chart:/ {
      chart_name = $2
      next
    }

    block == "chart_spec" && /^      version:/ {
      chart_version = $2
      gsub(/"/, "", chart_version)
      next
    }

    block == "source_ref" && /^        name:/ {
      source_name = $2
      next
    }

    block == "source_ref" && /^        namespace:/ {
      source_namespace = $2
      block = ""
      next
    }

    END {
      emit()
    }
  ' "$@"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command helm
require_command awk
require_command sort

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

helm_repository_files=()
while IFS= read -r file; do
  helm_repository_files+=("${file}")
done < <(
  {
    find "${REPO_ROOT}/infrastructure" "${REPO_ROOT}/observability" -name 'helmrepository.yaml'
    echo "${REPO_ROOT}/observability/sources/helm-repositories.yaml"
  } | sort -u
)

helm_release_files=()
while IFS= read -r file; do
  helm_release_files+=("${file}")
done < <(
  find "${REPO_ROOT}/infrastructure" "${REPO_ROOT}/observability" -name 'helmrelease.yaml' | sort
)

if ((${#helm_repository_files[@]} == 0)); then
  echo "[ERROR] No HelmRepository manifests found" >&2
  exit 1
fi

if ((${#helm_release_files[@]} == 0)); then
  echo "[ERROR] No HelmRelease manifests found" >&2
  exit 1
fi

repo_entries_file="${TMP_DIR}/repos.tsv"
extract_helm_repositories "${helm_repository_files[@]}" | sort -u > "${repo_entries_file}"

if [[ ! -s "${repo_entries_file}" ]]; then
  echo "[ERROR] Failed to parse any HelmRepository entries" >&2
  exit 1
fi

repo_url_for_key() {
  local repo_key="$1"
  awk -F'|' -v repo_key="${repo_key}" '$1 "/" $2 == repo_key { print $3; exit }' "${repo_entries_file}"
}

repo_alias_for_key() {
  local repo_key="$1"
  echo "${repo_key//\//-}"
}

while IFS= read -r repo_key; do
  alias_name="${repo_key//\//-}"
  repo_url="$(repo_url_for_key "${repo_key}")"
  helm repo add "${alias_name}" "${repo_url}" --force-update >/dev/null
done < <(awk -F'|' '{ print $1 "/" $2 }' "${repo_entries_file}")

helm repo update >/dev/null

outdated_count=0
error_count=0

printf "%-24s %-24s %-28s %-12s %-12s\n" "NAMESPACE" "RELEASE" "CHART" "CURRENT" "LATEST"
printf "%-24s %-24s %-28s %-12s %-12s\n" "---------" "-------" "-----" "-------" "------"

while IFS='|' read -r file release_namespace release_name chart_name chart_version source_name source_namespace; do
  repo_key="${source_namespace}/${source_name}"
  repo_url="$(repo_url_for_key "${repo_key}")"
  repo_alias="$(repo_alias_for_key "${repo_key}")"

  if [[ -z "${repo_url}" || -z "${repo_alias}" ]]; then
    echo "[WARN] Skipping ${file}: could not resolve HelmRepository ${repo_key}" >&2
    error_count=$((error_count + 1))
    continue
  fi

  latest_version="$(
    helm search repo "${repo_alias}/${chart_name}" --versions 2>/dev/null |
      awk 'NR == 2 { print $2 }'
  )"

  if [[ -z "${latest_version}" ]]; then
    echo "[WARN] Skipping ${file}: could not find chart ${repo_alias}/${chart_name}" >&2
    error_count=$((error_count + 1))
    continue
  fi

  if version_gt "${latest_version}" "${chart_version}"; then
    printf "%-24s %-24s %-28s %-12s %-12s\n" \
      "${release_namespace}" "${release_name}" "${chart_name}" "${chart_version}" "${latest_version}"
    outdated_count=$((outdated_count + 1))
  fi
done < <(extract_helm_releases "${helm_release_files[@]}")

if ((outdated_count == 0)); then
  echo
  echo "[OK] All non-/apps HelmReleases are up to date"
fi

if ((error_count > 0)); then
  echo
  echo "[WARN] ${error_count} item(s) could not be checked" >&2
fi

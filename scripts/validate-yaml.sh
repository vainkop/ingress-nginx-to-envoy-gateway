#!/usr/bin/env bash
# Validate Kubernetes YAML files using kubeconform
# Supports Gateway API CRDs via datreeio/CRDs-catalog
set -euo pipefail

SCHEMA_LOCATION="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
K8S_SCHEMA="default"

if ! command -v kubeconform &>/dev/null; then
  echo "ERROR: kubeconform not found. Install: https://github.com/yannh/kubeconform#installation"
  exit 1
fi

FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "Usage: $0 <file1.yaml> [file2.yaml ...]"
  echo "  Or:  find examples/ -name '*.yaml' | xargs $0"
  exit 1
fi

ERRORS=0
for file in "${FILES[@]}"; do
  if ! kubeconform \
    -schema-location "${K8S_SCHEMA}" \
    -schema-location "${SCHEMA_LOCATION}" \
    -ignore-missing-schemas \
    -summary \
    -output text \
    "${file}"; then
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ ${ERRORS} -gt 0 ]]; then
  echo "FAILED: ${ERRORS} file(s) had validation errors"
  exit 1
fi

echo "All files validated successfully"

#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — cleanup
# Deletes the entire resource group. Irreversible.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

: "${SUBSCRIPTION_ID:?}"
: "${RG_NAME:?}"

echo "=========================================================================="
echo " WARNING: about to delete resource group ${RG_NAME} in ${SUBSCRIPTION_ID}"
echo "=========================================================================="
read -r -p "Type the resource group name to confirm: " confirm
if [[ "${confirm}" != "${RG_NAME}" ]]; then
  echo "Aborted."
  exit 1
fi

az account set --subscription "${SUBSCRIPTION_ID}"
az group delete --name "${RG_NAME}" --yes --no-wait
echo "Delete initiated (running in background). Check with: az group show -n ${RG_NAME}"

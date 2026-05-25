#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — deploys infra/secondary-aks.bicep (replica demo cluster)
# Requires infra/main.bicep (make infra) to have run first (needs Log Analytics ID).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found." >&2; exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${SUBSCRIPTION_ID:?}" "${RG_NAME:?}" "${LOCATION:?}"
: "${SECONDARY_AKS_NAME:?SECONDARY_AKS_NAME not set in .env}"
: "${LOG_ANALYTICS_NAME:?LOG_ANALYTICS_NAME not set in .env}"
: "${SECONDARY_VM_SIZE:=Standard_D4ds_v4}"

az account set --subscription "${SUBSCRIPTION_ID}"

echo "=========================================================================="
echo " Deploying secondary AKS (${SECONDARY_AKS_NAME}) to ${RG_NAME}"
echo "=========================================================================="

LOG_ANALYTICS_ID=$(az monitor log-analytics workspace show \
  -g "${RG_NAME}" -n "${LOG_ANALYTICS_NAME}" --query id -o tsv 2>/dev/null || echo "")

if [[ -z "${LOG_ANALYTICS_ID}" ]]; then
  echo "ERROR: Log Analytics '${LOG_ANALYTICS_NAME}' not found in '${RG_NAME}'." >&2
  echo "       Run 'make infra' first." >&2
  exit 1
fi

echo "[infra-secondary] Deploying secondary-aks.bicep..."
az deployment group create \
  --resource-group "${RG_NAME}" \
  --name "aks-secondary-$(date +%s)" \
  --template-file "${SCRIPT_DIR}/secondary-aks.bicep" \
  --parameters \
      secondaryAksName="${SECONDARY_AKS_NAME}" \
      logAnalyticsId="${LOG_ANALYTICS_ID}" \
      location="${LOCATION}" \
      vmSize="${SECONDARY_VM_SIZE}" \
  --output table

echo "[infra-secondary] Fetching credentials..."
az aks get-credentials \
  --resource-group "${RG_NAME}" \
  --name "${SECONDARY_AKS_NAME}" \
  --overwrite-existing \
  --context "${SECONDARY_AKS_NAME}"

echo "[infra-secondary] Done. Context: ${SECONDARY_AKS_NAME}"

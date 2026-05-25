#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — deploys infra/main.bicep + infra/storage.bicep
# Idempotent. Reads ../.env (relative to repo root).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.example to .env and fill the values." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID not set in .env}"
: "${RG_NAME:?RG_NAME not set in .env}"
: "${LOCATION:?LOCATION not set in .env}"
: "${AKS_NAME:?AKS_NAME not set in .env}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT not set in .env}"
: "${LOG_ANALYTICS_NAME:?LOG_ANALYTICS_NAME not set in .env}"

echo "=========================================================================="
echo " Deploying AKS + Storage to subscription ${SUBSCRIPTION_ID} / RG ${RG_NAME}"
echo "=========================================================================="

az account set --subscription "${SUBSCRIPTION_ID}"

if ! az group show --name "${RG_NAME}" >/dev/null 2>&1; then
  echo "[infra] Creating resource group ${RG_NAME} in ${LOCATION}..."
  az group create --name "${RG_NAME}" --location "${LOCATION}" --tags client=demo workload=postgresql-ha-cnpg env=demo >/dev/null
else
  echo "[infra] Resource group ${RG_NAME} already exists."
fi

echo "[infra] Deploying main.bicep (AKS multi-zone + Log Analytics)..."
# SYSTEM_POOL_VM_SIZE and USER_POOL_VM_SIZE from .env override Bicep defaults
EXTRA_PARAMS=""
[[ -n "${SYSTEM_POOL_VM_SIZE:-}" ]] && EXTRA_PARAMS="${EXTRA_PARAMS} systemPoolVmSize=${SYSTEM_POOL_VM_SIZE}"
[[ -n "${USER_POOL_VM_SIZE:-}" ]]   && EXTRA_PARAMS="${EXTRA_PARAMS} userPoolVmSize=${USER_POOL_VM_SIZE}"

# shellcheck disable=SC2086
az deployment group create \
  --resource-group "${RG_NAME}" \
  --name "aks-pgha-$(date +%s)" \
  --template-file "${SCRIPT_DIR}/main.bicep" \
  --parameters \
      aksName="${AKS_NAME}" \
      logAnalyticsName="${LOG_ANALYTICS_NAME}" \
      location="${LOCATION}" \
      ${EXTRA_PARAMS} \
  --output table

echo "[infra] Deploying storage.bicep (Storage Account + backup container)..."
az deployment group create \
  --resource-group "${RG_NAME}" \
  --name "stg-pgha-$(date +%s)" \
  --template-file "${SCRIPT_DIR}/storage.bicep" \
  --parameters \
      storageAccountName="${STORAGE_ACCOUNT}" \
      backupContainerName="${BACKUP_CONTAINER:-pg-backups}" \
      location="${LOCATION}" \
  --output table

echo "[infra] Fetching AKS credentials..."
az aks get-credentials \
  --resource-group "${RG_NAME}" \
  --name "${AKS_NAME}" \
  --overwrite-existing

echo "[infra] Done. Next: make cnpg && make cluster"

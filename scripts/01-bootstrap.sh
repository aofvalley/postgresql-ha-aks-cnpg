#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — bootstrap script
# Modes:
#   bash scripts/01-bootstrap.sh all       # everything (cnpg + cluster)
#   bash scripts/01-bootstrap.sh cnpg      # only operator + plugins
#   bash scripts/01-bootstrap.sh cluster   # only Cluster + Pooler + backup + app
#
# Reads ../.env. Idempotent: re-running will helm upgrade and kubectl apply.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
MANIFEST_DIR="${REPO_ROOT}/manifests"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${RG_NAME:?}"
: "${AKS_NAME:?}"
: "${STORAGE_ACCOUNT:?}"
: "${BACKUP_CONTAINER:=pg-backups}"
: "${CNPG_NAMESPACE:=cnpg-system}"
: "${PG_NAMESPACE:=pg-demo}"
: "${CNPG_HELM_VERSION:=0.22.1}"
: "${PG_CLUSTER_NAME:=pg-demo}"

MODE="${1:-all}"

# ----------------------------------------------------------------------------
install_cnpg() {
  echo "=========================================================================="
  echo " Installing CNPG operator + dependencies"
  echo "=========================================================================="

  # cert-manager is optional — CNPG 1.28 self-manages TLS.
  # Skipped: AKS Policy addon (admissionsenforcer) conflicts with cert-manager webhook.
  echo "[cnpg] Skipping cert-manager (CNPG 1.28 self-manages TLS; avoids Policy addon conflict)."

  echo "[cnpg] Installing CloudNativePG operator (chart ${CNPG_HELM_VERSION})..."
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
  helm repo update cnpg >/dev/null
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace "${CNPG_NAMESPACE}" --create-namespace \
    --version "${CNPG_HELM_VERSION}" \
    --set monitoring.podMonitorEnabled=false \
    --set "tolerations[0].key=CriticalAddonsOnly" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[0].effect=NoSchedule" \
    --wait

  echo "[cnpg] Installing Barman Cloud Plugin (recommended for CNPG 1.28+)..."
  kubectl apply --server-side -f \
    https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.5.0/manifest.yaml || \
    echo "[cnpg] WARN: plugin-barman-cloud apply failed (cluster will still work via deprecated barmanObjectStore)."

  if ! kubectl plugin list 2>/dev/null | grep -q "kubectl-cnpg"; then
    echo "[cnpg] Installing kubectl-cnpg plugin via krew..."
    kubectl krew install cnpg || echo "[cnpg] WARN: krew install failed; install manually."
  fi

  echo "[cnpg] Operator install complete."
}

# ----------------------------------------------------------------------------
configure_workload_identity() {
  echo "[cluster] Configuring Workload Identity federation..."

  local oidc_issuer mi_name fed_name
  oidc_issuer=$(az aks show -g "${RG_NAME}" -n "${AKS_NAME}" --query "oidcIssuerProfile.issuerUrl" -o tsv)
  mi_name="mi-${STORAGE_ACCOUNT}-backup"

  # Capture identity client + object IDs (client ID injected into SA annotation)
  BACKUP_IDENTITY_CLIENT_ID=$(az identity show -g "${RG_NAME}" -n "${mi_name}" --query clientId -o tsv)
  export BACKUP_IDENTITY_CLIENT_ID STORAGE_ACCOUNT BACKUP_CONTAINER

  fed_name="fic-${PG_CLUSTER_NAME}-${PG_NAMESPACE}"
  if ! az identity federated-credential show \
      -g "${RG_NAME}" --identity-name "${mi_name}" --name "${fed_name}" >/dev/null 2>&1; then
    echo "[cluster] Creating FederatedIdentityCredential ${fed_name}..."
    az identity federated-credential create \
      --name "${fed_name}" \
      --identity-name "${mi_name}" \
      --resource-group "${RG_NAME}" \
      --issuer "${oidc_issuer}" \
      --subject "system:serviceaccount:${PG_NAMESPACE}:${PG_CLUSTER_NAME}" \
      --audiences api://AzureADTokenExchange >/dev/null
  else
    echo "[cluster] FederatedIdentityCredential ${fed_name} already exists."
  fi
}

# ----------------------------------------------------------------------------
apply_cluster() {
  echo "=========================================================================="
  echo " Applying namespaces, storage class, cluster, pooler, backup, monitoring"
  echo "=========================================================================="

  kubectl apply -f "${MANIFEST_DIR}/00-namespace.yaml"
  kubectl apply -f "${MANIFEST_DIR}/02-storage-class.yaml"

  configure_workload_identity

  # Render templated cluster manifest
  echo "[cluster] Rendering 04-pg-cluster.yaml with envsubst..."
  if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not installed (gettext package)." >&2
    exit 1
  fi
  envsubst < "${MANIFEST_DIR}/04-pg-cluster.yaml" | kubectl apply -f -

  kubectl apply -f "${MANIFEST_DIR}/05-pgbouncer-pooler.yaml"
  kubectl apply -f "${MANIFEST_DIR}/06-backup-schedule.yaml"

  echo "[cluster] Applying PodMonitor (skip-on-error if Prometheus CRDs missing)..."
  kubectl apply -f "${MANIFEST_DIR}/07-monitoring-podmonitor.yaml" || \
    echo "[cluster] WARN: PodMonitor not applied (Prometheus Operator CRDs missing)."

  echo "[cluster] Waiting for Cluster pg-demo to be ready (this can take 5-8 minutes)..."
  kubectl -n "${PG_NAMESPACE}" wait --for=condition=Ready cluster/pg-demo --timeout=15m || true

  kubectl apply -f "${MANIFEST_DIR}/08-sample-app.yaml"

  echo "=========================================================================="
  echo " Cluster ready. Verify with: kubectl cnpg status pg-demo -n ${PG_NAMESPACE}"
  echo "=========================================================================="
}

# ----------------------------------------------------------------------------
case "${MODE}" in
  cnpg)    install_cnpg ;;
  cluster) apply_cluster ;;
  all)     install_cnpg; apply_cluster ;;
  *) echo "Usage: $0 {all|cnpg|cluster}"; exit 1 ;;
esac

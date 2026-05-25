#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — Backup + Restore demo
#
# Steps:
#   1. Trigger an on-demand Backup CR
#   2. Wait until Status: completed
#   3. List blob container contents to verify upload
#   4. Create a new Cluster `pg-demo-pitr` from the same backup
#   5. Wait for restore cluster Ready and run a sanity SELECT
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

: "${PG_NAMESPACE:=pg-demo}"
: "${PG_CLUSTER_NAME:=pg-demo}"
: "${RG_NAME:?}"
: "${STORAGE_ACCOUNT:?}"
: "${BACKUP_CONTAINER:=pg-backups}"
: "${BACKUP_IDENTITY_CLIENT_ID:?}"

BACKUP_NAME="ondemand-$(date -u +%Y%m%d-%H%M%S)"
RESTORE_CLUSTER="${PG_CLUSTER_NAME}-pitr"

echo "=========================================================================="
echo " CNPG backup + restore demo"
echo "=========================================================================="

echo "[step 1] Creating on-demand Backup ${BACKUP_NAME}..."
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${PG_NAMESPACE}
spec:
  cluster:
    name: ${PG_CLUSTER_NAME}
  method: barmanObjectStore
EOF

echo "[step 2] Waiting for backup to complete..."
for i in {1..60}; do
  phase=$(kubectl get backup "${BACKUP_NAME}" -n "${PG_NAMESPACE}" -o jsonpath='{.status.phase}' || true)
  echo "  [${i}/60] phase=${phase:-pending}"
  [[ "${phase}" == "completed" ]] && break
  [[ "${phase}" == "failed" ]] && { echo "ERROR: backup failed"; kubectl describe backup "${BACKUP_NAME}" -n "${PG_NAMESPACE}"; exit 1; }
  sleep 10
done

echo "[step 3] Verifying blob container contents..."
STORAGE_KEY=$(az storage account keys list -g "${RG_NAME}" -n "${STORAGE_ACCOUNT}" \
  --query '[0].value' -o tsv)
az storage blob list \
  --account-name "${STORAGE_ACCOUNT}" \
  --container-name "${BACKUP_CONTAINER}" \
  --account-key "${STORAGE_KEY}" \
  --query "[?contains(name, '${PG_CLUSTER_NAME}')].{name:name,size:properties.contentLength,modified:properties.lastModified}" \
  --output table | head -20

echo "[step 4] Creating restore cluster ${RESTORE_CLUSTER}..."
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${RESTORE_CLUSTER}
  namespace: ${PG_NAMESPACE}
spec:
  description: "Restored from backup ${BACKUP_NAME}"
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  instances: 1
  storage:
    size: 100Gi
    storageClass: managed-csi-premium-v2-zrs
  walStorage:
    size: 32Gi
    storageClass: managed-csi-premium-v2-zrs
  bootstrap:
    recovery:
      source: ${PG_CLUSTER_NAME}-source
  externalClusters:
    - name: ${PG_CLUSTER_NAME}-source
      barmanObjectStore:
        destinationPath: "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${BACKUP_CONTAINER}"
        azureCredentials:
          inheritFromAzureAD: true
        serverName: ${PG_CLUSTER_NAME}
        wal:
          maxParallel: 8
  inheritedMetadata:
    labels:
      azure.workload.identity/use: "true"
  serviceAccountTemplate:
    metadata:
      annotations:
        azure.workload.identity/client-id: ${BACKUP_IDENTITY_CLIENT_ID}
      labels:
        azure.workload.identity/use: "true"
  affinity:
    nodeSelector:
      workload: postgresql
    tolerations:
      - key: workload
        operator: Equal
        value: postgresql
        effect: NoSchedule
EOF

echo "[step 5] Waiting for restore cluster to be Ready..."
kubectl -n "${PG_NAMESPACE}" wait --for=condition=Ready cluster/"${RESTORE_CLUSTER}" --timeout=15m || true

echo "[step 6] Running sanity SELECT on the restored cluster..."
RESTORE_POD=$(kubectl -n "${PG_NAMESPACE}" get pods \
  -l "cnpg.io/cluster=${RESTORE_CLUSTER},role=primary" \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "${PG_NAMESPACE}" exec "${RESTORE_POD}" -- \
  psql -U postgres -c "SELECT current_database(), now(), pg_is_in_recovery(), version();"

echo "=========================================================================="
echo " Backup + restore demo complete. Restore cluster: ${RESTORE_CLUSTER}"
echo "=========================================================================="

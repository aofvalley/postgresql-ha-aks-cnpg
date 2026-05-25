#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — Failover demo
#
# Steps:
#   1. Print current primary
#   2. Capture timestamp T0
#   3. Run `kubectl cnpg promote` against a target replica
#   4. Wait for new primary to accept writes
#   5. Capture timestamp T1 -> RTO = T1 - T0
#   6. Print new primary + status
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

: "${PG_NAMESPACE:=pg-demo}"
: "${PG_CLUSTER_NAME:=pg-demo}"

echo "=========================================================================="
echo " CNPG failover demo -- cluster ${PG_CLUSTER_NAME} in ns ${PG_NAMESPACE}"
echo "=========================================================================="

echo "[step 1] Current cluster status:"
kubectl cnpg status "${PG_CLUSTER_NAME}" -n "${PG_NAMESPACE}" || \
  kubectl get cluster "${PG_CLUSTER_NAME}" -n "${PG_NAMESPACE}"

current_primary=$(kubectl get cluster "${PG_CLUSTER_NAME}" -n "${PG_NAMESPACE}" \
  -o jsonpath='{.status.currentPrimary}')
primary_node=$(kubectl get pod "${current_primary}" -n "${PG_NAMESPACE}" -o jsonpath='{.spec.nodeName}')
primary_zone=$(kubectl get node "${primary_node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "?")
echo "[info] Current primary pod: ${current_primary} (zone: ${primary_zone})"

echo "[info] Pod distribution across zones:"
kubectl get pods -n "${PG_NAMESPACE}" -l "cnpg.io/cluster=${PG_CLUSTER_NAME}" \
  -o custom-columns="POD:.metadata.name,NODE:.spec.nodeName" --no-headers | \
  while read -r pod node; do
    zone=$(kubectl get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "?")
    printf "  %-40s zone=%s\n" "${pod}" "${zone}"
  done

target_replica=$(kubectl get pods -n "${PG_NAMESPACE}" \
  -l "cnpg.io/cluster=${PG_CLUSTER_NAME},cnpg.io/instanceRole=replica" \
  -o jsonpath='{.items[0].metadata.name}')
target_node=$(kubectl get pod "${target_replica}" -n "${PG_NAMESPACE}" -o jsonpath='{.spec.nodeName}')
target_zone=$(kubectl get node "${target_node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "?")
echo "[info] Promotion target replica:  ${target_replica} (zone: ${target_zone})"

if [[ -z "${target_replica}" ]]; then
  echo "ERROR: no replica found." >&2
  exit 1
fi

echo "[step 2] Triggering promotion at $(date -u +%H:%M:%S.%3NZ)..."
T0=$(date +%s%3N)
kubectl cnpg promote "${PG_CLUSTER_NAME}" "${target_replica}" -n "${PG_NAMESPACE}"

echo "[step 3] Waiting for ${target_replica} to become primary..."
while true; do
  new_primary=$(kubectl get cluster "${PG_CLUSTER_NAME}" -n "${PG_NAMESPACE}" \
    -o jsonpath='{.status.currentPrimary}')
  if [[ "${new_primary}" == "${target_replica}" ]]; then
    break
  fi
  sleep 0.2
done
T1=$(date +%s%3N)
new_node=$(kubectl get pod "${target_replica}" -n "${PG_NAMESPACE}" -o jsonpath='{.spec.nodeName}')
new_zone=$(kubectl get node "${new_node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "?")
echo "[step 4] New primary confirmed at $(date -u +%H:%M:%S.%3NZ)"
echo "[info]   Zone shift: ${primary_zone} → ${new_zone}"

RTO_MS=$((T1 - T0))
echo "=========================================================================="
echo " RTO (promotion -> new primary writable): ${RTO_MS} ms"
echo " Zone shift: ${primary_zone} → ${new_zone}"
echo "=========================================================================="

echo "[step 5] Final cluster status:"
kubectl cnpg status "${PG_CLUSTER_NAME}" -n "${PG_NAMESPACE}" | head -40

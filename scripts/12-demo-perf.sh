#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — pgbench performance demo
#
# Runs pgbench inside an ephemeral pod to benchmark the rw service.
# Reference numbers (Azure blog "Running high-performance PostgreSQL on AKS"):
#   - Premium SSD v2 (D16ds_v5): ~8,600 TPS @ 7.4 ms p95
#   - Local NVMe ACStor (L16s_v3): ~14,812 TPS @ 4.3 ms p95
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

: "${PG_NAMESPACE:=pg-demo}"
: "${PG_CLUSTER_NAME:=pg-demo}"

SCALE=${PGBENCH_SCALE:-50}
DURATION=${PGBENCH_DURATION:-60}
CLIENTS=${PGBENCH_CLIENTS:-16}
JOBS=${PGBENCH_JOBS:-4}

echo "=========================================================================="
echo " pgbench: scale=${SCALE} clients=${CLIENTS} duration=${DURATION}s"
echo "=========================================================================="

PASSWORD=$(kubectl get secret "${PG_CLUSTER_NAME}-app" -n "${PG_NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 -d)

run_pgbench() {
  kubectl run pgbench-runner --rm -i --restart=Never \
    --image=ghcr.io/cloudnative-pg/postgresql:16 \
    -n "${PG_NAMESPACE}" --env="PGPASSWORD=${PASSWORD}" -- \
    bash -c "$1"
}

echo "[step 1] Initializing pgbench schema (scale ${SCALE})..."
run_pgbench "pgbench -h ${PG_CLUSTER_NAME}-rw -U appuser -d appdb -i -s ${SCALE} -q"

echo "[step 2] Running benchmark (${DURATION}s, ${CLIENTS} clients, ${JOBS} jobs)..."
run_pgbench "pgbench -h ${PG_CLUSTER_NAME}-rw -U appuser -d appdb \
  -c ${CLIENTS} -j ${JOBS} -T ${DURATION} -P 5 \
  --report-latencies"

echo "=========================================================================="
echo " Done. Compare TPS / latency to the Azure blog reference numbers above."
echo "=========================================================================="

#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — Demo: Cross-cluster Replica + Promote (cross-cluster HA)
#
# Usage: bash scripts/13-demo-cross-cluster.sh [setup|demo|restore]
#   setup   — Apply streaming LB, copy secrets, bootstrap replica cluster
#   demo    — Run the live demo (write→replicate→promote→verify)
#   restore — Re-enable replica mode for next rehearsal run
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
MANIFEST_DIR="${REPO_ROOT}/manifests"

# shellcheck disable=SC1090
source "${ENV_FILE}"

PRIMARY_CTX="${AKS_NAME}"
SECONDARY_CTX="${SECONDARY_AKS_NAME}"
PG_NS="${PG_NAMESPACE:-pg-demo}"
PRIMARY_CLUSTER="pg-demo"
REPLICA_CLUSTER="pg-demo-replica"

MODE="${1:-demo}"

# ----------------------------------------------------------------------------
setup_replica_cluster() {
  echo "=========================================================================="
  echo " SETUP: Bootstrap Replica Cluster on secondary AKS"
  echo "=========================================================================="

  echo "[setup] Applying streaming LoadBalancer on primary..."
  kubectl --context "${PRIMARY_CTX}" apply -f "${MANIFEST_DIR}/09-primary-streaming-service.yaml"

  echo "[setup] Waiting for LB IP assignment (up to 3 min)..."
  for i in $(seq 1 36); do
    PRIMARY_LB_IP=$(kubectl --context "${PRIMARY_CTX}" -n "${PG_NS}" \
      get svc pg-demo-streaming-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${PRIMARY_LB_IP}" ]]; then break; fi
    echo "  ... waiting (${i}/36)"; sleep 5
  done

  if [[ -z "${PRIMARY_LB_IP:-}" ]]; then
    echo "ERROR: LB IP not assigned after 3 min." >&2; exit 1
  fi
  echo "[setup] Primary LB IP: ${PRIMARY_LB_IP}"
  export PRIMARY_LB_IP

  echo "[setup] Ensuring namespace exists on secondary..."
  kubectl --context "${SECONDARY_CTX}" create namespace "${PG_NS}" --dry-run=client -o yaml | \
    kubectl --context "${SECONDARY_CTX}" apply -f -

  echo "[setup] Copying replication secrets from primary to secondary..."
  for secret in pg-demo-replication pg-demo-ca; do
    kubectl --context "${PRIMARY_CTX}" -n "${PG_NS}" get secret "${secret}" -o json | \
      jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.annotations,.metadata.ownerReferences)' | \
      kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" apply -f -
  done

  echo "[setup] Applying Replica Cluster CR on secondary..."
  PRIMARY_LB_IP="${PRIMARY_LB_IP}" envsubst < "${MANIFEST_DIR}/10-replica-cluster.yaml" | \
    kubectl --context "${SECONDARY_CTX}" apply -f -

  echo "[setup] Waiting for replica cluster to bootstrap (pg_basebackup, up to 10 min)..."
  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    wait --for=condition=Ready cluster/"${REPLICA_CLUSTER}" --timeout=600s

  echo ""
  echo "[setup] Replica cluster ready!"
  kubectl --context "${SECONDARY_CTX}" cnpg status "${REPLICA_CLUSTER}" -n "${PG_NS}"
}

# ----------------------------------------------------------------------------
run_demo() {
  echo "=========================================================================="
  echo " DEMO: Cross-cluster Replica + Promote"
  echo " Primary  context : ${PRIMARY_CTX}"
  echo " Replica  context : ${SECONDARY_CTX}"
  echo "=========================================================================="

  echo ""
  echo ">>> Step 1: Show streaming replication status"
  kubectl --context "${PRIMARY_CTX}" cnpg status "${PRIMARY_CLUSTER}" -n "${PG_NS}"
  echo ""
  kubectl --context "${SECONDARY_CTX}" cnpg status "${REPLICA_CLUSTER}" -n "${PG_NS}"
  echo ""
  read -rp ">>> Streaming confirmed. Press ENTER to write data to primary..."

  echo ""
  echo ">>> Step 2: Write to primary, verify replication"
  PRIMARY_POD=$(kubectl --context "${PRIMARY_CTX}" -n "${PG_NS}" \
    get pods -l "cnpg.io/cluster=${PRIMARY_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}')

  kubectl --context "${PRIMARY_CTX}" -n "${PG_NS}" exec "${PRIMARY_POD}" -- \
    psql -U postgres -c "
      CREATE TABLE IF NOT EXISTS cross_cluster_demo(id serial PRIMARY KEY, msg text, ts timestamptz DEFAULT now());
      INSERT INTO cross_cluster_demo(msg) VALUES ('replication-test-$(date +%s)');
      SELECT * FROM cross_cluster_demo ORDER BY ts DESC LIMIT 3;"

  echo "[replica] Checking data in secondary (2s lag)..."
  sleep 3
  REPLICA_POD=$(kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    get pods -l "cnpg.io/cluster=${REPLICA_CLUSTER}" -o jsonpath='{.items[0].metadata.name}')

  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" exec "${REPLICA_POD}" -- \
    psql -U postgres -c "SELECT * FROM cross_cluster_demo ORDER BY ts DESC LIMIT 3;"

  echo ""
  read -rp ">>> Data replicated. Press ENTER to promote (simulate primary cluster failure)..."

  echo ""
  echo ">>> Step 3: Promote replica cluster"
  echo "[primary] Pausing primary AKS operator..."
  kubectl --context "${PRIMARY_CTX}" -n cnpg-system scale deploy cnpg-cloudnative-pg --replicas=0
  sleep 5

  START_TS=$(date +%s)
  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    patch cluster "${REPLICA_CLUSTER}" --type=merge -p '{"spec":{"replica":{"enabled":false}}}'

  echo "[replica] Waiting for promotion..."
  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    wait --for=condition=Ready cluster/"${REPLICA_CLUSTER}" --timeout=120s
  END_TS=$(date +%s)

  echo ""
  echo ">>> PROMOTE RTO: $((END_TS - START_TS)) seconds"

  echo ""
  echo ">>> Step 4: Verify promoted cluster accepts writes"
  PROMOTED_POD=$(kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    get pods -l "cnpg.io/cluster=${REPLICA_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}')

  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" exec "${PROMOTED_POD}" -- \
    psql -U postgres -c "
      INSERT INTO cross_cluster_demo(msg) VALUES ('written-after-promote-$(date +%s)');
      SELECT pg_is_in_recovery(), count(*) FROM cross_cluster_demo;"

  echo ""
  echo "=========================================================================="
  echo " DEMO COMPLETE — promote RTO: $((END_TS - START_TS))s — writes confirmed"
  echo "=========================================================================="
}

# ----------------------------------------------------------------------------
restore_state() {
  echo "[restore] Scaling CNPG operator back on primary..."
  kubectl --context "${PRIMARY_CTX}" -n cnpg-system scale deploy cnpg-cloudnative-pg --replicas=1
  echo "[restore] Re-enabling replica mode on ${REPLICA_CLUSTER}..."
  kubectl --context "${SECONDARY_CTX}" -n "${PG_NS}" \
    patch cluster "${REPLICA_CLUSTER}" --type=merge -p '{"spec":{"replica":{"enabled":true}}}'
  echo "[restore] Done. Wait 30s for streaming to re-establish."
}

# ----------------------------------------------------------------------------
case "${MODE}" in
  setup)   setup_replica_cluster ;;
  demo)    run_demo ;;
  restore) restore_state ;;
  *) echo "Usage: $0 {setup|demo|restore}"; exit 1 ;;
esac

#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC -- External connection demo helper
#
# Prints connection details for the cluster (host/port/user/pass/db) and the
# kubectl port-forward command to run in a separate terminal so external tools
# (VS Code PostgreSQL extension, psql, DBeaver) can reach the cluster.
#
# Usage:
#   bash scripts/15-demo-connect.sh           # default svc/pg-demo-rw
#   bash scripts/15-demo-connect.sh ro        # read-only via standbys
#   bash scripts/15-demo-connect.sh r         # any instance
#   bash scripts/15-demo-connect.sh pooler    # via PgBouncer
#   bash scripts/15-demo-connect.sh --forward # also start port-forward here
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/.env"

: "${PG_NAMESPACE:=pg-demo}"
: "${PG_CLUSTER_NAME:=pg-demo}"
: "${LOCAL_PORT:=5432}"

target="rw"
do_forward=false
for arg in "$@"; do
  case "$arg" in
    --forward|-f) do_forward=true ;;
    rw|ro|r|pooler) target="$arg" ;;
    *) echo "[warn] unknown arg: $arg" >&2 ;;
  esac
done

case "$target" in
  rw)     svc="${PG_CLUSTER_NAME}-rw"        ; role="primary (RW)" ;;
  ro)     svc="${PG_CLUSTER_NAME}-ro"        ; role="standbys (RO, round-robin)" ;;
  r)      svc="${PG_CLUSTER_NAME}-r"         ; role="any instance" ;;
  pooler) svc="${PG_CLUSTER_NAME}-rw-pooler" ; role="primary via PgBouncer" ;;
esac

echo "=========================================================================="
echo " CNPG external connection helper -- ${PG_CLUSTER_NAME} in ns ${PG_NAMESPACE}"
echo "=========================================================================="

# Confirm service exists
if ! kubectl -n "${PG_NAMESPACE}" get svc "${svc}" >/dev/null 2>&1; then
  echo "[error] Service ${svc} not found in namespace ${PG_NAMESPACE}." >&2
  echo "        Available services:" >&2
  kubectl -n "${PG_NAMESPACE}" get svc -l "cnpg.io/cluster=${PG_CLUSTER_NAME}" >&2
  exit 1
fi

# Extract credentials from the app secret
secret_name="${PG_CLUSTER_NAME}-app"
PGUSER=$(kubectl -n "${PG_NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.username}' | base64 -d)
PGPASS=$(kubectl -n "${PG_NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.password}' | base64 -d)
PGDB=$(kubectl   -n "${PG_NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.dbname}'   | base64 -d)

cat <<EOF

[info] Target service : svc/${svc}  (${role})
[info] Namespace      : ${PG_NAMESPACE}
[info] Local port     : ${LOCAL_PORT}

------------------------------------------------------------------
 Connection parameters (paste into VS Code PostgreSQL extension)
------------------------------------------------------------------
  Host     : localhost
  Port     : ${LOCAL_PORT}
  User     : ${PGUSER}
  Password : ${PGPASS}
  Database : ${PGDB}
  SSL mode : prefer   (or 'disable' if it complains -- local tunnel)

------------------------------------------------------------------
 Port-forward command (run in ANOTHER terminal if not using --forward)
------------------------------------------------------------------
  kubectl -n ${PG_NAMESPACE} port-forward svc/${svc} ${LOCAL_PORT}:5432

------------------------------------------------------------------
 Quick smoke test once port-forward is up
------------------------------------------------------------------
  PGPASSWORD='${PGPASS}' psql -h localhost -p ${LOCAL_PORT} \\
      -U ${PGUSER} -d ${PGDB} \\
      -c "SELECT inet_server_addr() AS pod_ip, current_database(), now();"

EOF

if [[ "${do_forward}" == "true" ]]; then
  echo "[info] Starting port-forward (Ctrl+C to stop)..."
  exec kubectl -n "${PG_NAMESPACE}" port-forward "svc/${svc}" "${LOCAL_PORT}:5432"
fi

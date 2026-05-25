#!/usr/bin/env bash
# ============================================================================
# Demo CNPG PoC — Demo: bidirectional interop Flex Server <-> CNPG-on-AKS
#
# Narrative (for Demo demo):
#   * Flex Server (PaaS managed) and CNPG-on-AKS (self-managed) speak the same
#     PostgreSQL wire protocol. A developer can move datasets bidirectionally
#     with stock `pg_dump | pg_restore` — no proprietary tools, no vendor
#     lock-in, same operator skills on both sides.
#   * Auth is asymmetric: Flex uses Entra ID (passwordless, AAD token);
#     CNPG uses standard PostgreSQL auth via `kubectl exec` on the primary
#     pod (Unix socket, no password file on the operator's laptop).
#   * Data flows in pipe via stdin/stdout — no intermediate file on disk.
#
# Usage:
#   bash scripts/14-demo-interop-bidir.sh prepare      # idempotent setup
#   bash scripts/14-demo-interop-bidir.sh flex-to-cnpg # demo direction 1
#   bash scripts/14-demo-interop-bidir.sh cnpg-to-flex # demo direction 2
#   bash scripts/14-demo-interop-bidir.sh demo         # prepare + both
#   bash scripts/14-demo-interop-bidir.sh cleanup      # drop demo DB on both
#
# Datasets (ligeros, optimizados para velocidad en directo):
#   * Flex.app_demo.demo_skus    — 5 filas, tabla "operacional"
#   * CNPG.app_demo.demo_audit   — 5 filas, tabla "auditoría"
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Run 'cp .env.example .env' first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

# ----------------------------------------------------------------------------
# Required env (with safe defaults)
# ----------------------------------------------------------------------------
: "${AKS_NAME:?}"
: "${RG_NAME:?}"
: "${PG_NAMESPACE:=pg-demo}"
: "${PG_CLUSTER_NAME:=pg-demo}"

: "${FLEX_FQDN:=demo-flex-postgres.postgres.database.azure.com}"
: "${FLEX_RG:=rg-existing-flex}"
: "${FLEX_SERVER:=demo-flex-postgres}"
: "${FLEX_AAD_ADMIN:=demo-admin@example.com}"
: "${INTEROP_DB:=app_demo}"

# Tooling required on operator's laptop
for tool in az kubectl pg_dump psql; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' not found in PATH." >&2
    exit 1
  }
done

# pg_dump/pg_restore major version (must be >= max(flex_pg, cnpg_pg))
DUMP_MAJOR=$(pg_dump --version | awk '{print $3}' | cut -d. -f1)
if (( DUMP_MAJOR < 17 )); then
  echo "WARNING: pg_dump major version ${DUMP_MAJOR} < 17 (Flex is PG17)."
  echo "         Dumps may miss v17-only features. Install PostgreSQL 17 client tools."
fi

PRIMARY_CTX="${AKS_NAME}"
PRIMARY_POD=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log() { printf '\n>>> %s\n' "$*"; }
step() { printf '\n[step %s] %s\n' "$1" "$2"; }

# Acquire short-lived AAD token for Flex (resource: ossrdbms-aad)
flex_aad_token() {
  az account get-access-token \
    --resource https://ossrdbms-aad.database.windows.net \
    --query accessToken -o tsv
}

# psql wrapper for Flex with AAD token as password
flex_psql() {
  local db="${1}"; shift
  PGPASSWORD="$(flex_aad_token)" \
  psql --set=sslmode=require \
       -h "${FLEX_FQDN}" \
       -U "${FLEX_AAD_ADMIN}" \
       -d "${db}" \
       -v ON_ERROR_STOP=1 \
       "$@"
}

# Discover the primary pod (cached)
get_primary_pod() {
  if [[ -z "${PRIMARY_POD}" ]]; then
    PRIMARY_POD=$(kubectl --context "${PRIMARY_CTX}" -n "${PG_NAMESPACE}" \
      get pods -l "cnpg.io/cluster=${PG_CLUSTER_NAME},role=primary" \
      -o jsonpath='{.items[0].metadata.name}')
    if [[ -z "${PRIMARY_POD}" ]]; then
      echo "ERROR: no primary pod found for cluster ${PG_CLUSTER_NAME}." >&2
      exit 1
    fi
  fi
  echo "${PRIMARY_POD}"
}

# Run psql inside the primary pod as the postgres superuser (Unix socket)
cnpg_psql_super() {
  local db="${1}"; shift
  local pod; pod=$(get_primary_pod)
  kubectl --context "${PRIMARY_CTX}" -n "${PG_NAMESPACE}" exec -i "${pod}" -- \
    psql -U postgres -d "${db}" -v ON_ERROR_STOP=1 "$@"
}

# Run psql inside the primary pod as appuser
cnpg_psql_app() {
  local db="${1}"; shift
  local pod; pod=$(get_primary_pod)
  kubectl --context "${PRIMARY_CTX}" -n "${PG_NAMESPACE}" exec -i "${pod}" -- \
    psql -U appuser -d "${db}" -v ON_ERROR_STOP=1 "$@"
}

# Run pg_dump inside the primary pod (streams to stdout)
cnpg_pg_dump() {
  local db="${1}"; shift
  local pod; pod=$(get_primary_pod)
  kubectl --context "${PRIMARY_CTX}" -n "${PG_NAMESPACE}" exec -i "${pod}" -- \
    pg_dump -U postgres -d "${db}" "$@"
}

# Run psql inside the primary pod reading SQL from stdin (for plain-format restore)
cnpg_psql_stdin() {
  local db="${1}"; shift
  local pod; pod=$(get_primary_pod)
  kubectl --context "${PRIMARY_CTX}" -n "${PG_NAMESPACE}" exec -i "${pod}" -- \
    psql -U postgres -d "${db}" -v ON_ERROR_STOP=1 "$@"
}

# ----------------------------------------------------------------------------
# prepare: idempotent setup of both databases + seed data
# ----------------------------------------------------------------------------
do_prepare() {
  log "PREPARE — idempotent setup of Flex + CNPG demo databases"

  step 1 "Ensuring database '${INTEROP_DB}' exists on Flex..."
  az postgres flexible-server db create \
    --resource-group "${FLEX_RG}" \
    --server-name "${FLEX_SERVER}" \
    --database-name "${INTEROP_DB}" >/dev/null 2>&1 || true
  echo "    flex db ready: ${FLEX_FQDN}/${INTEROP_DB}"

  step 2 "Seeding demo_skus in Flex (5 rows)..."
  flex_psql "${INTEROP_DB}" <<'SQL'
DROP TABLE IF EXISTS demo_skus;
CREATE TABLE demo_skus (
  sku_id      SERIAL PRIMARY KEY,
  ref         TEXT NOT NULL,
  family      TEXT NOT NULL,
  price_eur   NUMERIC(10,2) NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT now()
);
INSERT INTO demo_skus(ref, family, price_eur) VALUES
  ('ZARA-001', 'jeans',     49.95),
  ('ZARA-002', 'jacket',    89.95),
  ('MASS-003', 'tshirt',    19.95),
  ('BERS-004', 'sneakers',  59.95),
  ('PULL-005', 'sweater',   39.95);
SQL
  flex_psql "${INTEROP_DB}" -c "SELECT count(*) AS flex_skus FROM demo_skus;"

  step 3 "Ensuring database '${INTEROP_DB}' exists on CNPG (kubectl exec as postgres)..."
  local exists
  exists=$(cnpg_psql_super postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${INTEROP_DB}'" | tr -d '[:space:]')
  if [[ "${exists}" != "1" ]]; then
    cnpg_psql_super postgres \
      -c "CREATE DATABASE ${INTEROP_DB} OWNER appuser;"
  fi
  # PostgreSQL 15+ revokes CREATE on schema public by default
  cnpg_psql_super "${INTEROP_DB}" \
    -c "GRANT CREATE, USAGE ON SCHEMA public TO appuser;"
  echo "    cnpg db ready: ${PG_CLUSTER_NAME}-rw/${INTEROP_DB}"

  step 4 "Seeding demo_audit in CNPG (5 rows)..."
  cnpg_psql_super "${INTEROP_DB}" <<'SQL'
DROP TABLE IF EXISTS demo_audit;
CREATE TABLE demo_audit (
  event_id    SERIAL PRIMARY KEY,
  event_type  TEXT NOT NULL,
  actor       TEXT NOT NULL,
  payload     JSONB NOT NULL,
  occurred_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO demo_audit(event_type, actor, payload) VALUES
  ('sku.created',  'svc.catalog', '{"sku":"ZARA-001"}'),
  ('price.changed','svc.pricing', '{"sku":"ZARA-002","delta":5.0}'),
  ('stock.moved',  'svc.wms',     '{"sku":"MASS-003","from":"WH1","to":"WH2"}'),
  ('sku.archived', 'svc.catalog', '{"sku":"BERS-004"}'),
  ('sku.created',  'svc.catalog', '{"sku":"PULL-005"}');
SQL
  cnpg_psql_super "${INTEROP_DB}" -c "SELECT count(*) AS cnpg_audit FROM demo_audit;"

  log "PREPARE complete. Flex has demo_skus; CNPG has demo_audit."
}

# ----------------------------------------------------------------------------
# flex-to-cnpg: dump demo_skus from Flex, pipe into pg_restore inside CNPG
# ----------------------------------------------------------------------------
do_flex_to_cnpg() {
  log "DEMO 1/2 — Flex (PaaS, PG17) ────► CNPG-on-AKS (PG16)"

  step 1 "Stream pg_dump (Flex, plain SQL) → psql (CNPG primary pod, via kubectl exec)..."
  # Plain SQL format is portable across PG versions (Flex 17 -> CNPG 16).
  # `transaction_timeout` is a PG17-only GUC; filter it out so PG16 accepts the dump.
  local t0; t0=$(date +%s%3N)

  PGPASSWORD="$(flex_aad_token)" \
  pg_dump --format=plain --no-owner --no-acl \
          --clean --if-exists \
          --no-publications --no-subscriptions \
          --table=public.demo_skus \
          -h "${FLEX_FQDN}" -U "${FLEX_AAD_ADMIN}" -d "${INTEROP_DB}" \
  | sed '/^SET transaction_timeout/d' \
  | cnpg_psql_stdin "${INTEROP_DB}"

  local t1; t1=$(date +%s%3N)

  step 2 "Verifying row count in CNPG..."
  cnpg_psql_super "${INTEROP_DB}" <<SQL
SELECT
  count(*)                                   AS rows_after_restore,
  (SELECT count(*) FROM demo_audit)       AS untouched_audit_rows,
  current_database()                         AS db_now,
  version()                                  AS pg_version
FROM demo_skus;
SQL

  echo ""
  echo "✅ Flex → CNPG completed in $((t1 - t0)) ms"
}

# ----------------------------------------------------------------------------
# cnpg-to-flex: dump demo_audit from CNPG, pipe into pg_restore against Flex
# ----------------------------------------------------------------------------
do_cnpg_to_flex() {
  log "DEMO 2/2 — CNPG-on-AKS (PG16) ────► Flex (PaaS, PG17)"

  step 1 "Stream pg_dump (CNPG via kubectl exec, plain SQL) → psql (Flex)..."
  local t0; t0=$(date +%s%3N)

  cnpg_pg_dump "${INTEROP_DB}" \
      --format=plain --no-owner --no-acl \
      --clean --if-exists \
      --no-publications --no-subscriptions \
      --table=public.demo_audit \
  | PGPASSWORD="$(flex_aad_token)" \
    psql --set=sslmode=require \
         -h "${FLEX_FQDN}" -U "${FLEX_AAD_ADMIN}" -d "${INTEROP_DB}" \
         -v ON_ERROR_STOP=1

  local t1; t1=$(date +%s%3N)

  step 2 "Verifying row count in Flex..."
  flex_psql "${INTEROP_DB}" <<SQL
SELECT
  count(*)                                   AS rows_after_restore,
  (SELECT count(*) FROM demo_skus)        AS untouched_skus_rows,
  current_database()                         AS db_now,
  version()                                  AS pg_version
FROM demo_audit;
SQL

  echo ""
  echo "✅ CNPG → Flex completed in $((t1 - t0)) ms"
}

# ----------------------------------------------------------------------------
# cleanup: drop demo DB on both sides
# ----------------------------------------------------------------------------
do_cleanup() {
  log "CLEANUP — drop ${INTEROP_DB} on Flex + CNPG"

  step 1 "Dropping ${INTEROP_DB} on Flex..."
  az postgres flexible-server db delete \
    --resource-group "${FLEX_RG}" \
    --server-name "${FLEX_SERVER}" \
    --database-name "${INTEROP_DB}" --yes >/dev/null 2>&1 || true
  echo "    flex db dropped (if it existed)."

  step 2 "Dropping ${INTEROP_DB} on CNPG..."
  cnpg_psql_super postgres \
    -c "DROP DATABASE IF EXISTS ${INTEROP_DB} WITH (FORCE);" || true
}

# ----------------------------------------------------------------------------
case "${1:-demo}" in
  prepare)      do_prepare ;;
  flex-to-cnpg) do_flex_to_cnpg ;;
  cnpg-to-flex) do_cnpg_to_flex ;;
  demo)         do_prepare; do_flex_to_cnpg; do_cnpg_to_flex ;;
  cleanup)      do_cleanup ;;
  *) echo "Usage: $0 {prepare|flex-to-cnpg|cnpg-to-flex|demo|cleanup}" >&2; exit 1 ;;
esac

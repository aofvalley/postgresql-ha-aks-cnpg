# Runbook — Failover

## Goal

Demonstrate that a primary loss is recovered automatically by the CNPG operator with **RTO < 30 s** and zero data loss (sync replication).

## Pre-flight

```bash
kubectl cnpg status pg-demo -n pg-demo
```

Expect:
- 1 primary, 2 replicas
- Streaming lag = 0 B
- All instances `Ready`

## Demo A — Planned promotion (cleanest demo)

```bash
make demo-failover
# or directly:
bash scripts/10-demo-failover.sh
```

What the script does:

1. Captures current primary pod name via `.status.currentPrimary`.
2. Picks the first replica (`cnpg.io/instanceRole=replica`) as the promotion target.
3. Records `T0`, runs `kubectl cnpg promote pg-demo <replica>`.
4. Polls `.status.currentPrimary` until it equals the target.
5. Records `T1`, prints **RTO = T1 - T0** in milliseconds.

**Expected RTO**: 5–15 s. Old primary is automatically reconfigured as a replica streaming from the new one.

## Demo B — Pod kill (unplanned)

```bash
kubectl delete pod pg-demo-1 -n pg-demo --grace-period=0 --force
```

Operator detects the primary is gone, promotes the replica with the lowest WAL lag. Expected RTO ≈ 20–40 s. Verify with:

```bash
watch -n1 'kubectl cnpg status pg-demo -n pg-demo | head -20'
```

## Demo C — Node drain (zone outage simulation)

```bash
node=$(kubectl get pod pg-demo-1 -n pg-demo -o jsonpath='{.spec.nodeName}')
kubectl cordon "${node}"
kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --force
```

The PVC (Premium SSD v2 ZRS) re-attaches in another zone; CNPG promotes a replica that already runs on a healthy node. Restore the node afterwards:

```bash
kubectl uncordon "${node}"
```

## Validation queries

After promotion, connect via the rw service to prove writes succeed on the new primary:

```bash
kubectl run -it --rm psql-check --image=ghcr.io/cloudnative-pg/postgresql:16 \
  --restart=Never -n pg-demo -- \
  psql -h pg-demo-rw -U appuser -d appdb \
  -c "INSERT INTO ping(t) VALUES (now()); SELECT count(*) FROM ping;"
```

## Recovery checklist

- [ ] `kubectl cnpg status pg-demo` shows 1 primary + 2 replicas, all `streaming`
- [ ] Replication lag returns to 0 B within 60 s after promotion
- [ ] `pg-demo-rw` service endpoint matches new primary pod IP
- [ ] No `cnpg_collector_*_error` metrics > 0 in Prometheus

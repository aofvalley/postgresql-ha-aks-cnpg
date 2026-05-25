# Runbook — Backup & Restore (PITR)

## Backup model

| Element | Where | Frequency |
|---|---|---|
| WAL stream | `pg-backups/<cluster>/wals/` | Continuous |
| Base backup | `pg-backups/<cluster>/base/` | Daily 02:00 UTC (ScheduledBackup) |
| On-demand | Backup CR (`scripts/11-demo-backup.sh`) | Manual |
| Authentication | User-assigned MI via Workload Identity | n/a |

Retention is enforced by `barmanObjectStore.data.retentionPolicy: "30d"` (configurable in `04-pg-cluster.yaml`).

## Demo A — On-demand backup + verify

```bash
make demo-backup
# or:
bash scripts/11-demo-backup.sh
```

What it does:

1. Creates `Backup` CR `ondemand-<timestamp>`.
2. Polls until `.status.phase == completed`.
3. Lists blobs in `pg-backups` to confirm the new directory.
4. Spins up a `pg-demo-restore` Cluster CR using `bootstrap.recovery` from the same `barmanObjectStore`.
5. Waits for restore cluster `Ready`, runs a sanity SELECT.

## Demo B — PITR to a specific timestamp

Edit a copy of the restore manifest produced by the script and add a recovery target:

```yaml
spec:
  bootstrap:
    recovery:
      source: pg-demo-source
      recoveryTarget:
        targetTime: "2026-04-29 14:30:00+00"  # any second within retention
```

The operator replays WAL up to (and including) the timestamp, then promotes a fresh primary.

Other targets:

| Field | Meaning |
|---|---|
| `targetTime` | Stop at a given timestamp |
| `targetXID` | Stop at a specific transaction ID |
| `targetLSN` | Stop at a WAL log sequence number |
| `targetName` | Stop at a named restore point |
| `targetImmediate: true` | Stop as soon as a consistent state is reached |

## Validation queries

After restore:

```sql
SELECT pg_last_xact_replay_timestamp();
SELECT count(*) FROM appdb.public.ping;
SELECT max(t) FROM appdb.public.ping;
```

## Backup health checks

- `kubectl get scheduledbackup -n pg-demo` → next run time
- `kubectl get backup -n pg-demo` → list of completed backups
- `kubectl describe backup <name>` → uploaded WAL ranges, errors
- Prometheus: `cnpg_collector_last_available_backup_timestamp` should advance daily

## Disaster scenarios

| Scenario | Recovery path |
|---|---|
| Logical corruption (bad UPDATE) | PITR to timestamp **before** the transaction |
| Cluster destroyed | Re-deploy infra + apply Cluster CR with `bootstrap.recovery` pointing at existing barmanObjectStore |
| Region outage | Re-create infra in DR region, point `barmanObjectStore.destinationPath` at the surviving copy of the storage account (Geo-replicated container is a future hardening step) |
| Storage account compromised | Soft-delete (7 d) + versioning (90 d) lets you roll back blob state |

## Hardening notes (post-PoC)

- Switch storage account to GRS / RA-GRS for cross-region durability
- Enable immutability policies on the backup container
- Add a second ScheduledBackup at 14:00 UTC for sub-12h RPO
- Migrate from deprecated `.spec.backup.barmanObjectStore` to the Barman Cloud Plugin (already installed by `01-bootstrap.sh cnpg`)

# adv_aks — Demo TOP MODE rollback / restore guide

> Snapshot of cluster state **before** and **after** demo-mode upgrade for the Demo PostgreSQL HA on AKS PoC.
> Use this folder to restore `adv_aks` to its prior shape after the demo.

## 📸 Snapshots

| File | Description |
|---|---|
| `BEFORE-cluster.json` | `az aks show` output before changes |
| `BEFORE-nodepools.json` | `az aks nodepool list` before changes |
| `BEFORE-storageclasses.yaml` | All StorageClasses before changes |
| `AFTER-cluster.json` | `az aks show` output after demo-mode |
| `AFTER-nodepools.json` | Nodepools after demo-mode |
| `AFTER-storageclasses.yaml` | StorageClasses after demo-mode |
| `AFTER-nodes.txt` | Node listing showing 3-zone pgpool |

## 📊 State diff (BEFORE → AFTER)

| Item | BEFORE | AFTER (demo TOP) |
|---|---|---|
| **Tier** | Free | **Standard** (Uptime SLA 99.95%) |
| **Nodepools** | `agentpool` only | `agentpool` + **`pgpool`** |
| **agentpool** | 2× D4ds_v4, single-zone, autoscale 2-5 | _unchanged_ |
| **pgpool (NEW)** | – | 3× D8ds_v5, **zones 1+2+3**, taint `workload=postgres`, label `workload=postgres` |
| **Total nodes** | 2 | **5** (2 system + 3 PG) |
| **StorageClasses** | default (LRS), managed-csi-premium (LRS) | + `managed-csi-premium-v2` (PSv2 LRS) + **`managed-csi-premium-v2-zrs`** (PSv2 ZRS, 10000 IOPS / 400 MB/s) |
| **CNPG cluster instances** | 2 (PSv1 LRS, single-zone) | 3 (PSv2 ZRS, 1 per AZ) |

## 🛑 Pause cluster (after demo)

```powershell
az aks stop --resource-group adv_day2_ops --name adv_aks
```

→ All node VMs deallocated. **Stops compute billing** for all nodepools (system + pgpool).
→ Disks (PVs), LBs, public IPs continue to bill (~$5–10/day for ZRS PVs).

To resume:
```powershell
az aks start --resource-group adv_day2_ops --name adv_aks
```

## 💰 Estimated demo cost

| Scenario | Monthly equivalent | Real cost (4h demo) |
|---|---|---|
| Cluster running 24×7 (TOP mode) | ~$1,500 | n/a |
| Cluster STOPPED, only PVs billing | ~$200 (storage only) | – |
| **Recommended:** stop after each demo | ~$200 + 4h compute | **~$8–10** |

## 🔄 Rollback to BEFORE state

When you no longer need demo mode and want to restore the original cluster:

```powershell
# 1. Delete the CNPG demo cluster (releases the PSv2 ZRS PVs)
kubectl delete cluster pg-demo -n pg-demo --ignore-not-found
kubectl delete namespace pg-demo --ignore-not-found

# 2. Delete the zonal pgpool nodepool (frees 3× D8ds_v5)
az aks nodepool delete `
  --resource-group adv_day2_ops `
  --cluster-name adv_aks `
  --name pgpool `
  --no-wait

# 3. Downgrade tier back to Free
az aks update --resource-group adv_day2_ops --name adv_aks --tier free

# 4. (Optional) Remove the new StorageClasses
kubectl delete sc managed-csi-premium-v2 managed-csi-premium-v2-zrs

# 5. Verify final state matches BEFORE-cluster.json
az aks show -g adv_day2_ops -n adv_aks --query "{tier:sku.tier}" -o table
az aks nodepool list -g adv_day2_ops --cluster-name adv_aks -o table
```

Result: cluster identical to `BEFORE-cluster.json` (only `agentpool`, Free tier, no PSv2 SCs).

## 🚀 Re-deploy demo workload (after `az aks start`)

The CNPG operator and `pg-demo` cluster need to be re-deployed if you deleted them in the rollback flow:

```powershell
cd C:\path\to\postgresql-ha-aks-cnpg

# Operator (already installed if you didn't delete cnpg-system ns)
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.28.0/releases/cnpg-1.28.0.yaml

# Demo namespace + cluster (TOP MODE)
kubectl apply -f demo-adv-aks\00-namespace.yaml
kubectl apply -f demo-adv-aks\04-pg-cluster-topmode.yaml

# Wait for cluster ready
kubectl wait --for=condition=Ready cluster/pg-demo -n pg-demo --timeout=10m
kubectl get pods -n pg-demo -o wide
```

## ✅ Demo runbook (quick reference)

1. `az aks start -g adv_day2_ops -n adv_aks`  ← wait ~3 min
2. Verify nodes are zonal: `kubectl get nodes -L topology.kubernetes.io/zone`
3. Apply demo cluster: `kubectl apply -f 04-pg-cluster-topmode.yaml`
4. Wait ready, run failover demo (see parent `README.md`)
5. After demo: `az aks stop -g adv_day2_ops -n adv_aks`

---

**Generated:** 2026-04-30 | **PoC:** Demo — PostgreSQL HA on AKS with CloudNativePG

# Common issues

## 1. Pods Pending — `no PV available`

**Symptom**: `pg-demo-1` pod stuck `Pending`, PVC `Pending`, event `waiting for first consumer to be created before binding`.

**Cause**: `managed-csi-premium-v2-zrs` uses `volumeBindingMode: WaitForFirstConsumer`. This is correct — the PVC binds only when the pod is scheduled to a node.

**Action**: Confirm the pod is actually being scheduled (check tolerations and node selectors). If still stuck after 2 min, check:

```bash
kubectl describe pod pg-demo-1 -n pg-demo
kubectl get events -n pg-demo --sort-by=.lastTimestamp
```

## 2. Pods Pending — `0/N nodes match taints`

**Symptom**: PG pods Pending with `node(s) had untolerated taint workload=postgresql`.

**Cause**: The `pgpool` user pool is tainted `workload=postgresql:NoSchedule`. The cluster CR must include the matching toleration AND nodeSelector — both are present in `04-pg-cluster.yaml`.

**Action**: Verify nodes are labelled and tainted as expected:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,LABELS:.metadata.labels
```

If the user pool was renamed in `main.bicep`, update the `nodeSelector` and `tolerations` in `04-pg-cluster.yaml` accordingly.

## 3. CNPG operator pods CrashLoopBackOff — webhook cert errors

**Symptom**: operator logs show `tls: failed to verify certificate` or `webhook failed`.

**Cause**: cert-manager not installed or not ready when the CNPG chart was deployed.

**Action**:

```bash
kubectl get pods -n cert-manager
helm list -n cert-manager
# If missing, re-run:
bash scripts/01-bootstrap.sh cnpg
```

## 4. Backup phase = `failed` — `permission denied`

**Symptom**: `kubectl describe backup <name>` shows HTTP 403 or `AuthorizationPermissionMismatch`.

**Cause**: Workload Identity not properly federated or storage RBAC missing.

**Action checklist**:

1. Federated credential exists:
   ```bash
   az identity federated-credential list -g $RG_NAME --identity-name mi-${STORAGE_ACCOUNT}-backup -o table
   ```
   `subject` must be `system:serviceaccount:pg-demo:pg-demo`.

2. ServiceAccount has the workload-identity annotation:
   ```bash
   kubectl get sa pg-demo -n pg-demo -o yaml | grep azure.workload.identity/client-id
   ```
   Value must equal the MI's `clientId`.

3. Namespace + SA carry the use-label (added by `00-namespace.yaml` and CNPG). Otherwise the projected token is not injected.

4. MI has `Storage Blob Data Contributor` on the storage account (created by `storage.bicep`).

## 5. Premium SSD v2 not available in the chosen region/zone

**Symptom**: PVC events show `failed to provision volume: PremiumV2_LRS not supported in zone X`.

**Cause**: Premium SSD v2 is not GA in every region/zone combo.

**Action**:

- Confirm region support in the [Azure docs](https://learn.microsoft.com/azure/virtual-machines/disks-types#premium-ssd-v2)
- Switch `LOCATION` in `.env` to a fully supported region (e.g. `westeurope`, `northeurope`, `eastus2`)
- Or temporarily fall back to `managed-csi-premium` (Premium SSD v1) — edit `02-storage-class.yaml`

## 6. `kubectl cnpg` plugin missing

**Symptom**: `error: unknown command "cnpg" for "kubectl"`.

**Action**:

```bash
kubectl krew install cnpg
# or, without krew:
curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo bash
```

## 7. PgBouncer pods Pending — `cluster not found`

**Symptom**: `Pooler pg-demo-rw-pooler` shows error `referenced cluster does not exist`.

**Cause**: Pooler manifest applied before Cluster CR is created.

**Action**: Re-apply after the cluster is `Ready`. The bootstrap script does this in the right order; manual users should follow `00 → 02 → 04 → 05 → 06 → 07 → 08`.

## 8. `envsubst` not found on Windows

**Symptom**: `01-bootstrap.sh cluster` fails with `envsubst: command not found`.

**Action**: Run inside WSL2 (`gettext` package), or install Git Bash `gettext`, or render manually:

```bash
sed -e "s|\${BACKUP_IDENTITY_CLIENT_ID}|${BACKUP_IDENTITY_CLIENT_ID}|g" \
    -e "s|\${STORAGE_ACCOUNT}|${STORAGE_ACCOUNT}|g" \
    -e "s|\${BACKUP_CONTAINER}|${BACKUP_CONTAINER}|g" \
    manifests/04-pg-cluster.yaml | kubectl apply -f -
```

## 9. PodMonitor not picked up by Managed Prometheus

**Symptom**: no CNPG metrics in Grafana / metric explorer.

**Cause**: Managed Prometheus by default scrapes only the `kube-system` and `monitoring` namespaces.

**Action**: Add `pg-demo` to the Azure Monitor `ama-metrics-prometheus-config` ConfigMap, or label the namespace so the scraper picks it up. See [Customize Prometheus collection](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-configuration).

## 10. `barmanObjectStore` deprecation warning

**Symptom**: operator logs `WARN spec.backup.barmanObjectStore is deprecated, use Barman Cloud Plugin`.

**Action**: Cosmetic for the PoC. Migration path:

1. Plugin is already installed by `01-bootstrap.sh cnpg` (`plugin-barman-cloud`).
2. Replace `.spec.backup.barmanObjectStore` with a `.spec.plugins[]` entry referencing the plugin's `BackupConfig` CR (see plugin docs).
3. Keep `serviceAccountTemplate` annotation for Workload Identity.

Track the migration as a follow-up task; not required for the PoC demo.

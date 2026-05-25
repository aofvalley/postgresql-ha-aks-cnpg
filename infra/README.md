# infra/

Bicep templates for the Demo CNPG PoC.

| File | What it creates |
|---|---|
| [`main.bicep`](./main.bicep) | AKS cluster (multi-AZ, Cilium, OIDC + Workload Identity, Azure Monitor add-on, managed Prometheus, Azure Linux nodes) + dedicated `pgpool` user node pool spanning 3 zones + Log Analytics workspace |
| [`storage.bicep`](./storage.bicep) | Storage Account (StorageV2, TLS 1.2, blob versioning + 7-day soft delete) + `pg-backups` private container + user-assigned managed identity with `Storage Blob Data Contributor` role |
| [`deploy.sh`](./deploy.sh) | Idempotent wrapper that reads `../.env`, ensures the resource group exists, deploys both templates, and runs `az aks get-credentials` |

## Naming
All resources land in the resource group from `RG_NAME` (default `rg-pgha-demo`). Tags applied: `client=demo`, `workload=postgresql-ha-cnpg`, `env=demo`, `owner=csa-team`.

## Outputs you'll use later

After `bash deploy.sh` you can grab the values used by the cluster manifest with:

```bash
az deployment group show -g "$RG_NAME" -n "$(az deployment group list -g $RG_NAME --query '[?starts_with(name, `stg-pgha-`)].name | [0]' -o tsv)" --query 'properties.outputs' -o json
```

Notable outputs:
- `aksOidcIssuerUrl` → used to create the FederatedIdentityCredential bound to the CNPG ServiceAccount
- `backupIdentityClientId` → injected into the CNPG pod via `azure.workload.identity/client-id` annotation
- `blobEndpoint` → used in `manifests/04-pg-cluster.yaml` `barmanObjectStore.destinationPath`

## Notes
- The user pool has a `workload=postgresql:NoSchedule` taint — Cluster CR uses the matching toleration.
- `apiServerAccessProfile.enablePrivateCluster` is `false` for demo simplicity. Flip to `true` for production along with proper bastion/VPN.
- Storage Account network ACL is `Allow` from any source for demo. Restrict to the AKS subnet (or use private endpoints) before going to prod.

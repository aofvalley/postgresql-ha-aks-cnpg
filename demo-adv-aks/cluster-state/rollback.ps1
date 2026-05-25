# Rollback adv_aks to BEFORE state
# Run this to undo demo TOP MODE upgrades and return to lab baseline.
# See README.md in this folder for full diff and snapshots.

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RG = 'adv_day2_ops'
$AKS = 'adv_aks'

if (-not $Force) {
    Write-Host "⚠️  This will:" -ForegroundColor Yellow
    Write-Host "   - Delete CNPG cluster pg-demo + namespace"
    Write-Host "   - Delete nodepool 'pgpool' (3× D8ds_v5)"
    Write-Host "   - Downgrade tier Standard → Free"
    Write-Host "   - Delete StorageClasses managed-csi-premium-v2 + managed-csi-premium-v2-zrs"
    Write-Host ""
    $c = Read-Host "Continue? (y/N)"
    if ($c -ne 'y') { Write-Host "Aborted." ; exit 0 }
}

Write-Host "`n[1/5] Deleting CNPG demo cluster..." -ForegroundColor Cyan
kubectl delete cluster pg-demo -n pg-demo --ignore-not-found --timeout=120s
kubectl delete namespace pg-demo --ignore-not-found --timeout=120s

Write-Host "`n[2/5] Deleting pgpool nodepool (this takes ~5 min)..." -ForegroundColor Cyan
az aks nodepool delete --resource-group $RG --cluster-name $AKS --name pgpool

Write-Host "`n[3/5] Downgrading AKS tier to Free..." -ForegroundColor Cyan
az aks update --resource-group $RG --name $AKS --tier free

Write-Host "`n[4/5] Removing PSv2 StorageClasses..." -ForegroundColor Cyan
kubectl delete sc managed-csi-premium-v2 --ignore-not-found
kubectl delete sc managed-csi-premium-v2-zrs --ignore-not-found

Write-Host "`n[5/5] Verifying final state..." -ForegroundColor Cyan
az aks show -g $RG -n $AKS --query "{tier:sku.tier, k8s:kubernetesVersion}" -o table
az aks nodepool list -g $RG --cluster-name $AKS -o table
kubectl get sc

Write-Host "`n✅ Rollback complete. Compare with BEFORE-*.json to verify." -ForegroundColor Green

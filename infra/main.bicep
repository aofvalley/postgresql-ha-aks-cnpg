// ============================================================================
// Demo CNPG PoC — AKS multi-zona + Log Analytics + Azure Monitor
// Idempotent. Deploy with `bash infra/deploy.sh` (wraps az deployment group create)
//
// Highlights:
//   - AKS multi-zone across 3 AZ (zones 1,2,3)
//   - System pool: Standard_D8ds_v5 (2 nodes, taints CriticalAddonsOnly)
//   - User pool : Standard_D16ds_v5 (3 nodes, one per zone)
//   - OIDC issuer + Workload Identity enabled (for backup secret federation)
//   - Azure Monitor for containers + Log Analytics workspace
//   - Premium SSD v2 ZRS supported via storage class (applied later in manifests/)
// ============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('AKS cluster name.')
param aksName string

@description('Log Analytics workspace name.')
param logAnalyticsName string

@description('System node pool VM size.')
param systemPoolVmSize string = 'Standard_D8ds_v5'

@description('System node pool node count.')
@minValue(1)
@maxValue(5)
param systemPoolCount int = 2

@description('User (PostgreSQL) node pool VM size.')
param userPoolVmSize string = 'Standard_D16ds_v5'

@description('User node pool node count (one per zone).')
@minValue(3)
@maxValue(9)
param userPoolCount int = 3

@description('Kubernetes version (must support CNPG 1.28).')
param kubernetesVersion string = '1.33'

@description('Tags applied to all resources.')
param tags object = {
  client: 'demo'
  workload: 'postgresql-ha-cnpg'
  env: 'demo'
  owner: 'csa-team'
}

// ----------------------------------------------------------------------------
// Log Analytics workspace (used by Azure Monitor for containers add-on)
// ----------------------------------------------------------------------------
resource logws 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ----------------------------------------------------------------------------
// AKS cluster — multi-zone, OIDC + Workload Identity, Azure Monitor add-on
// ----------------------------------------------------------------------------
resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Standard' // Standard tier required for SLA + uptime guarantees in prod-like demo
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: '${aksName}-dns'

    // OIDC + Workload Identity — required to use federated identity for Blob backup access
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // Multi-zone control plane (AZ-spread system pool below)
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        vmSize: systemPoolVmSize
        count: systemPoolCount
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        availabilityZones: [
          '1'
          '2'
          '3'
        ]
        nodeTaints: [
          'CriticalAddonsOnly=true:NoSchedule'
        ]
        enableAutoScaling: false
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'cilium'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
    }

    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logws.id
        }
      }
      azurepolicy: {
        enabled: true
        config: {
          version: 'v2'
        }
      }
    }

    // Azure Monitor metrics (managed Prometheus) — useful for CNPG PodMonitor scraping
    azureMonitorProfile: {
      metrics: {
        enabled: true
      }
    }

    apiServerAccessProfile: {
      enablePrivateCluster: false // demo simplicity; flip to true for prod
    }
  }
}

// ----------------------------------------------------------------------------
// User node pool dedicated to PostgreSQL — one node per AZ
// ----------------------------------------------------------------------------
resource userPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-09-01' = {
  parent: aks
  name: 'pgpool'
  properties: {
    mode: 'User'
    vmSize: userPoolVmSize
    count: userPoolCount
    osType: 'Linux'
    osSKU: 'AzureLinux'
    type: 'VirtualMachineScaleSets'
    availabilityZones: [
      '1'
      '2'
      '3'
    ]
    nodeLabels: {
      workload: 'postgresql'
    }
    nodeTaints: [
      'workload=postgresql:NoSchedule'
    ]
    enableAutoScaling: false
    maxPods: 110
  }
}

// ----------------------------------------------------------------------------
// Outputs consumed by scripts/01-bootstrap.sh
// ----------------------------------------------------------------------------
output aksName string = aks.name
output aksOidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output aksKubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
output logAnalyticsId string = logws.id

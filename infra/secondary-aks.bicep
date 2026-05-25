// ============================================================================
// Demo CNPG PoC — Secondary AKS for Replica Cluster demo
//
// Minimal cluster: single system pool, no Workload Identity (no backups),
// reuses Log Analytics from primary. Single zone OK for replica demo.
// ============================================================================

@description('Azure region.')
param location string = resourceGroup().location

@description('Secondary AKS cluster name.')
param secondaryAksName string

@description('Log Analytics workspace resource ID (reuse from primary).')
param logAnalyticsId string

@description('Node VM size.')
param vmSize string = 'Standard_D4ds_v4'

@description('Node count.')
@minValue(2)
@maxValue(4)
param nodeCount int = 2

@description('Kubernetes version.')
param kubernetesVersion string = '1.33'

@description('Tags applied to all resources.')
param tags object = {
  client: 'demo'
  workload: 'postgresql-ha-cnpg'
  env: 'demo'
  role: 'replica-cluster'
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: secondaryAksName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: '${secondaryAksName}-dns'

    oidcIssuerProfile: {
      enabled: false
    }
    securityProfile: {
      workloadIdentity: {
        enabled: false
      }
    }

    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        vmSize: vmSize
        count: nodeCount
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        maxPods: 110
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'azure'
      loadBalancerSku: 'standard'
      serviceCidr: '10.1.0.0/16'
      dnsServiceIP: '10.1.0.10'
    }

    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsId
        }
      }
    }

    apiServerAccessProfile: {
      enablePrivateCluster: false
    }
  }
}

output secondaryAksName string = aks.name
output secondaryAksKubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId

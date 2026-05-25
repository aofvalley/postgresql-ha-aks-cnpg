// ============================================================================
// Demo CNPG PoC — Storage Account + Blob container for Barman Cloud backups
// Managed identity grants `Storage Blob Data Contributor` to the AKS workload
// identity that CNPG will federate with (binding done via FederatedIdentityCredential
// in scripts/01-bootstrap.sh after AKS OIDC issuer URL is known).
// ============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Globally unique storage account name (lowercase, <=24 chars).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Blob container holding Barman base backups + WAL archive.')
param backupContainerName string = 'pg-backups'

@description('Tags applied to all resources.')
param tags object = {
  client: 'demo'
  workload: 'postgresql-ha-cnpg'
  env: 'demo'
}

// ----------------------------------------------------------------------------
// User-assigned managed identity that CNPG pods will federate with via Workload Identity
// ----------------------------------------------------------------------------
resource backupIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mi-${storageAccountName}-backup'
  location: location
  tags: tags
}

// ----------------------------------------------------------------------------
// Storage Account — Standard_LRS for demo. Switch to Standard_ZRS or RA-GRS for prod.
// ----------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // Barman plugin can use either SAS or workload identity; keep on for demo
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow' // demo only — restrict to AKS subnet for prod
    }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    isVersioningEnabled: true
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: backupContainerName
  properties: {
    publicAccess: 'None'
  }
}

// ----------------------------------------------------------------------------
// RBAC: grant `Storage Blob Data Contributor` to the user-assigned identity
// ----------------------------------------------------------------------------
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, backupIdentity.id, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: backupIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output backupContainerName string = backupContainerName
output backupIdentityClientId string = backupIdentity.properties.clientId
output backupIdentityResourceId string = backupIdentity.id
output blobEndpoint string = storage.properties.primaryEndpoints.blob

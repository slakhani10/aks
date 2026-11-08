// -----------------------------------------------------------------------------
// Key Vault (CIS 8.x): RBAC authorization, soft delete + purge protection,
// public network access disabled, reachable only via private endpoint, audit
// logs to Log Analytics.
// -----------------------------------------------------------------------------

param prefix string
param location string
param tags object

@description('Key Vault name (globally unique, max 24 chars).')
param keyVaultName string

param privateEndpointSubnetId string

@description('vNets that must resolve the vault privately (AKS vNet + App Gateway vNet).')
param linkedVnetIds array

param logAnalyticsWorkspaceId string

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (vnetId, i) in linkedVnetIds: {
    parent: dnsZone
    name: '${last(split(vnetId, '/'))}-link'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${prefix}-pe-kv'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    customNetworkInterfaceName: '${prefix}-pe-kv-nic'
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: kv.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource peDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vaultcore'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: kv
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        // allLogs includes the AuditEvent category (CIS 5.1.5)
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri

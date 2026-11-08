// =============================================================================
// Secure AKS environment aligned with CIS Microsoft Azure Foundations Benchmark v1.4
//
// Deploy into an EXISTING resource group. All resources:
//   * are created in the resource group's region
//   * are named with the resource group name as prefix: <rg>-aks, <rg>-vnet-aks, ...
//
// Traffic flow:  Internet -> App Gateway WAF_v2 (own vNet) -> peering -> AKS internal LB
// AKS egress:    NAT Gateway, filtered by NSG rules in config/aks-egress-rules.json
// =============================================================================
targetScope = 'resourceGroup'

// ------------------------------------------------------------- Required inputs --
@description('VM SKU for the system node pool (e.g. Standard_D4ds_v5).')
param systemNodeVmSize string = 'Standard_D4ds_v5'

@description('Node count for the system node pool. Use 3+ for production.')
@minValue(1)
@maxValue(100)
param systemNodeCount int = 3

@description('VM SKU for the user (workload) node pool. Defaults to the system pool SKU.')
param userNodeVmSize string = systemNodeVmSize

@description('Node count for the user (workload) node pool.')
@minValue(0)
@maxValue(1000)
param userNodeCount int = 2

// ------------------------------------------------------------- Optional inputs --
@description('Kubernetes version. Leave empty to use the AKS default for the region.')
param kubernetesVersion string = ''

@description('Entra ID group object IDs that get AKS cluster admin (Azure RBAC).')
param aksAdminGroupObjectIds array = []

@description('Object ID of the deploying service principal. Gets AKS RBAC Cluster Admin so the pipeline can run "az aks command invoke". Leave empty to skip.')
param deployerPrincipalId string = ''

@description('Optional Key Vault secret ID of a PFX certificate. When set, App Gateway serves HTTPS and redirects HTTP to HTTPS.')
param appGatewayCertificateKvUri string = ''

@description('Enable host-based encryption for node VMs (temp disks and caches). Requires the Microsoft.Compute/EncryptionAtHost feature to be registered on the subscription.')
param enableEncryptionAtHost bool = true

@description('Enable VNet flow logs + Traffic Analytics (CIS 6.4/6.5). Requires an existing Network Watcher for the region.')
param enableVnetFlowLogs bool = false

@description('Resource group of the regional Network Watcher (only used when enableVnetFlowLogs = true).')
param networkWatcherResourceGroup string = 'NetworkWatcherRG'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

// ------------------------------------------------------------ Address space ----
// AKS vNet /22 (1,024 IPs). With Azure CNI Overlay pods use podCidr, so the node
// subnet only needs node IPs: /24 = 251 nodes. The remaining /23 is free for
// additional node pools or subnets.
@description('AKS vNet address space.')
param aksVnetAddressPrefix string = '10.0.0.0/22'
param aksNodeSubnetPrefix string = '10.0.0.0/24'
@description('Subnet that hosts the AKS internal load balancer frontend IP(s) used by the App Gateway.')
param aksIngressSubnetPrefix string = '10.0.1.0/28'
param aksPrivateEndpointSubnetPrefix string = '10.0.1.16/28'

// App Gateway vNet /24. AGW subnet /25 = 123 usable IPs, enough for the maximum
// autoscale capacity (10) with lots of headroom; the other /25 is free.
@description('App Gateway vNet address space.')
param agwVnetAddressPrefix string = '10.1.0.0/24'
param agwSubnetPrefix string = '10.1.0.0/25'

// Overlay ranges - must not overlap any vNet you peer/route to.
param podCidr string = '10.244.0.0/16'
param serviceCidr string = '172.16.0.0/16'
param dnsServiceIp string = '172.16.0.10'

// ------------------------------------------------------------------- Naming ----
var prefix = toLower(resourceGroup().name)
var location = resourceGroup().location
var tags = union(resourceGroup().?tags ?? {}, {
  workload: 'aks'
  'security-baseline': 'cis-azure-foundations-1.4'
})

// Alphanumeric-only prefix for resources with strict naming rules (Key Vault, Storage).
var alnumPrefix = replace(replace(replace(replace(prefix, '-', ''), '_', ''), '.', ''), '(', '')
var uniqueSuffix = uniqueString(resourceGroup().id)
var keyVaultName = take('${take(alnumPrefix, 13)}kv${uniqueSuffix}', 24)
var flowLogStorageName = take('${take(alnumPrefix, 13)}fl${uniqueSuffix}', 24)

// Static private IP of the AKS internal LB that App Gateway forwards to
// (first usable address in an Azure subnet = host index 3).
var ingressPrivateIp = cidrHost(aksIngressSubnetPrefix, 3)

var egressRules = loadJsonContent('config/aks-egress-rules.json')

// Built-in role definition IDs
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// ---------------------------------------------------------------- Modules ------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    prefix: prefix
    location: location
    tags: tags
    retentionInDays: logRetentionDays
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    prefix: prefix
    location: location
    tags: tags
    aksVnetAddressPrefix: aksVnetAddressPrefix
    aksNodeSubnetPrefix: aksNodeSubnetPrefix
    aksIngressSubnetPrefix: aksIngressSubnetPrefix
    aksPrivateEndpointSubnetPrefix: aksPrivateEndpointSubnetPrefix
    agwVnetAddressPrefix: agwVnetAddressPrefix
    agwSubnetPrefix: agwSubnetPrefix
    aksEgressRules: egressRules
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    prefix: prefix
    location: location
    tags: tags
    keyVaultName: keyVaultName
    privateEndpointSubnetId: network.outputs.aksPrivateEndpointSubnetId
    linkedVnetIds: [
      network.outputs.aksVnetId
      network.outputs.agwVnetId
    ]
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    prefix: prefix
    location: location
    tags: tags
    aksVnetName: network.outputs.aksVnetName
    nodeSubnetId: network.outputs.aksNodeSubnetId
    systemNodeVmSize: systemNodeVmSize
    systemNodeCount: systemNodeCount
    userNodeVmSize: userNodeVmSize
    userNodeCount: userNodeCount
    kubernetesVersion: kubernetesVersion
    enableEncryptionAtHost: enableEncryptionAtHost
    adminGroupObjectIds: aksAdminGroupObjectIds
    deployerPrincipalId: deployerPrincipalId
    podCidr: podCidr
    serviceCidr: serviceCidr
    dnsServiceIp: dnsServiceIp
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

module appGateway 'modules/appgateway.bicep' = {
  name: 'appgateway'
  params: {
    prefix: prefix
    location: location
    tags: tags
    subnetId: network.outputs.agwSubnetId
    identityId: agwIdentity.id
    backendPrivateIp: ingressPrivateIp
    certificateKvUri: appGatewayCertificateKvUri
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
  // The App Gateway needs Key Vault access before it can load an HTTPS certificate.
  dependsOn: [
    kvRoleAgw
  ]
}

module policy 'modules/policy.bicep' = {
  name: 'policy'
  params: {
    prefix: prefix
  }
}

// --------------------------------------------- Key Vault RBAC assignments -----
resource kvExisting 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// App Gateway identity is created up-front so its Key Vault access exists before the gateway.
resource agwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-agw'
  location: location
  tags: tags
}

resource kvRoleAgw 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, keyVaultName, agwIdentity.id, roleKeyVaultSecretsUser)
  scope: kvExisting
  properties: {
    principalId: agwIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
  }
  dependsOn: [
    keyVault
  ]
}

resource kvRoleCsi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, keyVaultName, 'aks-kv-secrets-provider', roleKeyVaultSecretsUser)
  scope: kvExisting
  properties: {
    principalId: aks.outputs.keyVaultSecretsProviderPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
  }
  dependsOn: [
    keyVault
  ]
}

// ------------------------------------------------------- VNet flow logs ---------
resource flowLogStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (enableVnetFlowLogs) {
  name: flowLogStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    // CIS 3.1, 3.12 (TLS 1.2), 3.5/3.7 (no public blob access, deny public network)
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
    }
  }
}

module flowLogs 'modules/flowlogs.bicep' = if (enableVnetFlowLogs) {
  name: 'flowlogs-${prefix}'
  scope: resourceGroup(networkWatcherResourceGroup)
  params: {
    location: location
    tags: tags
    networkWatcherName: 'NetworkWatcher_${location}'
    vnetIds: [
      network.outputs.aksVnetId
      network.outputs.agwVnetId
    ]
    storageAccountId: flowLogStorage.id
    retentionDays: 365
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    logAnalyticsWorkspaceCustomerId: monitoring.outputs.workspaceCustomerId
  }
}

// ---------------------------------------------------------------- Outputs ------
output location string = location
output aksName string = aks.outputs.aksName
output aksNodeResourceGroup string = '${prefix}-aks-nodes'
output appGatewayName string = appGateway.outputs.appGatewayName
output appGatewayPublicIp string = appGateway.outputs.publicIpAddress
output appGatewayFqdn string = appGateway.outputs.publicFqdn
output ingressPrivateIp string = ingressPrivateIp
output ingressSubnetName string = network.outputs.aksIngressSubnetName
output keyVaultName string = keyVault.outputs.keyVaultName
output natGatewayPublicIp string = network.outputs.natGatewayPublicIp
output logAnalyticsWorkspaceName string = monitoring.outputs.workspaceName
output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl

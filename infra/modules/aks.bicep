// -----------------------------------------------------------------------------
// Private AKS cluster
//  * Private API server (no public FQDN), Entra ID auth + Azure RBAC, local accounts disabled
//  * Azure CNI Overlay + Cilium network policy, NAT Gateway egress (no public LB)
//  * Azure Policy, Defender, Container Insights, Key Vault CSI driver, workload identity
//  * Encryption at host, automatic patch + node image upgrades, image cleaner
// -----------------------------------------------------------------------------

param prefix string
param location string
param tags object

param aksVnetName string
param nodeSubnetId string

param systemNodeVmSize string
param systemNodeCount int
param userNodeVmSize string
param userNodeCount int

@description('Kubernetes version. Empty = AKS default for the region.')
param kubernetesVersion string

param enableEncryptionAtHost bool

@description('Entra ID group object IDs granted cluster admin.')
param adminGroupObjectIds array

@description('Optional principal (e.g. the CI/CD service principal) granted cluster admin via Azure RBAC.')
param deployerPrincipalId string

param podCidr string
param serviceCidr string
param dnsServiceIp string

param logAnalyticsWorkspaceId string

var aksName = '${prefix}-aks'

// Built-in role definition IDs
var roleNetworkContributor = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var roleAksRbacClusterAdmin = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

resource aksVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: aksVnetName
}

resource controlPlaneIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-aks'
  location: location
  tags: tags
}

// The control plane identity must manage the BYO subnets (node subnet, ILB subnet, NAT GW association).
resource vnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksVnet.id, controlPlaneIdentity.id, roleNetworkContributor)
  scope: aksVnet
  properties: {
    principalId: controlPlaneIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleNetworkContributor)
  }
}

var commonPoolProperties = {
  osType: 'Linux'
  osSKU: 'AzureLinux'
  type: 'VirtualMachineScaleSets'
  vnetSubnetID: nodeSubnetId
  enableNodePublicIP: false
  enableEncryptionAtHost: enableEncryptionAtHost
  osDiskType: 'Managed'
  osDiskSizeGB: 128
  maxPods: 110
  upgradeSettings: {
    maxSurge: '33%'
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlPlaneIdentity.id}': {}
    }
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    dnsPrefix: aksName
    nodeResourceGroup: '${prefix}-aks-nodes'
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: subscription().tenantId
      adminGroupObjectIDs: adminGroupObjectIds
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: 'system'
    }
    agentPoolProfiles: [
      union(commonPoolProperties, {
        name: 'system'
        mode: 'System'
        vmSize: systemNodeVmSize
        count: systemNodeCount
        // Keep application pods off the system pool
        nodeTaints: [
          'CriticalAddonsOnly=true:NoSchedule'
        ]
      })
      union(commonPoolProperties, {
        name: 'user'
        mode: 'User'
        vmSize: userNodeVmSize
        count: userNodeCount
      })
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      podCidr: podCidr
      serviceCidr: serviceCidr
      dnsServiceIP: dnsServiceIp
      loadBalancerSku: 'standard'
      outboundType: 'userAssignedNATGateway'
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      imageCleaner: {
        enabled: true
        intervalHours: 168
      }
      defender: {
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
        securityMonitoring: {
          enabled: true
        }
      }
    }
    addonProfiles: {
      azurepolicy: {
        enabled: true
      }
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
        }
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
    }
  }
  dependsOn: [
    vnetNetworkContributor
  ]
}

// ------------------------------------------- Container Insights (managed identity) --
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'MSCI-${location}-${aksName}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerInsights-Group-Default'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Off'
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'ciworkspace'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerInsights-Group-Default'
        ]
        destinations: [
          'ciworkspace'
        ]
      }
    ]
  }
}

resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Container Insights data collection for ${aksName}'
  }
}

// ------------------------------------------------- Control plane logs (CIS 5.x) --
resource aksDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: aks
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in [
        'kube-apiserver'
        'kube-audit-admin'
        'kube-controller-manager'
        'kube-scheduler'
        'cluster-autoscaler'
        'guard'
      ]: {
        category: category
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

// ------------------------------------------------------ Azure RBAC for Kubernetes --
resource groupAdmins 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for groupId in adminGroupObjectIds: {
    name: guid(aks.id, groupId, roleAksRbacClusterAdmin)
    scope: aks
    properties: {
      principalId: groupId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAksRbacClusterAdmin)
    }
  }
]

resource deployerAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(aks.id, deployerPrincipalId, roleAksRbacClusterAdmin)
  scope: aks
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAksRbacClusterAdmin)
  }
}

output aksName string = aks.name
output aksId string = aks.id
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output keyVaultSecretsProviderPrincipalId string = aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
output controlPlaneIdentityPrincipalId string = controlPlaneIdentity.properties.principalId

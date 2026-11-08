// -----------------------------------------------------------------------------
// Networking: two separate, peered virtual networks
//   * AKS vNet          -> node subnet, internal-ingress subnet, private-endpoint subnet
//   * App Gateway vNet  -> dedicated Application Gateway (WAF_v2) subnet
// Every subnet has an NSG (CIS 6.x). AKS egress goes through a NAT Gateway and is
// filtered by the NSG egress rules in config/aks-egress-rules.json.
// -----------------------------------------------------------------------------

param prefix string
param location string
param tags object

param aksVnetAddressPrefix string
param aksNodeSubnetPrefix string
param aksIngressSubnetPrefix string
param aksPrivateEndpointSubnetPrefix string
param agwVnetAddressPrefix string
param agwSubnetPrefix string

@description('Outbound NSG rules applied to the AKS subnets (see config/aks-egress-rules.json).')
param aksEgressRules array

param logAnalyticsWorkspaceId string

var aksVnetName = '${prefix}-vnet-aks'
var agwVnetName = '${prefix}-vnet-agw'
var aksNodeSubnetName = '${prefix}-snet-aks-nodes'
var aksIngressSubnetName = '${prefix}-snet-aks-ingress'
var aksPeSubnetName = '${prefix}-snet-pe'
var agwSubnetName = '${prefix}-snet-agw'

// ---------------------------------------------------------------- NSG: AKS --
var aksInboundRules = [
  {
    name: 'Allow-AppGateway-HTTP-HTTPS-Inbound'
    properties: {
      description: 'Only the Application Gateway subnet may reach the internal ingress on 80/443.'
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: agwSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: aksVnetAddressPrefix
      destinationPortRanges: [
        '80'
        '443'
      ]
    }
  }
  {
    name: 'Deny-AppGateway-Other-Inbound'
    properties: {
      description: 'Block any other traffic from the peered Application Gateway vNet.'
      priority: 110
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: agwVnetAddressPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Deny-Internet-Inbound'
    properties: {
      description: 'No direct Internet ingress to AKS. All user traffic must traverse the Application Gateway WAF.'
      priority: 4000
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

var aksOutboundRules = [
  for rule in aksEgressRules: {
    name: rule.name
    properties: {
      description: rule.?description ?? ''
      priority: rule.priority
      direction: 'Outbound'
      access: rule.access
      protocol: rule.protocol
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: rule.destinationAddressPrefix
      destinationPortRanges: rule.destinationPortRanges
    }
  }
]

resource aksNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg-aks'
  location: location
  tags: tags
  properties: {
    securityRules: concat(aksInboundRules, aksOutboundRules)
  }
}

// ------------------------------------------------------ NSG: App Gateway ----
// Rules required by Application Gateway v2:
// https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups
resource agwNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg-agw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Internet-HTTP-HTTPS-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: agwSubnetPrefix
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
      {
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          description: 'Required by the Application Gateway v2 control plane.'
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ------------------------------------------------------- NAT Gateway ---------
// Deterministic, outbound-only egress for AKS. No public load balancer is created.
resource natPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-pip-natgw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-05-01' = {
  name: '${prefix}-natgw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
  }
}

// ------------------------------------------------------------ vNets ---------
resource aksVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: aksVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        aksVnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: aksNodeSubnetName
        properties: {
          addressPrefix: aksNodeSubnetPrefix
          networkSecurityGroup: {
            id: aksNsg.id
          }
          natGateway: {
            id: natGw.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: aksIngressSubnetName
        properties: {
          addressPrefix: aksIngressSubnetPrefix
          networkSecurityGroup: {
            id: aksNsg.id
          }
          defaultOutboundAccess: false
        }
      }
      {
        name: aksPeSubnetName
        properties: {
          addressPrefix: aksPrivateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: aksNsg.id
          }
          defaultOutboundAccess: false
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource agwVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: agwVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        agwVnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: agwSubnetName
        properties: {
          addressPrefix: agwSubnetPrefix
          networkSecurityGroup: {
            id: agwNsg.id
          }
        }
      }
    ]
  }
}

// ------------------------------------------------------------ Peering -------
resource aksToAgw 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: aksVnet
  name: 'peer-to-${agwVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: agwVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource agwToAks 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: agwVnet
  name: 'peer-to-${aksVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: aksVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [
    aksToAgw
  ]
}

// ------------------------------------------------------ Diagnostics ---------
resource aksNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: aksNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource agwNsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: agwNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource natPipDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: natPip
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
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

output aksVnetId string = aksVnet.id
output aksVnetName string = aksVnet.name
output agwVnetId string = agwVnet.id
output aksNodeSubnetId string = aksVnet.properties.subnets[0].id
output aksIngressSubnetId string = aksVnet.properties.subnets[1].id
output aksIngressSubnetName string = aksIngressSubnetName
output aksPrivateEndpointSubnetId string = aksVnet.properties.subnets[2].id
output agwSubnetId string = agwVnet.properties.subnets[0].id
output natGatewayPublicIp string = natPip.properties.ipAddress
output aksNsgName string = aksNsg.name

// -----------------------------------------------------------------------------
// Application Gateway WAF_v2: the only Internet-facing entry point.
//   Internet -> Public IP -> WAF (Prevention, Microsoft DRS 2.1 + Bot Manager)
//            -> peered AKS vNet -> internal load balancer IP (AKS ingress subnet)
// When a Key Vault certificate secret ID is supplied an HTTPS listener (TLS 1.2+)
// is created and HTTP is redirected to HTTPS.
// -----------------------------------------------------------------------------

param prefix string
param location string
param tags object

param subnetId string

@description('Resource ID of the user-assigned identity used to read the TLS certificate from Key Vault.')
param identityId string

@description('Private IP of the AKS internal load balancer / ingress controller (backend target).')
param backendPrivateIp string

@description('Optional Key Vault secret ID (versionless recommended) of a PFX certificate for the HTTPS listener.')
param certificateKvUri string

@minValue(0)
@maxValue(125)
param minCapacity int = 2

@minValue(2)
@maxValue(125)
param maxCapacity int = 10

param logAnalyticsWorkspaceId string

var agwName = '${prefix}-agw'
var useHttps = !empty(certificateKvUri)
var agwId = resourceId('Microsoft.Network/applicationGateways', agwName)

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-pip-agw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: toLower('${prefix}-agw-${uniqueString(resourceGroup().id)}')
    }
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: '${prefix}-wafpol'
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.0'
        }
      ]
    }
  }
}

var httpListener = {
  name: 'listener-http'
  properties: {
    frontendIPConfiguration: {
      id: '${agwId}/frontendIPConfigurations/frontend-public'
    }
    frontendPort: {
      id: '${agwId}/frontendPorts/port-80'
    }
    protocol: 'Http'
  }
}

var httpsListener = {
  name: 'listener-https'
  properties: {
    frontendIPConfiguration: {
      id: '${agwId}/frontendIPConfigurations/frontend-public'
    }
    frontendPort: {
      id: '${agwId}/frontendPorts/port-443'
    }
    protocol: 'Https'
    sslCertificate: {
      id: '${agwId}/sslCertificates/listener-cert'
    }
  }
}

var routeToAksRule = {
  name: 'rule-to-aks'
  properties: {
    ruleType: 'Basic'
    priority: 200
    httpListener: {
      id: '${agwId}/httpListeners/${useHttps ? 'listener-https' : 'listener-http'}'
    }
    backendAddressPool: {
      id: '${agwId}/backendAddressPools/pool-aks-ingress'
    }
    backendHttpSettings: {
      id: '${agwId}/backendHttpSettingsCollection/settings-aks-ingress'
    }
  }
}

var redirectRule = {
  name: 'rule-http-to-https'
  properties: {
    ruleType: 'Basic'
    priority: 100
    httpListener: {
      id: '${agwId}/httpListeners/listener-http'
    }
    redirectConfiguration: {
      id: '${agwId}/redirectConfigurations/redirect-http-to-https'
    }
  }
}

resource agw 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: agwName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: minCapacity
      maxCapacity: maxCapacity
    }
    enableHttp2: true
    firewallPolicy: {
      id: wafPolicy.id
    }
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101S'
    }
    gatewayIPConfigurations: [
      {
        name: 'gateway-ipconfig'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontend-public'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: concat(
      [
        {
          name: 'port-80'
          properties: {
            port: 80
          }
        }
      ],
      useHttps
        ? [
            {
              name: 'port-443'
              properties: {
                port: 443
              }
            }
          ]
        : []
    )
    sslCertificates: useHttps
      ? [
          {
            name: 'listener-cert'
            properties: {
              keyVaultSecretId: certificateKvUri
            }
          }
        ]
      : []
    backendAddressPools: [
      {
        name: 'pool-aks-ingress'
        properties: {
          backendAddresses: [
            {
              ipAddress: backendPrivateIp
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'probe-aks-ingress'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'settings-aks-ingress'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          pickHostNameFromBackendAddress: false
          probe: {
            id: '${agwId}/probes/probe-aks-ingress'
          }
        }
      }
    ]
    httpListeners: useHttps ? [httpListener, httpsListener] : [httpListener]
    redirectConfigurations: useHttps
      ? [
          {
            name: 'redirect-http-to-https'
            properties: {
              redirectType: 'Permanent'
              targetListener: {
                id: '${agwId}/httpListeners/listener-https'
              }
              includePath: true
              includeQueryString: true
            }
          }
        ]
      : []
    requestRoutingRules: useHttps ? [redirectRule, routeToAksRule] : [routeToAksRule]
  }
}

resource agwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: agw
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        // Access, Performance and Firewall logs
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

resource pipDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: pip
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

output appGatewayName string = agw.name
output publicIpAddress string = pip.properties.ipAddress
output publicFqdn string = pip.properties.dnsSettings.fqdn
output wafPolicyName string = wafPolicy.name

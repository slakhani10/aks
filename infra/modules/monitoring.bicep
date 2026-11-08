@description('Naming prefix (resource group name).')
param prefix string

param location string
param tags object

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-log'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output workspaceId string = law.id
output workspaceCustomerId string = law.properties.customerId
output workspaceName string = law.name

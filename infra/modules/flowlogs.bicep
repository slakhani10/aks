// -----------------------------------------------------------------------------
// VNet flow logs (CIS 6.4 / 6.5 successor to NSG flow logs). Deployed into the
// regional Network Watcher's resource group, because Azure only allows one
// Network Watcher per region per subscription.
// -----------------------------------------------------------------------------

param location string
param tags object

param networkWatcherName string

@description('Target vNets to log.')
param vnetIds array

param storageAccountId string

@minValue(91)
param retentionDays int

param logAnalyticsWorkspaceId string
param logAnalyticsWorkspaceCustomerId string

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-05-01' existing = {
  name: networkWatcherName
}

resource flowLogs 'Microsoft.Network/networkWatchers/flowLogs@2024-05-01' = [
  for vnetId in vnetIds: {
    parent: networkWatcher
    name: '${last(split(vnetId, '/'))}-flowlog'
    location: location
    tags: tags
    properties: {
      targetResourceId: vnetId
      storageId: storageAccountId
      enabled: true
      format: {
        type: 'JSON'
        version: 2
      }
      retentionPolicy: {
        enabled: true
        days: retentionDays
      }
      flowAnalyticsConfiguration: {
        networkWatcherFlowAnalyticsConfiguration: {
          enabled: true
          workspaceId: logAnalyticsWorkspaceCustomerId
          workspaceRegion: location
          workspaceResourceId: logAnalyticsWorkspaceId
          trafficAnalyticsInterval: 10
        }
      }
    }
  }
]

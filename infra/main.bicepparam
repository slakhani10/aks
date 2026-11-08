// Example parameters for local deployments:
//   az deployment group create -g <existing-rg> -f infra/main.bicep -p infra/main.bicepparam
// The GitHub Actions workflow passes these values from its run inputs instead.
using 'main.bicep'

param systemNodeVmSize = 'Standard_D4ds_v5'
param systemNodeCount = 3
param userNodeVmSize = 'Standard_D4ds_v5'
param userNodeCount = 2

// Optional
// param aksAdminGroupObjectIds = ['00000000-0000-0000-0000-000000000000']
// param appGatewayCertificateKvUri = 'https://<vault>.vault.azure.net/secrets/<cert-name>'
// param enableVnetFlowLogs = true

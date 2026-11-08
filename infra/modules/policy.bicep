// -----------------------------------------------------------------------------
// Azure Policy assignments (resource-group scope) enforced in-cluster by the
// AKS Azure Policy add-on (Gatekeeper).
// -----------------------------------------------------------------------------

param prefix string

// Built-in: "Kubernetes clusters should use internal load balancers"
// Blocks any Service of type LoadBalancer that would get a public IP, so the only
// Internet entry point stays the Application Gateway WAF.
var internalLbPolicyId = '/providers/Microsoft.Authorization/policyDefinitions/3fc4dc25-5baf-40d8-9b05-7fe74c1bc64e'

// Built-in initiative: "Kubernetes cluster pod security baseline standards for Linux-based workloads"
var podSecurityBaselineId = '/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d'

var excludedNamespaces = [
  'kube-system'
  'gatekeeper-system'
  'azure-arc'
  'azure-extensions-usage-system'
  'aks-command'
]

resource internalLb 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: take('${prefix}-aks-internal-lb', 64)
  properties: {
    displayName: '${prefix}: AKS services must use internal load balancers'
    policyDefinitionId: internalLbPolicyId
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'deny'
      }
      excludedNamespaces: {
        value: excludedNamespaces
      }
    }
  }
}

resource podSecurity 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: take('${prefix}-aks-pod-baseline', 64)
  properties: {
    displayName: '${prefix}: AKS pod security baseline (deny)'
    policyDefinitionId: podSecurityBaselineId
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'deny'
      }
      excludedNamespaces: {
        value: excludedNamespaces
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Azure Policy assignments (resource-group scope), enforced in-cluster by the
# AKS Azure Policy add-on (Gatekeeper).
# -----------------------------------------------------------------------------

locals {
  policy_excluded_namespaces = [
    "kube-system",
    "gatekeeper-system",
    "azure-arc",
    "azure-extensions-usage-system",
    "aks-command",
    "azure-alb-system", # ALB Controller for App Gateway for Containers (installed via Helm)
  ]
}

# Built-in: "Kubernetes clusters should use internal load balancers"
# Blocks any Service of type LoadBalancer that would get a public IP, so the only
# Internet entry point stays App Gateway for Containers with WAF.
resource "azurerm_resource_group_policy_assignment" "aks_internal_lb" {
  name                 = substr("${local.prefix}-aks-internal-lb", 0, min(64, length("${local.prefix}-aks-internal-lb")))
  display_name         = "${local.prefix}: AKS services must use internal load balancers"
  resource_group_id    = data.azurerm_resource_group.this.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/3fc4dc25-5baf-40d8-9b05-7fe74c1bc64e"
  enforce              = true

  parameters = jsonencode({
    effect             = { value = "deny" }
    excludedNamespaces = { value = local.policy_excluded_namespaces }
  })
}

# Built-in initiative: "Kubernetes cluster pod security baseline standards for Linux-based workloads"
resource "azurerm_resource_group_policy_assignment" "aks_pod_baseline" {
  name                 = substr("${local.prefix}-aks-pod-baseline", 0, min(64, length("${local.prefix}-aks-pod-baseline")))
  display_name         = "${local.prefix}: AKS pod security baseline (deny)"
  resource_group_id    = data.azurerm_resource_group.this.id
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
  enforce              = true

  parameters = jsonencode({
    effect             = { value = "deny" }
    excludedNamespaces = { value = local.policy_excluded_namespaces }
  })
}

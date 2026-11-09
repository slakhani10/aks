# =============================================================================
# Secure AKS environment aligned with CIS Microsoft Azure Foundations Benchmark v1.4
#
# Deploys into an EXISTING resource group. All resources:
#   * are created in the resource group's region
#   * are named with the resource group name as prefix: <rg>-aks, <rg>-vnet-aks, ...
#
# Traffic flow: Internet -> App Gateway WAF_v2 (own vNet) -> peering -> AKS internal LB
# AKS egress:   NAT Gateway, filtered by NSG rules in config/aks-egress-rules.json
# =============================================================================

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  prefix   = lower(data.azurerm_resource_group.this.name)
  location = data.azurerm_resource_group.this.location
  rg_name  = data.azurerm_resource_group.this.name

  # Every taggable resource gets the resource group's tags (plus optional
  # additional_tags; the resource group's value wins if a key exists in both).
  # The AKS cluster also propagates these to the resources in its node resource group.
  tags = merge(var.additional_tags, data.azurerm_resource_group.this.tags)

  # Alphanumeric-only prefix for resources with strict naming rules (Key Vault, Storage).
  alnum_prefix       = replace(local.prefix, "/[^a-z0-9]/", "")
  short_alnum_prefix = substr(local.alnum_prefix, 0, min(length(local.alnum_prefix), 13))
  unique_suffix      = substr(sha1(data.azurerm_resource_group.this.id), 0, 8)
  key_vault_name     = "${local.short_alnum_prefix}kv${local.unique_suffix}"
  flowlog_sa_name    = "${local.short_alnum_prefix}fl${local.unique_suffix}"

  aks_name          = "${local.prefix}-aks"
  user_node_vm_size = coalesce(var.user_node_vm_size, var.system_node_vm_size)

  # Static private IP of the AKS internal LB that App Gateway forwards to
  # (first usable address in an Azure subnet: .4).
  ingress_private_ip = cidrhost(local.aks_ingress_subnet_cidr, 4)

  egress_rules = jsondecode(file("${path.module}/config/aks-egress-rules.json"))
}

# ---------------------------------------------------------------- Monitoring --
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.prefix}-log"
  location            = local.location
  resource_group_name = local.rg_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

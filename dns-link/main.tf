# =============================================================================
# Links the AKS environment's vNets to EXISTING central private DNS zones that
# live in another subscription (e.g. created by ../dns-zones).
#
# Looks up both zones by subscription + resource group + name, then creates:
#   Key Vault zone  <- AKS vNet, runner vNet (if any)
#   AKS API zone    <- runner vNet (if any)
# The AKS vNet is NOT linked to the API zone here: AKS creates that link itself
# when the cluster uses a custom private DNS zone (a second link from the same
# vNet would conflict).
# =============================================================================

data "azurerm_resource_group" "env" {
  name = var.resource_group_name
}

locals {
  prefix         = lower(data.azurerm_resource_group.env.name)
  runner_enabled = var.runner_vnet_name != null && var.runner_vnet_name != ""

  aks_private_dns_zone_name = coalesce(var.aks_private_dns_zone_name, "privatelink.${data.azurerm_resource_group.env.location}.azmk8s.io")

  tags = data.azurerm_resource_group.env.tags
}

# --------------------------------------------- AKS environment (default sub) --
data "azurerm_virtual_network" "aks" {
  name                = "${local.prefix}-vnet-aks"
  resource_group_name = data.azurerm_resource_group.env.name
}

data "azurerm_virtual_network" "runner" {
  count = local.runner_enabled ? 1 : 0

  name                = var.runner_vnet_name
  resource_group_name = data.azurerm_resource_group.env.name
}

# ------------------------------------------- Central zones (DNS subscription) --
data "azurerm_private_dns_zone" "kv" {
  provider = azurerm.dns

  name                = var.kv_private_dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

data "azurerm_private_dns_zone" "aks_api" {
  provider = azurerm.dns

  name                = local.aks_private_dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name

  lifecycle {
    precondition {
      condition     = endswith(local.aks_private_dns_zone_name, "privatelink.${data.azurerm_resource_group.env.location}.azmk8s.io")
      error_message = "The API server zone must be privatelink.${data.azurerm_resource_group.env.location}.azmk8s.io (or a subzone) to match the cluster's region."
    }
  }
}

locals {
  vnets = merge(
    { aks = data.azurerm_virtual_network.aks },
    local.runner_enabled ? { runner = data.azurerm_virtual_network.runner[0] } : {}
  )

  # zone key/vnet key -> link
  links = merge(
    { for k, v in local.vnets : "kv/${k}" => { zone_id = data.azurerm_private_dns_zone.kv.id, vnet = v } },
    local.runner_enabled ? {
      "aks_api/runner" = { zone_id = data.azurerm_private_dns_zone.aks_api.id, vnet = data.azurerm_virtual_network.runner[0] }
    } : {}
  )
}

# Link names include the environment's resource group so several environments can
# share the central zones without name clashes.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.links
  provider = azurerm.dns

  name                 = "${each.value.vnet.name}-link"
  private_dns_zone_id  = each.value.zone_id
  virtual_network_id   = each.value.vnet.id
  registration_enabled = false
  tags                 = local.tags
}

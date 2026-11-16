# =============================================================================
# Central private DNS zones for the secure AKS environment(s):
#   * privatelink.vaultcore.azure.net      - Key Vault private endpoints
#   * privatelink.<region>.azmk8s.io       - private AKS API servers
#
# Created in an EXISTING resource group of the chosen subscription (typically a
# hub / shared-services subscription). Zones are not linked to any vNet here:
# the AKS deployment uses them (dns_zone_* variables) and the "Link private DNS
# zones" workflow (../dns-link) links the environment's vNets.
# =============================================================================

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  aks_region = coalesce(var.aks_region, data.azurerm_resource_group.this.location)
  tags       = merge(var.additional_tags, data.azurerm_resource_group.this.tags)

  zones = {
    key_vault = "privatelink.vaultcore.azure.net"
    aks_api   = "privatelink.${local.aks_region}.azmk8s.io"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.zones

  name                = each.value
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

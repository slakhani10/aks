# =============================================================================
# Central private DNS zones for the secure AKS environment(s):
#   * privatelink.vaultcore.azure.net      - Key Vault private endpoints
#   * privatelink.<region>.azmk8s.io       - private AKS API servers
#   * privatelink.azurecr.io               - Azure Container Registry private endpoints
#   * privatelink.postgres.database.azure.com - PostgreSQL flexible server private endpoints
#
# Created in an EXISTING resource group of the chosen subscription (typically a
# hub / shared-services subscription). Zones are not linked to any vNet here:
# the AKS deployment (workflow input central_dns_zones = "<subscription>/<rg>")
# uses them and links its own vNets.
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
    acr       = "privatelink.azurecr.io"
    postgres  = "privatelink.postgres.database.azure.com"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.zones

  name                = each.value
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# Private DNS for the private API server, the Key Vault private endpoint and the
# service zones (Azure Container Registry, PostgreSQL flexible server) used by
# private endpoints that workloads add later.
#
# Two modes:
#   * Local (default): both zones are created in this resource group and linked to
#     the AKS vNet (and the private runner vNet when connected).
#   * Central: set dns_zone_resource_group_name (and dns_zone_subscription_id when
#     the zones live in another subscription) to use EXISTING zones, e.g. created by
#     ../dns-zones. They are looked up by name and linked from here, in the DNS
#     subscription (provider alias "dns"):
#       Key Vault zone        <- AKS vNet, runner vNet (if connected)
#       ACR / PostgreSQL zones <- AKS vNet, runner vNet (if connected)
#       AKS API zone          <- runner vNet (if connected)
#     AKS links its own vNet to the API zone (documented AKS behaviour for custom
#     zones), so that link is not created here - a second one would conflict.
#
# A cluster's private DNS zone can't be changed after creation: switching between
# modes on an existing cluster recreates the cluster.
# -----------------------------------------------------------------------------

locals {
  central_dns = var.dns_zone_resource_group_name != null && var.dns_zone_resource_group_name != ""

  aks_private_dns_zone_name = coalesce(var.aks_private_dns_zone_name, "privatelink.${local.location}.azmk8s.io")

  kv_dns_zone_id  = local.central_dns ? data.azurerm_private_dns_zone.kv_central[0].id : azurerm_private_dns_zone.kv[0].id
  aks_dns_zone_id = local.central_dns ? data.azurerm_private_dns_zone.aks_api_central[0].id : azurerm_private_dns_zone.aks_api[0].id

  # Service zones (key => zone name); empty names are skipped.
  service_dns_zone_names = {
    for k, v in {
      acr      = var.acr_private_dns_zone_name
      postgres = var.postgres_private_dns_zone_name
    } : k => v if v != null && v != ""
  }

  # vNets that must resolve the service zones.
  dns_linked_vnets = merge(
    { aks = { name = azurerm_virtual_network.aks.name, id = azurerm_virtual_network.aks.id } },
    local.runner_enabled ? {
      runner = { name = data.azurerm_virtual_network.runner[0].name, id = data.azurerm_virtual_network.runner[0].id }
    } : {}
  )

  # One link per (zone, vNet), keyed "<zone key>-<vnet key>", e.g. "acr-aks".
  service_dns_zone_links = {
    for pair in setproduct(keys(local.service_dns_zone_names), keys(local.dns_linked_vnets)) :
    "${pair[0]}-${pair[1]}" => { zone = pair[0], vnet = pair[1] }
  }

  service_dns_zone_ids = local.central_dns ? {
    for k, z in data.azurerm_private_dns_zone.service_central : k => z.id
    } : {
    for k, z in azurerm_private_dns_zone.service : k => z.id
  }
}

# ------------------------------------------------------------ Central zones --
data "azurerm_private_dns_zone" "kv_central" {
  count    = local.central_dns ? 1 : 0
  provider = azurerm.dns

  name                = var.kv_private_dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

data "azurerm_private_dns_zone" "aks_api_central" {
  count    = local.central_dns ? 1 : 0
  provider = azurerm.dns

  name                = local.aks_private_dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name

  lifecycle {
    precondition {
      condition     = endswith(local.aks_private_dns_zone_name, "privatelink.${local.location}.azmk8s.io")
      error_message = "aks_private_dns_zone_name must be privatelink.${local.location}.azmk8s.io (or a subzone of it) - the zone must match the cluster's region."
    }
  }
}

# -------------------------------------------------------------- Local zones --
resource "azurerm_private_dns_zone" "kv" {
  count = local.central_dns ? 0 : 1

  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  for_each = local.central_dns ? {} : merge(
    {
      aks = { name = azurerm_virtual_network.aks.name, id = azurerm_virtual_network.aks.id }
    },
    # Lets jobs on the private runner manage secrets/certificates in the private vault.
    local.runner_enabled ? {
      runner = { name = data.azurerm_virtual_network.runner[0].name, id = data.azurerm_virtual_network.runner[0].id }
    } : {}
  )

  name                 = "${each.value.name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.kv[0].id
  virtual_network_id   = each.value.id
  registration_enabled = false
  tags                 = local.tags
}

# Kept in this resource group (rather than AKS's "System" zone in the node resource
# group) so it can be linked to other vNets - such as the private GitHub runner -
# with the deployment identity's resource-group-scoped permissions.
resource "azurerm_private_dns_zone" "aks_api" {
  count = local.central_dns ? 0 : 1

  name                = local.aks_private_dns_zone_name
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_api" {
  count = local.central_dns ? 0 : 1

  name                 = "${azurerm_virtual_network.aks.name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.aks_api[0].id
  virtual_network_id   = azurerm_virtual_network.aks.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_api_runner" {
  count = !local.central_dns && local.runner_enabled ? 1 : 0

  name                 = "${var.runner_vnet_name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.aks_api[0].id
  virtual_network_id   = data.azurerm_virtual_network.runner[0].id
  registration_enabled = false
  tags                 = local.tags
}

# ----------------------------------------------- Links to central zones --
# Created in the DNS subscription; names carry the vNet name (which includes this
# environment's resource group) so several environments can share the zones.
resource "azurerm_private_dns_zone_virtual_network_link" "kv_central" {
  for_each = local.central_dns ? merge(
    { aks = { name = azurerm_virtual_network.aks.name, id = azurerm_virtual_network.aks.id } },
    local.runner_enabled ? {
      runner = { name = data.azurerm_virtual_network.runner[0].name, id = data.azurerm_virtual_network.runner[0].id }
    } : {}
  ) : {}
  provider = azurerm.dns

  name                 = "${each.value.name}-link"
  private_dns_zone_id  = data.azurerm_private_dns_zone.kv_central[0].id
  virtual_network_id   = each.value.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_api_runner_central" {
  count    = local.central_dns && local.runner_enabled ? 1 : 0
  provider = azurerm.dns

  name                 = "${var.runner_vnet_name}-link"
  private_dns_zone_id  = data.azurerm_private_dns_zone.aks_api_central[0].id
  virtual_network_id   = data.azurerm_virtual_network.runner[0].id
  registration_enabled = false
  tags                 = local.tags
}

# ------------------------------------------------ Service zones (ACR, PG) --
data "azurerm_private_dns_zone" "service_central" {
  for_each = local.central_dns ? local.service_dns_zone_names : {}
  provider = azurerm.dns

  name                = each.value
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_private_dns_zone" "service" {
  for_each = local.central_dns ? {} : local.service_dns_zone_names

  name                = each.value
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "service" {
  for_each = local.central_dns ? {} : local.service_dns_zone_links

  name                 = "${local.dns_linked_vnets[each.value.vnet].name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.service[each.value.zone].id
  virtual_network_id   = local.dns_linked_vnets[each.value.vnet].id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "service_central" {
  for_each = local.central_dns ? local.service_dns_zone_links : {}
  provider = azurerm.dns

  name                 = "${local.dns_linked_vnets[each.value.vnet].name}-link"
  private_dns_zone_id  = data.azurerm_private_dns_zone.service_central[each.value.zone].id
  virtual_network_id   = local.dns_linked_vnets[each.value.vnet].id
  registration_enabled = false
  tags                 = local.tags
}

# AKS writes the API server's A record into the zone (and, for a central zone,
# links its own vNet). Required for local and central zones alike.
resource "azurerm_role_assignment" "aks_private_dns_contributor" {
  scope                            = local.aks_dns_zone_id
  role_definition_name             = "Private DNS Zone Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# --------------------------------------------- State moves (no re-creation) --
moved {
  from = azurerm_private_dns_zone.kv
  to   = azurerm_private_dns_zone.kv[0]
}

moved {
  from = azurerm_private_dns_zone.aks_api
  to   = azurerm_private_dns_zone.aks_api[0]
}

moved {
  from = azurerm_private_dns_zone_virtual_network_link.aks_api
  to   = azurerm_private_dns_zone_virtual_network_link.aks_api[0]
}

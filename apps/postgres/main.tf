# =============================================================================
# Optional PostgreSQL flexible server for ONE application on the secure AKS
# environment, reachable ONLY through a private endpoint in the environment's
# private endpoint subnet (<rg>-snet-pe, inside the AKS vNet):
#
#   pods / private runner --5432--> private endpoint (snet-pe) --> PostgreSQL
#   <server>.postgres.database.azure.com -> privatelink zone -> private IP
#
# Public network access is disabled, TLS is required and connection logging is on
# (CIS Azure 1.4 section 4.3, adapted to flexible server). Diagnostics go to the
# environment's Log Analytics workspace. Created and destroyed by the
# "Deploy application" workflow (apps/), never by the AKS deployment.
# =============================================================================

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  prefix   = lower(data.azurerm_resource_group.this.name)
  location = data.azurerm_resource_group.this.location
  tags     = merge(var.additional_tags, data.azurerm_resource_group.this.tags, { "app" = var.app_name })

  # Server names are global DNS names: lowercase letters, digits and '-', 3-63
  # characters. A short hash of the resource group ID keeps them unique.
  name_prefix   = trim(substr(replace(local.prefix, "/[^a-z0-9-]/", "-"), 0, 20), "-")
  unique_suffix = substr(sha1(data.azurerm_resource_group.this.id), 0, 6)
  server_name   = "${local.name_prefix}-${var.app_name}-pg-${local.unique_suffix}"

  database_name = coalesce(var.database_name, replace(var.app_name, "-", "_"))

  # CIS-aligned server parameters.
  server_parameters = {
    "require_secure_transport"   = "on" # TLS only
    "log_checkpoints"            = "on"
    "log_connections"            = "on"
    "log_disconnections"         = "on"
    "connection_throttle.enable" = "on"
    "logfiles.retention_days"    = "7" # > 3 days
  }
}

# Resources of the AKS environment, found by its naming convention.
data "azurerm_subnet" "pe" {
  name                 = "${local.prefix}-snet-pe"
  virtual_network_name = "${local.prefix}-vnet-aks"
  resource_group_name  = var.resource_group_name
}

data "azurerm_log_analytics_workspace" "this" {
  name                = "${local.prefix}-log"
  resource_group_name = var.resource_group_name
}

# Admin password: generated, kept in the (private, Entra-ID-only) state and handed
# to the application as a Kubernetes Secret by the workflow - never printed.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "-_.~" # URL-safe, so DATABASE_URL needs no escaping
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = local.server_name
  resource_group_name = var.resource_group_name
  location            = local.location
  version             = var.postgres_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # Private endpoint only: no public access, no VNet injection.
  public_network_access_enabled = false

  administrator_login    = "pgadmin"
  administrator_password = random_password.admin.result

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  tags = local.tags

  lifecycle {
    # Azure picks the zone when none is given; don't fight it on later runs.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "this" {
  for_each = local.server_parameters

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = local.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  count = var.entra_admin_object_id == null || var.entra_admin_object_id == "" ? 0 : 1

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.entra_admin_object_id
  principal_name      = var.entra_admin_principal_name
  principal_type      = var.entra_admin_principal_type

  lifecycle {
    precondition {
      condition     = var.entra_admin_principal_name != null && var.entra_admin_principal_name != ""
      error_message = "entra_admin_principal_name is required with entra_admin_object_id."
    }
  }
}

resource "azurerm_private_endpoint" "this" {
  name                          = "${local.prefix}-pe-${var.app_name}-pg"
  location                      = local.location
  resource_group_name           = var.resource_group_name
  subnet_id                     = data.azurerm_subnet.pe.id
  custom_network_interface_name = "${local.prefix}-pe-${var.app_name}-pg-nic"
  tags                          = local.tags

  private_service_connection {
    name                           = "postgresqlServer"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.postgres_private_dns_zone_id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

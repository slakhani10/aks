# -----------------------------------------------------------------------------
# Azure Database for PostgreSQL flexible server 16 with PRIVATE ACCESS (VNet
# integration), for the workloads of this environment.
#
#   <rg>-vnet-aks
#   ├─ <rg>-snet-aks-nodes ──TCP 5432──┐   pods leave the overlay with the node IP
#   └─ <rg>-snet-pg  (delegated to Microsoft.DBforPostgreSQL/flexibleServers)
#        NSG <rg>-nsg-pg: 5432 only from the node subnet, the subnet itself (HA)
#        and the private runner; out: Storage (WAL archive) + Entra ID only
#   DNS  <prefix>.private.postgres.database.azure.com  (linked to AKS + runner vNets)
#
# CIS Azure 1.4 section 4.3 (flexible-server equivalents): TLS enforced, log
# checkpoints / connections / disconnections, connection throttling, log
# retention > 3 days, no public network access. Diagnostics go to Log Analytics.
#
# The server can't move to another subnet or vNet after creation, and the
# delegated subnet can't grow while the server exists - it is a /27 (27 usable
# addresses; an HA server uses 4).
# -----------------------------------------------------------------------------

locals {
  pg_enabled = var.postgres_enabled

  # 2nd /27 of the vNet's 2nd /24 (e.g. 10.0.1.64/27) - next to the PE subnet
  # (10.0.1.16/28), leaving the vNet's 4th /24 free for growth.
  pg_subnet_cidr = cidrsubnet(var.aks_vnet_cidr, 27 - local.aks_vnet_bits, 10)

  # DNS-label-safe version of the resource-group prefix.
  pg_name_prefix = trim(substr(replace(local.prefix, "/[^a-z0-9-]/", "-"), 0, 40), "-")
  pg_server_name = "${local.pg_name_prefix}-pg-${local.unique_suffix}"
  # VNet-integrated servers need their own zone ending in postgres.database.azure.com
  # (not the privatelink zone used by private endpoints, and not the server name).
  pg_dns_zone_name = "${local.pg_name_prefix}.private.postgres.database.azure.com"

  pg_entra_admin = var.postgres_entra_admin_object_id != null && var.postgres_entra_admin_object_id != ""

  pg_nsg_rules = merge({
    "Allow-AKS-Nodes-PostgreSQL-Inbound" = {
      description                = "Pods (SNAT to their node IP) and nodes may connect to PostgreSQL."
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.aks_node_subnet_cidr
      destination_address_prefix = local.pg_subnet_cidr
      destination_port_ranges    = ["5432"]
    }
    "Allow-Subnet-PostgreSQL-Inbound" = {
      description                = "High availability / replication inside the delegated subnet (required)."
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.pg_subnet_cidr
      destination_address_prefix = local.pg_subnet_cidr
      destination_port_ranges    = ["5432"]
    }
    "Allow-AzureLoadBalancer-Inbound" = {
      description                = "Azure platform health probes."
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_address_prefix      = "AzureLoadBalancer"
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Deny-VirtualNetwork-Inbound" = {
      description                = "Nothing else in the vNet, peered vNets or on-premises may reach the database subnet."
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Allow-Subnet-PostgreSQL-Outbound" = {
      description                = "High availability / replication inside the delegated subnet (required)."
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.pg_subnet_cidr
      destination_address_prefix = local.pg_subnet_cidr
      destination_port_ranges    = ["5432"]
    }
    "Allow-Storage-Outbound" = {
      description                = "WAL archiving and backups to Azure Storage (required)."
      priority                   = 110
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      destination_address_prefix = "Storage"
      destination_port_ranges    = ["443"]
    }
    "Allow-AzureActiveDirectory-Outbound" = {
      description                = "Microsoft Entra ID authentication."
      priority                   = 120
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      destination_address_prefix = "AzureActiveDirectory"
      destination_port_ranges    = ["443"]
    }
    "Deny-Internet-Outbound" = {
      description                = "No other Internet egress from the database subnet."
      priority                   = 4000
      direction                  = "Outbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "Internet"
      destination_port_ranges    = ["*"]
    }
    }, local.runner_enabled ? {
    "Allow-Runner-PostgreSQL-Inbound" = {
      description                = "Private GitHub runner: database jobs such as migrations."
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.runner_vnet_ranges[0]
      destination_address_prefix = local.pg_subnet_cidr
      destination_port_ranges    = ["5432"]
    }
  } : {})
}

# ------------------------------------------------------------- Network ------
resource "azurerm_subnet" "pg" {
  count = local.pg_enabled ? 1 : 0

  name                            = "${local.prefix}-snet-pg"
  resource_group_name             = local.rg_name
  virtual_network_name            = azurerm_virtual_network.aks.name
  address_prefixes                = [local.pg_subnet_cidr]
  default_outbound_access_enabled = false
  # Added by the service with the first server anyway (WAL upload path); declared so
  # Terraform never removes it.
  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "flexibleServers"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "pg" {
  count = local.pg_enabled ? 1 : 0

  name                = "${local.prefix}-nsg-pg"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "pg" {
  for_each = local.pg_enabled ? local.pg_nsg_rules : {}

  name                        = each.key
  description                 = each.value.description
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_address_prefix       = each.value.source_address_prefix
  source_port_range           = "*"
  destination_address_prefix  = each.value.destination_address_prefix
  destination_port_range      = length(each.value.destination_port_ranges) == 1 ? each.value.destination_port_ranges[0] : null
  destination_port_ranges     = length(each.value.destination_port_ranges) > 1 ? each.value.destination_port_ranges : null
  resource_group_name         = local.rg_name
  network_security_group_name = azurerm_network_security_group.pg[0].name
}

resource "azurerm_subnet_network_security_group_association" "pg" {
  count = local.pg_enabled ? 1 : 0

  subnet_id                 = azurerm_subnet.pg[0].id
  network_security_group_id = azurerm_network_security_group.pg[0].id

  depends_on = [azurerm_network_security_rule.pg]
}

resource "azurerm_monitor_diagnostic_setting" "pg_nsg" {
  count = local.pg_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_network_security_group.pg[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }
}

# ----------------------------------------------------------------- DNS ------
resource "azurerm_private_dns_zone" "pg" {
  count = local.pg_enabled ? 1 : 0

  name                = local.pg_dns_zone_name
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  for_each = local.pg_enabled ? local.dns_linked_vnets : {}

  name                 = "${each.value.name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.pg[0].id
  virtual_network_id   = each.value.id
  registration_enabled = false
  tags                 = local.tags
}

# -------------------------------------------------------------- Server ------
# Break-glass admin password: kept only in the (private, Entra-ID-only) Terraform
# state and the sensitive output postgres_admin_password. Prefer Entra ID logins
# (postgres_entra_admin_*) and turn password auth off with
# postgres_password_auth_enabled = false once they work.
resource "random_password" "pg_admin" {
  count = local.pg_enabled ? 1 : 0

  length           = 32
  special          = true
  override_special = "-_.~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_postgresql_flexible_server" "this" {
  count = local.pg_enabled ? 1 : 0

  name                = local.pg_server_name
  resource_group_name = local.rg_name
  location            = local.location
  version             = "16"
  sku_name            = var.postgres_sku_name
  storage_mb          = var.postgres_storage_mb
  auto_grow_enabled   = true

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup_enabled

  # Private access (VNet integration): no public endpoint at all.
  delegated_subnet_id           = azurerm_subnet.pg[0].id
  private_dns_zone_id           = azurerm_private_dns_zone.pg[0].id
  public_network_access_enabled = false

  administrator_login    = var.postgres_password_auth_enabled ? "pgadmin" : null
  administrator_password = var.postgres_password_auth_enabled ? random_password.pg_admin[0].result : null

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = var.postgres_password_auth_enabled
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  dynamic "high_availability" {
    for_each = var.postgres_high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 2
    start_minute = 0
  }

  tags = local.tags

  # The DNS zone must be linked before the server registers its record, and the
  # NSG must allow the platform's traffic before the server is placed in the subnet.
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.pg,
    azurerm_subnet_network_security_group_association.pg,
  ]

  lifecycle {
    # Azure picks zones when none are given; don't fight it on later runs.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]

    precondition {
      condition     = var.postgres_password_auth_enabled || local.pg_entra_admin
      error_message = "With postgres_password_auth_enabled = false, set postgres_entra_admin_object_id / _principal_name, otherwise nobody can log in."
    }
    precondition {
      condition     = !var.postgres_high_availability || !startswith(var.postgres_sku_name, "B_")
      error_message = "High availability isn't available for Burstable (B_) SKUs - use e.g. GP_Standard_D2ds_v5."
    }
  }
}

# CIS server parameters. Applied one after another: the service rejects
# concurrent configuration changes on one server.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  count     = local.pg_enabled ? 1 : 0
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  count     = local.pg_enabled ? 1 : 0
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.require_secure_transport]
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  count     = local.pg_enabled ? 1 : 0
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_checkpoints]
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  count     = local.pg_enabled ? 1 : 0
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_connections]
}

resource "azurerm_postgresql_flexible_server_configuration" "connection_throttle" {
  count     = local.pg_enabled ? 1 : 0
  name      = "connection_throttle.enable"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_disconnections]
}

resource "azurerm_postgresql_flexible_server_configuration" "log_retention" {
  count     = local.pg_enabled ? 1 : 0
  name      = "logfiles.retention_days"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "7" # CIS: > 3 days

  depends_on = [azurerm_postgresql_flexible_server_configuration.connection_throttle]
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  for_each = local.pg_enabled ? toset(var.postgres_databases) : toset([])

  name      = each.value
  server_id = azurerm_postgresql_flexible_server.this[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_retention]
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  count = local.pg_enabled && local.pg_entra_admin ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = local.rg_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.postgres_entra_admin_object_id
  principal_name      = var.postgres_entra_admin_principal_name
  principal_type      = var.postgres_entra_admin_principal_type

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_retention]

  lifecycle {
    precondition {
      condition     = var.postgres_entra_admin_principal_name != null && var.postgres_entra_admin_principal_name != ""
      error_message = "postgres_entra_admin_principal_name (the group's display name) is required with postgres_entra_admin_object_id."
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "pg" {
  count = local.pg_enabled ? 1 : 0

  name                       = "to-log-analytics"
  target_resource_id         = azurerm_postgresql_flexible_server.this[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Offline tests: `terraform init -backend=false && terraform test`

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      name     = "RG-Shop-Prod"
      location = "eastus2"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Shop-Prod"
      tags     = { costCenter = "1234" }
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Shop-Prod/providers/Microsoft.Network/virtualNetworks/rg-shop-prod-vnet-aks/subnets/rg-shop-prod-snet-pe"
    }
  }

  mock_data "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Shop-Prod/providers/Microsoft.OperationalInsights/workspaces/rg-shop-prod-log"
    }
  }

  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Shop-Prod/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg"
    }
  }
}

mock_provider "random" {}

variables {
  resource_group_name          = "RG-Shop-Prod"
  app_name                     = "orders-api"
  postgres_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Shop-Prod/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
}

run "private_endpoint_only" {
  command = plan

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this.public_network_access_enabled == false &&
      azurerm_postgresql_flexible_server.this.delegated_subnet_id == null &&
      startswith(azurerm_postgresql_flexible_server.this.name, "rg-shop-prod-orders-api-pg-") &&
      length(azurerm_postgresql_flexible_server.this.name) <= 63
    )
    error_message = "Server must be private (no public access, no VNet injection) and follow the naming convention."
  }

  assert {
    condition = (
      data.azurerm_subnet.pe.name == "rg-shop-prod-snet-pe" &&
      data.azurerm_subnet.pe.virtual_network_name == "rg-shop-prod-vnet-aks" &&
      azurerm_private_endpoint.this.name == "rg-shop-prod-pe-orders-api-pg" &&
      azurerm_private_endpoint.this.private_service_connection[0].subresource_names == tolist(["postgresqlServer"]) &&
      tolist(azurerm_private_endpoint.this.private_dns_zone_group[0].private_dns_zone_ids)[0] == var.postgres_private_dns_zone_id
    )
    error_message = "The private endpoint must sit in the environment's PE subnet and register in the PostgreSQL private DNS zone."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server_configuration.this["require_secure_transport"].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.this["log_connections"].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.this["log_disconnections"].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.this["log_checkpoints"].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.this["connection_throttle.enable"].value == "on" &&
      tonumber(azurerm_postgresql_flexible_server_configuration.this["logfiles.retention_days"].value) > 3
    )
    error_message = "CIS server parameters must be set."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server_database.this.name == "orders_api" &&
      azurerm_postgresql_flexible_server.this.tags == tomap({ costCenter = "1234", app = "orders-api" }) &&
      length(azurerm_postgresql_flexible_server_active_directory_administrator.this) == 0
    )
    error_message = "Database name, tags or Entra admin default are wrong."
  }
}

run "long_names_fit" {
  command = plan

  variables {
    resource_group_name = "RG-Shop-Prod"
    app_name            = "a-very-long-application-name-of-40-chars"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.this.name) <= 63
    error_message = "Server name must stay within 63 characters."
  }
}

run "entra_admin_group" {
  command = plan

  variables {
    entra_admin_object_id      = "22222222-2222-2222-2222-222222222222"
    entra_admin_principal_name = "pg-admins"
  }

  assert {
    condition     = azurerm_postgresql_flexible_server_active_directory_administrator.this[0].principal_type == "Group"
    error_message = "Entra admin group must be configured when given."
  }
}

run "rejects_bad_app_name" {
  command = plan

  variables {
    app_name = "Orders_API"
  }

  expect_failures = [var.app_name]
}

run "rejects_non_postgres_zone" {
  command = plan

  variables {
    postgres_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  expect_failures = [var.postgres_private_dns_zone_id]
}

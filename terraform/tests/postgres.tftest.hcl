# Offline tests for the VNet-integrated PostgreSQL 16 flexible server (postgres.tf).

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      name     = "rg-shop-prod"
      location = "eastus2"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shop-prod"
      tags = {
        costCenter = "1234"
        env        = "prod"
      }
    }
  }

  mock_data "azurerm_virtual_network" {
    defaults = {
      name          = "rg-shop-prod-vnet-runner"
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shop-prod/providers/Microsoft.Network/virtualNetworks/rg-shop-prod-vnet-runner"
      address_space = ["10.2.0.0/26"]
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}


# Subscription holding central private DNS zones (provider alias "dns").
mock_provider "azurerm" {
  alias = "dns"

  mock_data "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/rg-dns-hub/providers/Microsoft.Network/privateDnsZones/central-zone"
    }
  }
}

variables {
  resource_group_name = "rg-shop-prod"
}

# AKS validates private_dns_zone_id as a real resource ID even at plan time.
override_resource {
  target          = azurerm_private_dns_zone.aks_api
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shop-prod/providers/Microsoft.Network/privateDnsZones/privatelink.eastus2.azmk8s.io"
  }
}


run "postgres_vnet_integration_defaults" {
  command = plan

  assert {
    condition = (
      azurerm_subnet.pg[0].name == "rg-shop-prod-snet-pg" &&
      azurerm_subnet.pg[0].address_prefixes[0] == "10.0.1.64/27" &&
      azurerm_subnet.pg[0].delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers" &&
      azurerm_subnet.pg[0].service_endpoint[0].service == "Microsoft.Storage" &&
      azurerm_subnet.pg[0].default_outbound_access_enabled == false
    )
    error_message = "PostgreSQL needs a delegated /27 next to the PE subnet, with the Storage service endpoint."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].version == "16" &&
      azurerm_postgresql_flexible_server.this[0].public_network_access_enabled == false &&
      azurerm_postgresql_flexible_server.this[0].sku_name == "B_Standard_B1ms" &&
      startswith(azurerm_postgresql_flexible_server.this[0].name, "rg-shop-prod-pg-") &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].active_directory_auth_enabled == true &&
      length(azurerm_postgresql_flexible_server.this[0].high_availability) == 0
    )
    error_message = "Server must be PostgreSQL 16, private only, Entra auth on, no HA by default."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.pg[0].name == "rg-shop-prod.private.postgres.database.azure.com" &&
      keys(azurerm_private_dns_zone_virtual_network_link.pg) == ["aks"]
    )
    error_message = "VNet-integrated servers need their own *.postgres.database.azure.com zone linked to the AKS vNet."
  }

  assert {
    condition = (
      azurerm_network_security_rule.pg["Allow-AKS-Nodes-PostgreSQL-Inbound"].source_address_prefix == "10.0.0.0/24" &&
      azurerm_network_security_rule.pg["Allow-AKS-Nodes-PostgreSQL-Inbound"].destination_port_range == "5432" &&
      azurerm_network_security_rule.pg["Allow-Subnet-PostgreSQL-Inbound"].source_address_prefix == "10.0.1.64/27" &&
      azurerm_network_security_rule.pg["Allow-Storage-Outbound"].destination_address_prefix == "Storage" &&
      azurerm_network_security_rule.pg["Deny-VirtualNetwork-Inbound"].access == "Deny" &&
      azurerm_network_security_rule.pg["Deny-Internet-Outbound"].access == "Deny" &&
      !contains(keys(azurerm_network_security_rule.pg), "Allow-Runner-PostgreSQL-Inbound")
    )
    error_message = "Database NSG must allow only nodes, the subnet itself, Storage and Entra ID."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server_configuration.require_secure_transport[0].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.log_checkpoints[0].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.log_connections[0].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.log_disconnections[0].value == "on" &&
      azurerm_postgresql_flexible_server_configuration.connection_throttle[0].value == "on" &&
      tonumber(azurerm_postgresql_flexible_server_configuration.log_retention[0].value) > 3 &&
      length(azurerm_monitor_diagnostic_setting.pg) == 1
    )
    error_message = "CIS server parameters and diagnostics must be configured."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.this[0].tags == tomap({ costCenter = "1234", env = "prod" })
    error_message = "Resource group tags must be copied."
  }
}

run "postgres_with_runner_ha_and_entra_admin" {
  command = plan

  variables {
    runner_vnet_name                    = "rg-shop-prod-vnet-runner"
    postgres_sku_name                   = "GP_Standard_D2ds_v5"
    postgres_high_availability          = true
    postgres_password_auth_enabled      = false
    postgres_entra_admin_object_id      = "22222222-2222-2222-2222-222222222222"
    postgres_entra_admin_principal_name = "pg-admins"
    postgres_databases                  = ["orders", "inventory"]
  }

  assert {
    condition = (
      toset(keys(azurerm_private_dns_zone_virtual_network_link.pg)) == toset(["aks", "runner"]) &&
      azurerm_network_security_rule.pg["Allow-Runner-PostgreSQL-Inbound"].source_address_prefix == "10.2.0.0/26"
    )
    error_message = "The private runner must resolve and reach the database (5432 only)."
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this[0].high_availability[0].mode == "ZoneRedundant" &&
      azurerm_postgresql_flexible_server.this[0].authentication[0].password_auth_enabled == false &&
      azurerm_postgresql_flexible_server_active_directory_administrator.this[0].principal_name == "pg-admins" &&
      toset(keys(azurerm_postgresql_flexible_server_database.this)) == toset(["orders", "inventory"])
    )
    error_message = "HA, Entra-only auth and databases must follow the inputs."
  }
}

run "postgres_disabled" {
  command = plan

  variables {
    postgres_enabled = false
  }

  assert {
    condition = (
      length(azurerm_subnet.pg) == 0 &&
      length(azurerm_postgresql_flexible_server.this) == 0 &&
      length(azurerm_private_dns_zone.pg) == 0 &&
      length(azurerm_network_security_rule.pg) == 0
    )
    error_message = "Nothing PostgreSQL-related may be created when disabled."
  }
}

run "rejects_ha_on_burstable" {
  command = plan

  variables {
    postgres_high_availability = true
  }

  expect_failures = [azurerm_postgresql_flexible_server.this]
}

run "rejects_no_way_to_log_in" {
  command = plan

  variables {
    postgres_password_auth_enabled = false
  }

  expect_failures = [azurerm_postgresql_flexible_server.this]
}

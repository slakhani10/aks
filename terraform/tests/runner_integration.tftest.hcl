# Offline tests for the optional private GitHub runner connectivity (runner_vnet_name).

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

run "no_runner_by_default" {
  command = plan

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.private_dns_zone_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shop-prod/providers/Microsoft.Network/privateDnsZones/privatelink.eastus2.azmk8s.io" &&
      azurerm_private_dns_zone.aks_api.name == "privatelink.eastus2.azmk8s.io" &&
      azurerm_private_dns_zone_virtual_network_link.aks_api.name == "rg-shop-prod-vnet-aks-link"
    )
    error_message = "The private API server must use the resource-group-level private DNS zone, linked to the AKS vNet."
  }

  assert {
    condition     = length(azurerm_virtual_network_peering.aks_to_runner) == 0 && length(azurerm_private_dns_zone_virtual_network_link.aks_api_runner) == 0
    error_message = "Nothing runner-related should be created without runner_vnet_name."
  }

  assert {
    condition     = !contains(keys(azurerm_network_security_rule.aks), "Allow-Runner-HTTPS-Inbound")
    error_message = "No runner NSG rule without runner_vnet_name."
  }
}

run "runner_connected" {
  command = plan

  variables {
    runner_vnet_name = "rg-shop-prod-vnet-runner"
  }

  assert {
    condition = (
      length(azurerm_virtual_network_peering.aks_to_runner) == 1 &&
      azurerm_virtual_network_peering.runner_to_aks[0].virtual_network_name == "rg-shop-prod-vnet-runner" &&
      azurerm_virtual_network_peering.runner_to_aks[0].allow_forwarded_traffic == false
    )
    error_message = "AKS and runner vNets must be peered both ways without forwarded traffic."
  }

  assert {
    condition = (
      azurerm_network_security_rule.aks["Allow-Runner-HTTPS-Inbound"].source_address_prefix == "10.2.0.0/26" &&
      azurerm_network_security_rule.aks["Allow-Runner-HTTPS-Inbound"].destination_port_range == "443" &&
      azurerm_network_security_rule.aks["Deny-Runner-Other-Inbound"].access == "Deny"
    )
    error_message = "Runner may only reach the AKS vNet on TCP 443."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.aks_api_runner[0].private_dns_zone_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shop-prod/providers/Microsoft.Network/privateDnsZones/privatelink.eastus2.azmk8s.io"
    error_message = "The AKS private API DNS zone must be linked to the runner vNet."
  }

  assert {
    condition     = contains(keys(azurerm_private_dns_zone_virtual_network_link.kv), "runner")
    error_message = "The Key Vault private DNS zone must be linked to the runner vNet."
  }
}

run "rejects_runner_overlapping_aks" {
  command = plan

  variables {
    runner_vnet_name = "rg-shop-prod-vnet-runner"
    aks_vnet_cidr    = "10.2.0.0/22"
  }

  expect_failures = [azurerm_virtual_network.aks]
}

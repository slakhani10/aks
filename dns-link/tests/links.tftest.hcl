# Offline tests: `terraform init -backend=false && terraform test`

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      name     = "aks-rg"
      location = "northcentralus"
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/aks-rg"
      tags     = { env = "prod" }
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      name = "aks-rg-vnet-aks"
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/aks-rg/providers/Microsoft.Network/virtualNetworks/aks-rg-vnet-aks"
    }
  }
}

mock_provider "azurerm" {
  alias = "dns"
  mock_data "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/rg-dns-hub/providers/Microsoft.Network/privateDnsZones/zone"
    }
  }
}

variables {
  resource_group_name          = "aks-rg"
  dns_zone_subscription_id     = "99999999-9999-9999-9999-999999999999"
  dns_zone_resource_group_name = "rg-dns-hub"
}

run "without_runner" {
  command = plan

  assert {
    condition     = keys(azurerm_private_dns_zone_virtual_network_link.this) == ["kv/aks"]
    error_message = "Only the AKS vNet -> Key Vault zone link is expected (AKS links its own vNet to the API zone)."
  }

  assert {
    condition = (
      data.azurerm_private_dns_zone.kv.name == "privatelink.vaultcore.azure.net" &&
      data.azurerm_private_dns_zone.aks_api.name == "privatelink.northcentralus.azmk8s.io" &&
      data.azurerm_private_dns_zone.aks_api.resource_group_name == "rg-dns-hub"
    )
    error_message = "Zones must be looked up by name in the DNS resource group."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.this["kv/aks"].registration_enabled == false
    error_message = "Auto-registration must stay off."
  }
}

run "with_runner" {
  command = plan

  variables {
    runner_vnet_name = "aks-rg-vnet-runner"
  }

  assert {
    condition     = toset(keys(azurerm_private_dns_zone_virtual_network_link.this)) == toset(["kv/aks", "kv/runner", "aks_api/runner"])
    error_message = "Runner vNet must be linked to both zones."
  }
}

run "rejects_zone_for_another_region" {
  command = plan

  variables {
    aks_private_dns_zone_name = "privatelink.westeurope.azmk8s.io"
  }

  expect_failures = [data.azurerm_private_dns_zone.aks_api]
}

run "rejects_subscription_name" {
  command = plan

  variables {
    dns_zone_subscription_id = "Hub Subscription"
  }

  expect_failures = [var.dns_zone_subscription_id]
}

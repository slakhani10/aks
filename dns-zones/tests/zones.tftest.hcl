# Offline tests: `terraform init -backend=false && terraform test`

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      name     = "rg-dns-hub"
      location = "northcentralus"
      id       = "/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/rg-dns-hub"
      tags     = { costCenter = "shared" }
    }
  }
}

variables {
  resource_group_name = "rg-dns-hub"
}

run "zones_default_to_resource_group_region" {
  command = plan

  assert {
    condition = (
      azurerm_private_dns_zone.this["key_vault"].name == "privatelink.vaultcore.azure.net" &&
      azurerm_private_dns_zone.this["aks_api"].name == "privatelink.northcentralus.azmk8s.io" &&
      azurerm_private_dns_zone.this["aks_api"].resource_group_name == "rg-dns-hub"
    )
    error_message = "Unexpected zone names or resource group."
  }

  assert {
    condition     = azurerm_private_dns_zone.this["aks_api"].tags == tomap({ costCenter = "shared" })
    error_message = "Resource group tags must be copied."
  }
}

run "explicit_aks_region" {
  command = plan

  variables {
    aks_region = "eastus2"
  }

  assert {
    condition     = azurerm_private_dns_zone.this["aks_api"].name == "privatelink.eastus2.azmk8s.io"
    error_message = "aks_region must drive the API server zone name."
  }
}

run "rejects_display_style_region" {
  command = plan

  variables {
    aks_region = "North Central US"
  }

  expect_failures = [var.aks_region]
}

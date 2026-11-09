# Offline tests (no Azure access needed): `terraform init -backend=false && terraform test`
# The azurerm provider is mocked, so these only exercise plan-time logic:
# CIDR derivation, overlap detection, input validation and tag propagation.

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

run "default_cidrs" {
  command = plan

  assert {
    condition     = azurerm_virtual_network.aks.address_space == toset(["10.0.0.0/22"]) && azurerm_virtual_network.agw.address_space == toset(["10.1.0.0/24"])
    error_message = "Unexpected default vNet address spaces."
  }

  assert {
    condition = (
      azurerm_subnet.aks["nodes"].address_prefixes[0] == "10.0.0.0/24" &&
      azurerm_subnet.aks["ingress"].address_prefixes[0] == "10.0.1.0/28" &&
      azurerm_subnet.aks["pe"].address_prefixes[0] == "10.0.1.16/28" &&
      azurerm_subnet.agw.address_prefixes[0] == "10.1.0.0/25"
    )
    error_message = "Default subnets were not derived as documented."
  }

  assert {
    condition     = output.ingress_private_ip == "10.0.1.4"
    error_message = "Ingress IP should be the first usable Azure address of the ingress subnet."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.16.0.10"
    error_message = "DNS service IP should be the 10th address of service_cidr."
  }
}

run "custom_cidrs" {
  command = plan

  variables {
    aks_vnet_cidr = "192.168.0.0/23"
    agw_vnet_cidr = "192.168.8.0/25"
    pod_cidr      = "100.64.0.0/16"
    service_cidr  = "172.20.0.0/20"
  }

  assert {
    condition = (
      azurerm_subnet.aks["nodes"].address_prefixes[0] == "192.168.0.0/24" &&
      azurerm_subnet.aks["ingress"].address_prefixes[0] == "192.168.1.0/28" &&
      azurerm_subnet.aks["pe"].address_prefixes[0] == "192.168.1.16/28" &&
      azurerm_subnet.agw.address_prefixes[0] == "192.168.8.0/25"
    )
    error_message = "Subnets were not derived from the custom vNet CIDRs."
  }

  assert {
    condition     = output.ingress_private_ip == "192.168.1.4"
    error_message = "Ingress IP did not follow the custom AKS vNet CIDR."
  }

  assert {
    condition     = flatten([for p in azurerm_application_gateway.this.backend_address_pool : tolist(p.ip_addresses)]) == ["192.168.1.4"]
    error_message = "App Gateway backend must target the derived ingress IP."
  }

  assert {
    condition     = azurerm_network_security_rule.aks["Allow-AppGateway-HTTP-HTTPS-Inbound"].source_address_prefix == "192.168.8.0/25"
    error_message = "AKS NSG must only allow the derived App Gateway subnet."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.network_profile[0].pod_cidr == "100.64.0.0/16" &&
      azurerm_kubernetes_cluster.this.network_profile[0].service_cidr == "172.20.0.0/20" &&
      azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.20.0.10"
    )
    error_message = "Pod/service ranges were not passed to the cluster."
  }
}

run "rejects_overlapping_vnets" {
  command = plan

  variables {
    aks_vnet_cidr = "10.0.0.0/22"
    agw_vnet_cidr = "10.0.2.0/24"
  }

  expect_failures = [azurerm_virtual_network.aks]
}

run "rejects_pod_cidr_overlapping_vnet" {
  command = plan

  variables {
    pod_cidr = "10.0.0.0/16"
  }

  expect_failures = [azurerm_virtual_network.aks]
}

run "rejects_too_small_aks_vnet" {
  command = plan

  variables {
    aks_vnet_cidr = "10.0.0.0/24"
  }

  expect_failures = [var.aks_vnet_cidr]
}

run "rejects_misaligned_cidr" {
  command = plan

  variables {
    agw_vnet_cidr = "10.1.0.5/24"
  }

  expect_failures = [var.agw_vnet_cidr]
}

run "copies_resource_group_tags" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_virtual_network.aks.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster.this.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster.this.default_node_pool[0].tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster_node_pool.user.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_application_gateway.this.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_key_vault.this.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_network_security_group.aks.tags == tomap({ costCenter = "1234", env = "prod" }),
    ])
    error_message = "Resource group tags must be copied verbatim to resources."
  }
}

run "additional_tags_do_not_override_rg_tags" {
  command = plan

  variables {
    additional_tags = {
      env   = "should-be-overridden"
      owner = "platform-team"
    }
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.tags == tomap({ costCenter = "1234", env = "prod", owner = "platform-team" })
    error_message = "additional_tags should be merged, with resource group tags taking precedence."
  }
}

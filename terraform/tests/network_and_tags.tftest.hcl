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

run "default_cidrs" {
  command = plan

  assert {
    condition     = azurerm_virtual_network.aks.address_space == toset(["10.0.0.0/22"])
    error_message = "Unexpected default vNet address space."
  }

  assert {
    condition = (
      azurerm_subnet.aks["nodes"].address_prefixes[0] == "10.0.0.0/24" &&
      azurerm_subnet.aks["pe"].address_prefixes[0] == "10.0.1.16/28" &&
      azurerm_subnet.agc.address_prefixes[0] == "10.0.2.0/24"
    )
    error_message = "Default subnets were not derived as documented."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].dns_service_ip == "172.16.0.10"
    error_message = "DNS service IP should be the 10th address of service_cidr."
  }
}

run "agc_with_waf" {
  command = plan

  assert {
    condition = (
      azurerm_subnet.agc.delegation[0].service_delegation[0].name == "Microsoft.ServiceNetworking/trafficControllers" &&
      azurerm_application_load_balancer.this.name == "rg-shop-prod-agc" &&
      azurerm_application_load_balancer_frontend.this.name == "rg-shop-prod-agc-fe" &&
      azurerm_application_load_balancer_subnet_association.this.name == "rg-shop-prod-agc-assoc"
    )
    error_message = "App Gateway for Containers must be associated with a subnet delegated to trafficControllers."
  }

  assert {
    condition = (
      azurerm_web_application_firewall_policy.this.policy_settings[0].mode == "Prevention" &&
      azurerm_web_application_firewall_policy.this.policy_settings[0].enabled &&
      contains([for r in azurerm_web_application_firewall_policy.this.managed_rules[0].managed_rule_set : "${r.type}/${r.version}"], "Microsoft_DefaultRuleSet/2.1")
    )
    error_message = "WAF must be enabled in Prevention mode with DRS 2.1 (the rule set AGfC supports)."
  }

  assert {
    condition     = azurerm_federated_identity_credential.alb.subject == "system:serviceaccount:azure-alb-system:alb-controller-sa"
    error_message = "ALB Controller workload identity must be bound to its service account only."
  }

  assert {
    condition = (
      azurerm_role_assignment.alb_config_manager.role_definition_name == "AppGw for Containers Configuration Manager" &&
      azurerm_role_assignment.alb_subnet_join.role_definition_name == "Network Contributor"
    )
    error_message = "ALB Controller must get only the two documented roles."
  }

  assert {
    condition = (
      azurerm_network_security_rule.agc["Allow-Internet-HTTP-HTTPS-Inbound"].destination_port_ranges == toset(["80", "443"]) &&
      azurerm_network_security_rule.agc["Allow-AzureLoadBalancer-Inbound"].source_address_prefix == "AzureLoadBalancer" &&
      azurerm_network_security_rule.agc["Deny-All-Inbound"].access == "Deny"
    )
    error_message = "AGfC subnet NSG must allow only 80/443 from the Internet plus AzureLoadBalancer."
  }
}

run "custom_cidrs" {
  command = plan

  variables {
    aks_vnet_cidr = "192.168.0.0/22"
    pod_cidr      = "100.64.0.0/16"
    service_cidr  = "172.20.0.0/20"
  }

  assert {
    condition = (
      azurerm_subnet.aks["nodes"].address_prefixes[0] == "192.168.0.0/24" &&
      azurerm_subnet.aks["pe"].address_prefixes[0] == "192.168.1.16/28" &&
      azurerm_subnet.agc.address_prefixes[0] == "192.168.2.0/24"
    )
    error_message = "Subnets were not derived from the custom vNet CIDR."
  }

  assert {
    condition = (
      azurerm_network_security_rule.aks["Allow-AGC-To-Pods-Inbound"].source_address_prefix == "192.168.2.0/24" &&
      azurerm_network_security_rule.aks["Allow-AGC-To-Pods-Inbound"].destination_address_prefix == "100.64.0.0/16" &&
      azurerm_network_security_rule.aks["Deny-AGC-Other-Inbound"].source_address_prefix == "192.168.2.0/24" &&
      azurerm_network_security_rule.agc["Allow-To-Pods-Outbound"].destination_address_prefix == "100.64.0.0/16"
    )
    error_message = "NSGs must follow the derived AGfC subnet and the custom pod range."
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

run "rejects_service_cidr_overlapping_vnet" {
  command = plan

  variables {
    service_cidr = "10.0.0.0/16"
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
    aks_vnet_cidr = "10.0.0.0/23"
  }

  expect_failures = [var.aks_vnet_cidr]
}

run "rejects_misaligned_cidr" {
  command = plan

  variables {
    aks_vnet_cidr = "10.0.1.0/22"
  }

  expect_failures = [var.aks_vnet_cidr]
}

run "copies_resource_group_tags" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_virtual_network.aks.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster.this.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster.this.default_node_pool[0].tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_kubernetes_cluster_node_pool.user.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_application_load_balancer.this.tags == tomap({ costCenter = "1234", env = "prod" }),
      azurerm_web_application_firewall_policy.this.tags == tomap({ costCenter = "1234", env = "prod" }),
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

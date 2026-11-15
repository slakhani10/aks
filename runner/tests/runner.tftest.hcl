# Offline tests (no Azure access needed): `terraform init -backend=false && terraform test`

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
}

mock_provider "tls" {}

variables {
  resource_group_name = "rg-shop-prod"
}

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_virtual_network.runner.name == "rg-shop-prod-vnet-runner" && azurerm_virtual_network.runner.address_space == toset(["10.2.0.0/26"])
    error_message = "Unexpected runner vNet name or range."
  }

  assert {
    condition     = azurerm_subnet.runner.address_prefixes[0] == "10.2.0.0/28" && azurerm_subnet.runner.default_outbound_access_enabled == false
    error_message = "Runner subnet must be the first /28 with default outbound access disabled."
  }

  assert {
    condition     = keys(azurerm_linux_virtual_machine.runner) == ["rg-shop-prod-runner-01"]
    error_message = "Expected exactly one runner VM by default."
  }

  assert {
    condition     = output.runner_labels == "self-hosted,linux,x64,aks-runner,rg-shop-prod"
    error_message = "Runner labels must include the resource group so the AKS workflow can target it."
  }
}

run "vm_is_private_and_hardened" {
  command = plan

  variables {
    runner_count = 2
  }

  assert {
    condition     = keys(azurerm_linux_virtual_machine.runner) == ["rg-shop-prod-runner-01", "rg-shop-prod-runner-02"]
    error_message = "runner_count should create sequentially named VMs."
  }

  assert {
    condition = alltrue([for nic in azurerm_network_interface.runner :
      alltrue([for ip in nic.ip_configuration : ip.public_ip_address_id == null])
    ])
    error_message = "Runner NICs must not have public IPs."
  }

  assert {
    condition = alltrue([for vm in azurerm_linux_virtual_machine.runner :
      vm.disable_password_authentication && vm.secure_boot_enabled && vm.vtpm_enabled &&
      vm.encryption_at_host_enabled && vm.patch_mode == "AutomaticByPlatform"
    ])
    error_message = "Runner VMs must use Trusted Launch, encryption at host, platform patching and no password login."
  }

  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.runner : vm.tags == tomap({ costCenter = "1234", env = "prod" })])
    error_message = "Resource group tags must be copied to the VMs."
  }
}

run "nsg_denies_inbound_and_limits_egress" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.runner["Deny-All-Inbound"].direction == "Inbound" &&
      azurerm_network_security_rule.runner["Deny-All-Inbound"].access == "Deny" &&
      azurerm_network_security_rule.runner["Deny-All-Inbound"].source_address_prefix == "*"
    )
    error_message = "All inbound traffic to the runner subnet must be denied."
  }

  assert {
    condition     = length([for r in azurerm_network_security_rule.runner : r if r.direction == "Inbound" && r.access == "Allow"]) == 0
    error_message = "There must be no inbound allow rules."
  }

  assert {
    condition = (
      azurerm_network_security_rule.runner["Deny-Internet-Outbound"].access == "Deny" &&
      azurerm_network_security_rule.runner["Deny-Internet-Outbound"].destination_address_prefix == "Internet" &&
      azurerm_network_security_rule.runner["Allow-Internet-HTTPS"].destination_port_range == "443"
    )
    error_message = "Egress must be limited to the rules in config/runner-egress-rules.json."
  }

  assert {
    condition     = alltrue([for r in azurerm_network_security_rule.runner : length(r.description) <= 140])
    error_message = "NSG rule descriptions must be 140 characters or less (Azure limit)."
  }
}

run "rejects_too_small_vnet" {
  command = plan

  variables {
    runner_vnet_cidr = "10.2.0.0/29"
  }

  expect_failures = [var.runner_vnet_cidr]
}

run "rejects_too_many_runners" {
  command = plan

  variables {
    runner_count = 12
  }

  expect_failures = [var.runner_count]
}

# =============================================================================
# Private GitHub Actions self-hosted runner(s) for the secure AKS environment.
#
# Deploys into the EXISTING resource group used by the AKS environment, with the
# same naming convention (<rg>-...). The runner has:
#   * no public IP and no inbound access (NSG denies all inbound)
#   * outbound-only connectivity through a NAT Gateway, filtered by the NSG rules
#     in config/runner-egress-rules.json
#   * Trusted Launch (secure boot + vTPM), optional encryption at host,
#     platform-managed OS patching, SSH password login disabled
#
# The AKS Terraform peers this vNet (runner_vnet_name) so jobs on this runner can
# reach the private AKS API server and the private Key Vault.
# =============================================================================

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  prefix   = lower(data.azurerm_resource_group.this.name)
  location = data.azurerm_resource_group.this.location
  rg_name  = data.azurerm_resource_group.this.name

  # Resource group tags are copied to every resource; RG values win on conflicts.
  tags = merge(var.additional_tags, data.azurerm_resource_group.this.tags)

  vnet_bits          = tonumber(split("/", var.runner_vnet_cidr)[1])
  runner_subnet_cidr = cidrsubnet(var.runner_vnet_cidr, 28 - local.vnet_bits, 0) # 1st /28

  runner_names = [for i in range(var.runner_count) : format("%s-runner-%02d", local.prefix, i + 1)]

  # Labels the workflow registers the runners with. The AKS workflow targets
  # [self-hosted, <resource group>] so each environment uses its own runner(s).
  runner_labels = ["self-hosted", "linux", "x64", "aks-runner", local.prefix]

  egress_rules = jsondecode(file("${path.module}/config/runner-egress-rules.json"))
}

# ------------------------------------------------------------------- Network --
resource "azurerm_network_security_group" "runner" {
  name                = "${local.prefix}-nsg-runner"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

locals {
  runner_nsg_rules = merge(
    {
      "Deny-All-Inbound" = {
        description                = "Runners only make outbound connections; nothing may connect in (no SSH, no RDP)."
        priority                   = 4096
        direction                  = "Inbound"
        access                     = "Deny"
        protocol                   = "*"
        destination_address_prefix = "*"
        destination_port_ranges    = ["*"]
      }
    },
    {
      for r in local.egress_rules : r.name => {
        description                = try(r.description, "")
        priority                   = r.priority
        direction                  = "Outbound"
        access                     = r.access
        protocol                   = r.protocol
        destination_address_prefix = r.destinationAddressPrefix
        destination_port_ranges    = r.destinationPortRanges
      }
    }
  )
}

resource "azurerm_network_security_rule" "runner" {
  for_each = local.runner_nsg_rules

  name                        = each.key
  description                 = each.value.description
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = each.value.destination_address_prefix
  destination_port_range      = length(each.value.destination_port_ranges) == 1 ? each.value.destination_port_ranges[0] : null
  destination_port_ranges     = length(each.value.destination_port_ranges) > 1 ? each.value.destination_port_ranges : null
  resource_group_name         = local.rg_name
  network_security_group_name = azurerm_network_security_group.runner.name
}

resource "azurerm_public_ip" "natgw" {
  name                = "${local.prefix}-pip-natgw-runner"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "runner" {
  name                    = "${local.prefix}-natgw-runner"
  location                = local.location
  resource_group_name     = local.rg_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "runner" {
  nat_gateway_id       = azurerm_nat_gateway.runner.id
  public_ip_address_id = azurerm_public_ip.natgw.id
}

resource "azurerm_virtual_network" "runner" {
  name                = "${local.prefix}-vnet-runner"
  location            = local.location
  resource_group_name = local.rg_name
  address_space       = [var.runner_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "runner" {
  name                            = "${local.prefix}-snet-runner"
  resource_group_name             = local.rg_name
  virtual_network_name            = azurerm_virtual_network.runner.name
  address_prefixes                = [local.runner_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

resource "azurerm_subnet_nat_gateway_association" "runner" {
  subnet_id      = azurerm_subnet.runner.id
  nat_gateway_id = azurerm_nat_gateway.runner.id
}

# ---------------------------------------------------------------- Runner VMs --
# An SSH public key is mandatory for Linux VMs with password login disabled. The
# matching private key is never output; interactive access is not part of the
# design (no inbound rules). For break-glass use `az vm run-command invoke` or the
# serial console.
resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_interface" "runner" {
  for_each = toset(local.runner_names)

  name                = "${each.key}-nic"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
    # no public_ip_address_id: the runner is never reachable from the Internet
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  for_each = toset(local.runner_names)

  name                  = each.key
  computer_name         = each.key
  location              = local.location
  resource_group_name   = local.rg_name
  size                  = var.runner_vm_size
  network_interface_ids = [azurerm_network_interface.runner[each.key].id]
  tags                  = local.tags

  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.admin.public_key_openssh
  }

  # Trusted Launch + host encryption (CIS 7.x)
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = var.enable_encryption_at_host

  # Platform-managed OS patching
  provision_vm_agent    = true
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    runner_version = var.runner_version
  }))

  os_disk {
    name                 = "${each.key}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {} # managed storage account

  depends_on = [
    azurerm_subnet_nat_gateway_association.runner,
    azurerm_subnet_network_security_group_association.runner,
    azurerm_nat_gateway_public_ip_association.runner,
  ]

  lifecycle {
    # Changing cloud-init or the runner version must not silently rebuild a
    # registered runner. Taint/replace explicitly if you want a fresh VM.
    ignore_changes = [custom_data]
  }
}

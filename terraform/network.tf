# -----------------------------------------------------------------------------
# Networking: one AKS vNet with separate, NSG-protected subnets
#   * nodes  - AKS node pools (CNI Overlay: pods use pod_cidr, not vNet IPs)
#   * pe     - private endpoints (Key Vault)
#   * agc    - Application Gateway for Containers association subnet (/24, delegated)
#
# Application Gateway for Containers must share the cluster's vNet: with Azure CNI
# Overlay, Microsoft does not support it in a separate (peered) vNet in the same
# region. Isolation is enforced per subnet with NSGs and in-cluster with Cilium
# network policy. AKS egress goes through a NAT Gateway and is filtered by the NSG
# egress rules in config/aks-egress-rules.json.
# -----------------------------------------------------------------------------

# ------------------------------------------------ Optional private runner --
data "azurerm_virtual_network" "runner" {
  count = local.runner_enabled ? 1 : 0

  name                = var.runner_vnet_name
  resource_group_name = local.rg_name
}

locals {
  runner_enabled     = var.runner_vnet_name != null && var.runner_vnet_name != ""
  runner_vnet_ranges = local.runner_enabled ? data.azurerm_virtual_network.runner[0].address_space : []

  # --------------------------------------------- Subnets derived from inputs --
  aks_vnet_bits = tonumber(split("/", var.aks_vnet_cidr)[1])

  aks_node_subnet_cidr = cidrsubnet(var.aks_vnet_cidr, 24 - local.aks_vnet_bits, 0)  # 1st /24
  aks_pe_subnet_cidr   = cidrsubnet(var.aks_vnet_cidr, 28 - local.aks_vnet_bits, 17) # 2nd /28 of the 2nd /24
  agc_subnet_cidr      = cidrsubnet(var.aks_vnet_cidr, 24 - local.aks_vnet_bits, 2)  # 3rd /24 (AGfC needs exactly /24)

  dns_service_ip = cidrhost(var.service_cidr, 10)

  # ------------------------------------------------- Overlap detection --------
  # [first, last] address of each range as integers.
  cidr_ranges = {
    for name, cidr in merge({
      aks_vnet = var.aks_vnet_cidr
      pod      = var.pod_cidr
      service  = var.service_cidr
      }, { for i, c in local.runner_vnet_ranges : "runner_vnet_${i}" => c }) : name => {
      cidr  = cidr
      first = sum([for i, o in split(".", cidrhost(cidr, 0)) : tonumber(o) * pow(256, 3 - i)])
      size  = pow(2, 32 - tonumber(split("/", cidr)[1]))
    }
  }

  cidr_names = keys(local.cidr_ranges)
  cidr_overlaps = [
    for pair in setproduct(range(length(local.cidr_names)), range(length(local.cidr_names))) :
    "${local.cidr_names[pair[0]]} (${local.cidr_ranges[local.cidr_names[pair[0]]].cidr}) overlaps ${local.cidr_names[pair[1]]} (${local.cidr_ranges[local.cidr_names[pair[1]]].cidr})"
    if pair[0] < pair[1] &&
    local.cidr_ranges[local.cidr_names[pair[0]]].first < local.cidr_ranges[local.cidr_names[pair[1]]].first + local.cidr_ranges[local.cidr_names[pair[1]]].size &&
    local.cidr_ranges[local.cidr_names[pair[1]]].first < local.cidr_ranges[local.cidr_names[pair[0]]].first + local.cidr_ranges[local.cidr_names[pair[0]]].size
  ]

  # ------------------------------------------------- NSG: AKS subnets ---------
  aks_inbound_rules = {
    "Allow-AGC-To-Pods-Inbound" = {
      description                = "App Gateway for Containers proxies directly to pod IPs (overlay) and runs health probes."
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.agc_subnet_cidr
      destination_address_prefix = var.pod_cidr
      destination_port_ranges    = ["*"]
    }
    "Deny-AGC-Other-Inbound" = {
      description                = "Block any other traffic from the App Gateway for Containers subnet (e.g. to nodes or endpoints)."
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = local.agc_subnet_cidr
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Deny-Internet-Inbound" = {
      description                = "No direct Internet ingress to AKS. All user traffic must traverse the App Gateway for Containers WAF."
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "Internet"
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
  }

  runner_inbound_rules = local.runner_enabled ? {
    "Allow-Runner-HTTPS-Inbound" = {
      description                = "Private GitHub runner: TCP 443 only (private AKS API server, Key Vault private endpoint)."
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.runner_vnet_ranges[0]
      destination_address_prefix = var.aks_vnet_cidr
      destination_port_ranges    = ["443"]
    }
    "Deny-Runner-Other-Inbound" = {
      description                = "Block any other traffic from the peered runner vNet."
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = local.runner_vnet_ranges[0]
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
  } : {}

  aks_outbound_rules = {
    for r in local.egress_rules : r.name => {
      description                = try(r.description, "")
      priority                   = r.priority
      direction                  = "Outbound"
      access                     = r.access
      protocol                   = r.protocol
      source_address_prefix      = "*"
      destination_address_prefix = r.destinationAddressPrefix
      destination_port_ranges    = r.destinationPortRanges
    }
  }

  aks_nsg_rules = merge(local.aks_inbound_rules, local.runner_inbound_rules, local.aks_outbound_rules)

  aks_subnets = {
    nodes = {
      name   = "${local.prefix}-snet-aks-nodes"
      prefix = local.aks_node_subnet_cidr
    }
    pe = {
      name   = "${local.prefix}-snet-pe"
      prefix = local.aks_pe_subnet_cidr
    }
  }

  # ------------------------------------- NSG: App Gateway for Containers ------
  # https://learn.microsoft.com/azure/application-gateway/for-containers/application-gateway-for-containers-components#network-security-groups-on-the-association-subnet
  agc_nsg_rules = {
    "Allow-Internet-HTTP-HTTPS-Inbound" = {
      description                = "Client traffic to the App Gateway for Containers frontend (listeners only support 80/443)."
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "Internet"
      destination_address_prefix = "*"
      destination_port_ranges    = ["80", "443"]
    }
    "Allow-AzureLoadBalancer-Inbound" = {
      description                = "Required for App Gateway for Containers operation."
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_address_prefix      = "AzureLoadBalancer"
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Deny-All-Inbound" = {
      description                = "Nothing else may reach the App Gateway for Containers subnet."
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Allow-To-Pods-Outbound" = {
      description                = "Proxy and health-probe traffic to backend pods (overlay pod range)."
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "*"
      destination_address_prefix = var.pod_cidr
      destination_port_ranges    = ["*"]
    }
  }
}

# ---------------------------------------------------------------- NSG: AKS --
resource "azurerm_network_security_group" "aks" {
  name                = "${local.prefix}-nsg-aks"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "aks" {
  for_each = local.aks_nsg_rules

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
  network_security_group_name = azurerm_network_security_group.aks.name
}

# ------------------------------------- NSG: App Gateway for Containers ------
resource "azurerm_network_security_group" "agc" {
  name                = "${local.prefix}-nsg-agc"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "agc" {
  for_each = local.agc_nsg_rules

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
  network_security_group_name = azurerm_network_security_group.agc.name
}

# ------------------------------------------------------- NAT Gateway ---------
# Deterministic, outbound-only egress for AKS. No public load balancer is created.
resource "azurerm_public_ip" "natgw" {
  name                = "${local.prefix}-pip-natgw"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${local.prefix}-natgw"
  location                = local.location
  resource_group_name     = local.rg_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.natgw.id
}

# -------------------------------------------------------------- vNet --------
resource "azurerm_virtual_network" "aks" {
  name                = "${local.prefix}-vnet-aks"
  location            = local.location
  resource_group_name = local.rg_name
  address_space       = [var.aks_vnet_cidr]
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = length(local.cidr_overlaps) == 0
      error_message = "Address ranges must not overlap: ${join("; ", local.cidr_overlaps)}"
    }
  }
}

resource "azurerm_subnet" "aks" {
  for_each = local.aks_subnets

  name                              = each.value.name
  resource_group_name               = local.rg_name
  virtual_network_name              = azurerm_virtual_network.aks.name
  address_prefixes                  = [each.value.prefix]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  for_each = azurerm_subnet.aks

  subnet_id                 = each.value.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_nat_gateway_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks["nodes"].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet" "agc" {
  name                 = "${local.prefix}-snet-agc"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.agc_subnet_cidr]

  delegation {
    name = "trafficControllers"
    service_delegation {
      name    = "Microsoft.ServiceNetworking/trafficControllers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# The NSG must exist before the association is created: associations created after
# April 2026 enforce NSG rules fully, including on ports 80/443.
resource "azurerm_subnet_network_security_group_association" "agc" {
  subnet_id                 = azurerm_subnet.agc.id
  network_security_group_id = azurerm_network_security_group.agc.id

  depends_on = [azurerm_network_security_rule.agc]
}

# ------------------------------------------------------------ Peering -------
resource "azurerm_virtual_network_peering" "aks_to_runner" {
  count = local.runner_enabled ? 1 : 0

  name                         = "peer-to-${var.runner_vnet_name}"
  resource_group_name          = local.rg_name
  virtual_network_name         = azurerm_virtual_network.aks.name
  remote_virtual_network_id    = data.azurerm_virtual_network.runner[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "runner_to_aks" {
  count = local.runner_enabled ? 1 : 0

  name                         = "peer-to-${azurerm_virtual_network.aks.name}"
  resource_group_name          = local.rg_name
  virtual_network_name         = var.runner_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.aks.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# ------------------------------------------------------ Diagnostics ---------
resource "azurerm_monitor_diagnostic_setting" "nsg" {
  for_each = {
    aks = azurerm_network_security_group.aks.id
    agc = azurerm_network_security_group.agc.id
  }

  name                       = "to-log-analytics"
  target_resource_id         = each.value
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "natgw_pip" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_public_ip.natgw.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

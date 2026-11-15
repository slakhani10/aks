# -----------------------------------------------------------------------------
# Networking: two separate, peered virtual networks
#   * AKS vNet         -> node subnet, internal-ingress subnet, private-endpoint subnet
#   * App Gateway vNet -> dedicated Application Gateway (WAF_v2) subnet
# Every subnet has an NSG (CIS 6.x). AKS egress goes through a NAT Gateway and is
# filtered by the NSG egress rules in config/aks-egress-rules.json.
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
  agw_vnet_bits = tonumber(split("/", var.agw_vnet_cidr)[1])

  aks_node_subnet_cidr    = cidrsubnet(var.aks_vnet_cidr, 24 - local.aks_vnet_bits, 0)  # 1st /24
  aks_ingress_subnet_cidr = cidrsubnet(var.aks_vnet_cidr, 28 - local.aks_vnet_bits, 16) # /28 at start of 2nd /24
  aks_pe_subnet_cidr      = cidrsubnet(var.aks_vnet_cidr, 28 - local.aks_vnet_bits, 17) # next /28
  agw_subnet_cidr         = cidrsubnet(var.agw_vnet_cidr, 25 - local.agw_vnet_bits, 0)  # 1st /25

  dns_service_ip = cidrhost(var.service_cidr, 10)

  # ------------------------------------------------- Overlap detection --------
  # [first, last] address of each range as integers.
  cidr_ranges = {
    for name, cidr in merge({
      aks_vnet = var.aks_vnet_cidr
      agw_vnet = var.agw_vnet_cidr
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

  aks_inbound_rules = {
    "Allow-AppGateway-HTTP-HTTPS-Inbound" = {
      description                = "Only the Application Gateway subnet may reach the internal ingress on 80/443."
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.agw_subnet_cidr
      destination_address_prefix = var.aks_vnet_cidr
      destination_port_ranges    = ["80", "443"]
    }
    "Deny-AppGateway-Other-Inbound" = {
      description                = "Block any other traffic from the peered Application Gateway vNet."
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = var.agw_vnet_cidr
      destination_address_prefix = "*"
      destination_port_ranges    = ["*"]
    }
    "Deny-Internet-Inbound" = {
      description                = "No direct Internet ingress to AKS. All user traffic must traverse the App Gateway WAF."
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
    ingress = {
      name   = "${local.prefix}-snet-aks-ingress"
      prefix = local.aks_ingress_subnet_cidr
    }
    pe = {
      name   = "${local.prefix}-snet-pe"
      prefix = local.aks_pe_subnet_cidr
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

# ------------------------------------------------------ NSG: App Gateway ----
# Rules required by Application Gateway v2:
# https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure#network-security-groups
resource "azurerm_network_security_group" "agw" {
  name                = "${local.prefix}-nsg-agw"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags

  security_rule {
    name                       = "Allow-Internet-HTTP-HTTPS-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = local.agw_subnet_cidr
    destination_port_ranges    = ["80", "443"]
  }

  security_rule {
    name                       = "Allow-GatewayManager-Inbound"
    description                = "Required by the Application Gateway v2 control plane."
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "GatewayManager"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "65200-65535"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Inbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
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

# ------------------------------------------------------------ vNets ---------
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

resource "azurerm_virtual_network" "agw" {
  name                = "${local.prefix}-vnet-agw"
  location            = local.location
  resource_group_name = local.rg_name
  address_space       = [var.agw_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "agw" {
  name                 = "${local.prefix}-snet-agw"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.agw.name
  address_prefixes     = [local.agw_subnet_cidr]
}

resource "azurerm_subnet_network_security_group_association" "agw" {
  subnet_id                 = azurerm_subnet.agw.id
  network_security_group_id = azurerm_network_security_group.agw.id
}

# ------------------------------------------------------------ Peering -------
resource "azurerm_virtual_network_peering" "aks_to_agw" {
  name                         = "peer-to-${azurerm_virtual_network.agw.name}"
  resource_group_name          = local.rg_name
  virtual_network_name         = azurerm_virtual_network.aks.name
  remote_virtual_network_id    = azurerm_virtual_network.agw.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "agw_to_aks" {
  name                         = "peer-to-${azurerm_virtual_network.aks.name}"
  resource_group_name          = local.rg_name
  virtual_network_name         = azurerm_virtual_network.agw.name
  remote_virtual_network_id    = azurerm_virtual_network.aks.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

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
    agw = azurerm_network_security_group.agw.id
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

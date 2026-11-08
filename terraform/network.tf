# -----------------------------------------------------------------------------
# Networking: two separate, peered virtual networks
#   * AKS vNet         -> node subnet, internal-ingress subnet, private-endpoint subnet
#   * App Gateway vNet -> dedicated Application Gateway (WAF_v2) subnet
# Every subnet has an NSG (CIS 6.x). AKS egress goes through a NAT Gateway and is
# filtered by the NSG egress rules in config/aks-egress-rules.json.
# -----------------------------------------------------------------------------

locals {
  aks_inbound_rules = {
    "Allow-AppGateway-HTTP-HTTPS-Inbound" = {
      description                = "Only the Application Gateway subnet may reach the internal ingress on 80/443."
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = var.agw_subnet_prefix
      destination_address_prefix = var.aks_vnet_address_prefix
      destination_port_ranges    = ["80", "443"]
    }
    "Deny-AppGateway-Other-Inbound" = {
      description                = "Block any other traffic from the peered Application Gateway vNet."
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = var.agw_vnet_address_prefix
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

  aks_nsg_rules = merge(local.aks_inbound_rules, local.aks_outbound_rules)

  aks_subnets = {
    nodes = {
      name   = "${local.prefix}-snet-aks-nodes"
      prefix = var.aks_node_subnet_prefix
    }
    ingress = {
      name   = "${local.prefix}-snet-aks-ingress"
      prefix = var.aks_ingress_subnet_prefix
    }
    pe = {
      name   = "${local.prefix}-snet-pe"
      prefix = var.aks_private_endpoint_subnet_prefix
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
    destination_address_prefix = var.agw_subnet_prefix
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
  address_space       = [var.aks_vnet_address_prefix]
  tags                = local.tags
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
  address_space       = [var.agw_vnet_address_prefix]
  tags                = local.tags
}

resource "azurerm_subnet" "agw" {
  name                 = "${local.prefix}-snet-agw"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.agw.name
  address_prefixes     = [var.agw_subnet_prefix]
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

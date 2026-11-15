# -----------------------------------------------------------------------------
# Private AKS cluster
#  * Private API server (no public FQDN), Entra ID auth + Azure RBAC, local accounts disabled
#  * Azure CNI Overlay + Cilium network policy, NAT Gateway egress (no public LB)
#  * Azure Policy, Defender, Container Insights, Key Vault CSI driver, workload identity
#  * Encryption at host, automatic patch + node image upgrades, image cleaner
# -----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "aks" {
  name                = "${local.prefix}-id-aks"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

# The control plane identity must manage the BYO subnets (node subnet, ILB subnet, NAT GW).
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                            = azurerm_virtual_network.aks.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Private DNS zone for the private API server. Kept in this resource group (rather
# than AKS's "System" zone in the node resource group) so it can be linked to other
# vNets - such as the private GitHub runner - with the deployment identity's
# resource-group-scoped permissions.
resource "azurerm_private_dns_zone" "aks_api" {
  name                = "privatelink.${local.location}.azmk8s.io"
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_api" {
  name                 = "${azurerm_virtual_network.aks.name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.aks_api.id
  virtual_network_id   = azurerm_virtual_network.aks.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_api_runner" {
  count = local.runner_enabled ? 1 : 0

  name                 = "${var.runner_vnet_name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.aks_api.id
  virtual_network_id   = data.azurerm_virtual_network.runner[0].id
  registration_enabled = false
  tags                 = local.tags
}

# AKS writes the API server's A record into the zone.
resource "azurerm_role_assignment" "aks_private_dns_contributor" {
  scope                            = azurerm_private_dns_zone.aks_api.id
  role_definition_name             = "Private DNS Zone Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.aks_name
  location            = local.location
  resource_group_name = local.rg_name
  dns_prefix          = local.aks_name
  node_resource_group = "${local.prefix}-aks-nodes"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Standard"
  tags                = local.tags

  # Private API server
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = azurerm_private_dns_zone.aks_api.id # in this RG (see below)

  # Identity & access (CIS: RBAC on AKS)
  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.aks_admin_group_object_ids
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  oidc_issuer_enabled          = true
  workload_identity_enabled    = true
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 168
  azure_policy_enabled         = true

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Required by azurerm 5.x. "Manual" = node pools are defined explicitly below
  # (VM size and count are inputs); Node Auto Provisioning is not used.
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = azurerm_subnet.aks["nodes"].id
    os_sku                       = "AzureLinux"
    os_disk_type                 = "Managed"
    os_disk_size_gb              = 128
    max_pods                     = 110
    host_encryption_enabled      = var.enable_encryption_at_host
    node_public_ip_enabled       = false
    only_critical_addons_enabled = true # keep application pods off the system pool
    temporary_name_for_rotation  = "systemtmp"
    tags                         = local.tags

    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = local.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  depends_on = [
    azurerm_role_assignment.aks_network_contributor,
    azurerm_role_assignment.aks_private_dns_contributor,
    azurerm_private_dns_zone_virtual_network_link.aks_api,
    azurerm_subnet_nat_gateway_association.aks_nodes,
    azurerm_subnet_network_security_group_association.aks,
    azurerm_nat_gateway_public_ip_association.this,
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                    = "user"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.this.id
  mode                    = "User"
  vm_size                 = local.user_node_vm_size
  node_count              = var.user_node_count
  vnet_subnet_id          = azurerm_subnet.aks["nodes"].id
  os_type                 = "Linux"
  os_sku                  = "AzureLinux"
  os_disk_type            = "Managed"
  os_disk_size_gb         = 128
  max_pods                = 110
  host_encryption_enabled = var.enable_encryption_at_host
  node_public_ip_enabled  = false
  tags                    = local.tags

  upgrade_settings {
    max_surge = "33%"
  }
}

# ------------------------------------------- Container Insights (managed identity) --
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "MSCI-${local.location}-${local.aks_name}"
  location            = local.location
  resource_group_name = local.rg_name
  kind                = "Linux"
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Container Insights data collection for ${local.aks_name}"
}

# ------------------------------------------------- Control plane logs (CIS 5.x) --
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  dynamic "enabled_log" {
    for_each = toset([
      "kube-apiserver",
      "kube-audit-admin",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard",
    ])
    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ------------------------------------------------------ Azure RBAC for Kubernetes --
resource "azurerm_role_assignment" "aks_admin_groups" {
  for_each = toset(var.aks_admin_group_object_ids)

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "aks_deployer" {
  count = var.grant_deployer_cluster_admin ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

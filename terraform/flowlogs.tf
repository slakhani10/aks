# -----------------------------------------------------------------------------
# Optional VNet flow logs (CIS 6.4-6.6; successor to NSG flow logs).
# Flow logs are child resources of the regional Network Watcher, which Azure
# allows only once per region per subscription (normally in NetworkWatcherRG).
# -----------------------------------------------------------------------------

resource "azurerm_storage_account" "flowlogs" {
  count = var.enable_vnet_flow_logs ? 1 : 0

  name                     = local.flowlog_sa_name
  location                 = local.location
  resource_group_name      = local.rg_name
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.tags

  # CIS 3.x
  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  public_network_access             = "Disabled"
  infrastructure_encryption_enabled = true

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  for_each = var.enable_vnet_flow_logs ? {
    aks = azurerm_virtual_network.aks
  } : {}

  name                 = "${each.value.name}-flowlog"
  network_watcher_name = "NetworkWatcher_${local.location}"
  resource_group_name  = var.network_watcher_resource_group
  location             = local.location
  target_resource_id   = each.value.id
  storage_account_id   = azurerm_storage_account.flowlogs[0].id
  enabled              = true
  version              = 2
  tags                 = local.tags

  retention_policy {
    enabled = true
    days    = 365
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.this.workspace_id
    workspace_region      = local.location
    workspace_resource_id = azurerm_log_analytics_workspace.this.id
    interval_in_minutes   = 10
  }
}

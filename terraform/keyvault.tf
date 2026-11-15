# -----------------------------------------------------------------------------
# Key Vault (CIS 8.x): RBAC authorization, soft delete + purge protection,
# public network access disabled, reachable only via private endpoint, audit
# logs to Log Analytics.
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                          = local.key_vault_name
  location                      = local.location
  resource_group_name           = local.rg_name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 90
  purge_protection_enabled      = true
  public_network_access_enabled = false
  tags                          = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  for_each = merge(
    {
      aks = { name = azurerm_virtual_network.aks.name, id = azurerm_virtual_network.aks.id }
      agw = { name = azurerm_virtual_network.agw.name, id = azurerm_virtual_network.agw.id }
    },
    # Lets jobs on the private runner manage secrets/certificates in the private vault.
    local.runner_enabled ? {
      runner = { name = data.azurerm_virtual_network.runner[0].name, id = data.azurerm_virtual_network.runner[0].id }
    } : {}
  )

  name                 = "${each.value.name}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.kv.id # azurerm 5.x: zone (and its RG) referenced by ID
  virtual_network_id   = each.value.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "kv" {
  name                          = "${local.prefix}-pe-kv"
  location                      = local.location
  resource_group_name           = local.rg_name
  subnet_id                     = azurerm_subnet.aks["pe"].id
  custom_network_interface_name = "${local.prefix}-pe-kv-nic"
  tags                          = local.tags

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # allLogs includes AuditEvent (CIS 5.1.5)
  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Least-privilege data-plane access
resource "azurerm_role_assignment" "kv_agw" {
  scope                            = azurerm_key_vault.this.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.agw.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "kv_csi" {
  scope                            = azurerm_key_vault.this.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

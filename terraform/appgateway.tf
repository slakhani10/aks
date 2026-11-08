# -----------------------------------------------------------------------------
# Application Gateway WAF_v2: the only Internet-facing entry point.
#   Internet -> Public IP -> WAF (Prevention, Microsoft DRS 2.1 + Bot Manager)
#            -> peered AKS vNet -> internal load balancer IP (AKS ingress subnet)
# When app_gateway_certificate_kv_uri is set, an HTTPS listener (TLS 1.2+) is
# created and HTTP is redirected to HTTPS.
# -----------------------------------------------------------------------------

locals {
  agw_name      = "${local.prefix}-agw"
  agw_use_https = var.app_gateway_certificate_kv_uri != null && var.app_gateway_certificate_kv_uri != ""

  agw_frontend_ip = "frontend-public"
  agw_backend     = "pool-aks-ingress"
  agw_settings    = "settings-aks-ingress"
  agw_probe       = "probe-aks-ingress"
}

resource "azurerm_user_assigned_identity" "agw" {
  name                = "${local.prefix}-id-agw"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_public_ip" "agw" {
  name                = "${local.prefix}-pip-agw"
  location            = local.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${local.prefix}-agw-${local.unique_suffix}"
  tags                = local.tags
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${local.prefix}-wafpol"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    max_request_body_size_in_kb = 128
    file_upload_limit_in_mb     = 100
  }

  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }
}

resource "azurerm_application_gateway" "this" {
  name                              = local.agw_name
  location                          = local.location
  resource_group_name               = local.rg_name
  firewall_policy_id                = azurerm_web_application_firewall_policy.this.id
  force_firewall_policy_association = true
  http2_enabled                     = true
  tags                              = local.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = var.app_gateway_min_capacity
    max_capacity = var.app_gateway_max_capacity
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agw.id]
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  gateway_ip_configuration {
    name      = "gateway-ipconfig"
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_ip_configuration {
    name                 = local.agw_frontend_ip
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  dynamic "frontend_port" {
    for_each = local.agw_use_https ? [1] : []
    content {
      name = "port-443"
      port = 443
    }
  }

  dynamic "ssl_certificate" {
    for_each = local.agw_use_https ? [1] : []
    content {
      name                = "listener-cert"
      key_vault_secret_id = var.app_gateway_certificate_kv_uri
    }
  }

  backend_address_pool {
    name         = local.agw_backend
    ip_addresses = [local.ingress_private_ip]
  }

  probe {
    name                                      = local.agw_probe
    protocol                                  = "Http"
    host                                      = "127.0.0.1"
    path                                      = "/"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false

    match {
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                                = local.agw_settings
    port                                = 80
    protocol                            = "Http"
    cookie_based_affinity               = "Disabled"
    request_timeout                     = 30
    pick_host_name_from_backend_address = false
    probe_name                          = local.agw_probe
  }

  http_listener {
    name                           = "listener-http"
    frontend_ip_configuration_name = local.agw_frontend_ip
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  dynamic "http_listener" {
    for_each = local.agw_use_https ? [1] : []
    content {
      name                           = "listener-https"
      frontend_ip_configuration_name = local.agw_frontend_ip
      frontend_port_name             = "port-443"
      protocol                       = "Https"
      ssl_certificate_name           = "listener-cert"
    }
  }

  dynamic "redirect_configuration" {
    for_each = local.agw_use_https ? [1] : []
    content {
      name                 = "redirect-http-to-https"
      redirect_type        = "Permanent"
      target_listener_name = "listener-https"
      include_path         = true
      include_query_string = true
    }
  }

  dynamic "request_routing_rule" {
    for_each = local.agw_use_https ? [1] : []
    content {
      name                        = "rule-http-to-https"
      rule_type                   = "Basic"
      priority                    = 100
      http_listener_name          = "listener-http"
      redirect_configuration_name = "redirect-http-to-https"
    }
  }

  request_routing_rule {
    name                       = "rule-to-aks"
    rule_type                  = "Basic"
    priority                   = 200
    http_listener_name         = local.agw_use_https ? "listener-https" : "listener-http"
    backend_address_pool_name  = local.agw_backend
    backend_http_settings_name = local.agw_settings
  }

  # The gateway must be able to read the TLS certificate from Key Vault.
  depends_on = [
    azurerm_role_assignment.kv_agw,
    azurerm_subnet_network_security_group_association.agw,
  ]
}

resource "azurerm_monitor_diagnostic_setting" "agw" {
  for_each = {
    agw = azurerm_application_gateway.this.id
    pip = azurerm_public_ip.agw.id
  }

  name                       = "to-log-analytics"
  target_resource_id         = each.value
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # App Gateway: Access, Performance and Firewall logs
  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

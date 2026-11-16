# -----------------------------------------------------------------------------
# Application Gateway for Containers (AGfC) with WAF - the only Internet entry point.
#
#   Internet -> AGfC frontend (Azure-managed FQDN, ports 80/443 only)
#            -> WAF policy (Prevention, Microsoft DRS 2.1 + Bot Manager 1.0)
#            -> AGfC association subnet (delegated /24 in the AKS vNet)
#            -> backend pods directly (CNI Overlay routing domain)
#
# "Bring your own" deployment: Terraform owns the AGfC resource, its frontend,
# its subnet association and the WAF security policy. The in-cluster ALB
# Controller (installed by the workflow with Helm) only programs routing from
# Kubernetes Gateway API objects, using a workload identity that has no secrets.
# -----------------------------------------------------------------------------

locals {
  alb_controller_namespace       = "azure-alb-system"
  alb_controller_service_account = "alb-controller-sa"
}

resource "azurerm_application_load_balancer" "this" {
  name                = "${local.prefix}-agc"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

resource "azurerm_application_load_balancer_frontend" "this" {
  name                         = "${local.prefix}-agc-fe"
  application_load_balancer_id = azurerm_application_load_balancer.this.id
  tags                         = local.tags
}

resource "azurerm_application_load_balancer_subnet_association" "this" {
  name                         = "${local.prefix}-agc-assoc"
  application_load_balancer_id = azurerm_application_load_balancer.this.id
  subnet_id                    = azurerm_subnet.agc.id
  tags                         = local.tags

  # NSG rules must be in place first: they are fully enforced for new associations.
  depends_on = [azurerm_subnet_network_security_group_association.agc]
}

# ----------------------------------------------------------------- WAF --------
# AGfC supports DRS 2.1 and Bot Manager 1.0/1.1 (not CRS, not custom block responses).
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

# Step 1 of 2 to enable WAF: the Azure-side security policy. Step 2 is the
# WebApplicationFirewallPolicy custom resource in the cluster
# (k8s/platform/gateway.yaml), applied by the workflow. Without BOTH, AGfC does
# not inspect traffic.
resource "azurerm_application_load_balancer_security_policy" "waf" {
  name                               = "${local.prefix}-agc-waf"
  location                           = local.location
  application_load_balancer_id       = azurerm_application_load_balancer.this.id
  web_application_firewall_policy_id = azurerm_web_application_firewall_policy.this.id
  tags                               = local.tags
}

# ----------------------------------------------- ALB Controller identity ------
resource "azurerm_user_assigned_identity" "alb" {
  name                = "${local.prefix}-id-alb"
  location            = local.location
  resource_group_name = local.rg_name
  tags                = local.tags
}

# Workload identity: only the controller's service account can use this identity.
resource "azurerm_federated_identity_credential" "alb" {
  name                      = "alb-controller"
  user_assigned_identity_id = azurerm_user_assigned_identity.alb.id
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.alb_controller_namespace}:${local.alb_controller_service_account}"
  audience                  = ["api://AzureADTokenExchange"]
}

# Least privilege per Microsoft's BYO guidance: configure AGfC resources in this RG,
# and join only the AGfC subnet.
resource "azurerm_role_assignment" "alb_config_manager" {
  scope                            = data.azurerm_resource_group.this.id
  role_definition_name             = "AppGw for Containers Configuration Manager"
  principal_id                     = azurerm_user_assigned_identity.alb.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "alb_subnet_join" {
  scope                            = azurerm_subnet.agc.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.alb.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# ----------------------------------------------------------- Diagnostics ------
# Access logs and WAF (firewall) logs to Log Analytics (CIS 5.x).
resource "azurerm_monitor_diagnostic_setting" "agc" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_application_load_balancer.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

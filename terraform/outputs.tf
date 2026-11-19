output "location" {
  value = local.location
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "aks_node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "agc_id" {
  description = "App Gateway for Containers resource ID (Gateway annotation alb.networking.azure.io/alb-id)."
  value       = azurerm_application_load_balancer.this.id
}

output "agc_frontend_name" {
  description = "Frontend name referenced by the Gateway's addresses (type alb.networking.azure.io/alb-frontend)."
  value       = azurerm_application_load_balancer_frontend.this.name
}

output "agc_frontend_fqdn" {
  description = "Public entry point. Point your DNS CNAME here."
  value       = azurerm_application_load_balancer_frontend.this.fully_qualified_domain_name
}

output "waf_policy_id" {
  description = "Referenced by the in-cluster WebApplicationFirewallPolicy."
  value       = azurerm_web_application_firewall_policy.this.id
}

output "alb_controller_client_id" {
  description = "Workload identity client ID for the ALB Controller Helm chart (albController.podIdentity.clientID)."
  value       = azurerm_user_assigned_identity.alb.client_id
}

output "alb_controller_namespace" {
  value = local.alb_controller_namespace
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "nat_gateway_public_ip" {
  description = "Source IP of all AKS egress traffic (useful for allow-listing downstream)."
  value       = azurerm_public_ip.natgw.ip_address
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "private_dns_zone_ids" {
  description = "Private DNS zone IDs for private endpoints (private_dns_zone_group): key_vault, aks_api, acr, postgres."
  value = merge(
    { key_vault = local.kv_dns_zone_id, aks_api = local.aks_dns_zone_id },
    local.service_dns_zone_ids
  )
}

output "postgres_server_name" {
  value = local.pg_enabled ? azurerm_postgresql_flexible_server.this[0].name : null
}

output "postgres_fqdn" {
  description = "Connect to this name (resolves to the server's private IP in the AKS and runner vNets). TLS required."
  value       = local.pg_enabled ? azurerm_postgresql_flexible_server.this[0].fqdn : null
}

output "postgres_admin_login" {
  value = local.pg_enabled && var.postgres_password_auth_enabled ? "pgadmin" : null
}

output "postgres_admin_password" {
  description = "Break-glass password (terraform output -raw postgres_admin_password)."
  value       = local.pg_enabled && var.postgres_password_auth_enabled ? random_password.pg_admin[0].result : null
  sensitive   = true
}

output "postgres_subnet_cidr" {
  value = local.pg_enabled ? local.pg_subnet_cidr : null
}

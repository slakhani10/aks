output "location" {
  value = local.location
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "aks_node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "app_gateway_name" {
  value = azurerm_application_gateway.this.name
}

output "app_gateway_public_ip" {
  value = azurerm_public_ip.agw.ip_address
}

output "app_gateway_fqdn" {
  value = azurerm_public_ip.agw.fqdn
}

output "ingress_private_ip" {
  description = "Static IP the AKS internal load balancer / ingress controller must use (App Gateway backend)."
  value       = local.ingress_private_ip
}

output "ingress_subnet_name" {
  value = azurerm_subnet.aks["ingress"].name
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

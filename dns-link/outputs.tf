output "kv_private_dns_zone_id" {
  description = "Resolved Key Vault zone ID."
  value       = data.azurerm_private_dns_zone.kv.id
}

output "aks_private_dns_zone_id" {
  description = "Resolved AKS API server zone ID."
  value       = data.azurerm_private_dns_zone.aks_api.id
}

output "links" {
  description = "Created links: <zone>/<vnet> => link ID."
  value       = { for k, v in azurerm_private_dns_zone_virtual_network_link.this : k => v.id }
}

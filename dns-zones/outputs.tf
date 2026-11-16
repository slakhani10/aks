output "dns_zone_subscription_id" {
  description = "Use as DNS_ZONE_SUBSCRIPTION (repository variable) / dns_subscription (link workflow)."
  value       = split("/", azurerm_private_dns_zone.this["key_vault"].id)[2]
}

output "dns_zone_resource_group_name" {
  value = data.azurerm_resource_group.this.name
}

output "kv_private_dns_zone_name" {
  value = azurerm_private_dns_zone.this["key_vault"].name
}

output "kv_private_dns_zone_id" {
  value = azurerm_private_dns_zone.this["key_vault"].id
}

output "aks_private_dns_zone_name" {
  value = azurerm_private_dns_zone.this["aks_api"].name
}

output "aks_private_dns_zone_id" {
  value = azurerm_private_dns_zone.this["aks_api"].id
}

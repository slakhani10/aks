output "dns_zone_subscription_id" {
  description = "With dns_zone_resource_group_name, the value for the AKS workflow input central_dns_zones (<subscription>/<resource group>)."
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

output "acr_private_dns_zone_name" {
  value = azurerm_private_dns_zone.this["acr"].name
}

output "acr_private_dns_zone_id" {
  value = azurerm_private_dns_zone.this["acr"].id
}

output "postgres_private_dns_zone_name" {
  value = azurerm_private_dns_zone.this["postgres"].name
}

output "postgres_private_dns_zone_id" {
  value = azurerm_private_dns_zone.this["postgres"].id
}

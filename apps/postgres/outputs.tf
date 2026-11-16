output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Connect to this name: inside the linked vNets it resolves to the private endpoint IP."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.this.name
}

output "admin_login" {
  value = azurerm_postgresql_flexible_server.this.administrator_login
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "private_endpoint_ip" {
  value = azurerm_private_endpoint.this.private_service_connection[0].private_ip_address
}

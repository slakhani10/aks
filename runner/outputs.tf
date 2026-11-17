output "runner_vnet_name" {
  description = "Pass this to the AKS Terraform as runner_vnet_name (the AKS workflow does it automatically when runner = self-hosted)."
  value       = azurerm_virtual_network.runner.name
}

output "runner_vnet_id" {
  value = azurerm_virtual_network.runner.id
}

output "runner_vnet_cidr" {
  value = var.runner_vnet_cidr
}

output "runner_vm_names" {
  value = local.runner_names
}

output "runner_labels" {
  description = "Labels the workflow registers each runner with."
  value       = join(",", local.runner_labels)
}

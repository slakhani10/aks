# ------------------------------------------------------------ AKS environment --
variable "resource_group_name" {
  description = "Resource group of the AKS environment (deployment subscription). Its vNets are linked by naming convention: <rg>-vnet-aks and, if set, the runner vNet."
  type        = string
}

variable "runner_vnet_name" {
  description = "Name of the private GitHub runner vNet in the same resource group (e.g. <rg>-vnet-runner). Null/empty = no runner links. The workflow detects it automatically."
  type        = string
  default     = null
}

# ------------------------------------------------------ Central private DNS zones --
variable "dns_zone_subscription_id" {
  description = "Subscription ID holding the private DNS zones. The workflow resolves a subscription name to this ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.dns_zone_subscription_id))
    error_message = "dns_zone_subscription_id must be a subscription ID (GUID)."
  }
}

variable "dns_zone_resource_group_name" {
  description = "Resource group holding the private DNS zones."
  type        = string
}

variable "kv_private_dns_zone_name" {
  description = "Key Vault private DNS zone name."
  type        = string
  default     = "privatelink.vaultcore.azure.net"
}

variable "aks_private_dns_zone_name" {
  description = "Private AKS API server zone name (privatelink.<region>.azmk8s.io). Null = derived from the AKS environment's region."
  type        = string
  default     = null
}

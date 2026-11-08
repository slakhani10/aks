# ------------------------------------------------------------- Required inputs --
variable "resource_group_name" {
  description = "Name of the EXISTING resource group. Used as the naming prefix; its region is used for every resource."
  type        = string
}

variable "system_node_vm_size" {
  description = "VM SKU for the system node pool."
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_count" {
  description = "Node count for the system node pool. Use 3+ for production."
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_count >= 1 && var.system_node_count <= 100
    error_message = "system_node_count must be between 1 and 100."
  }
}

variable "user_node_vm_size" {
  description = "VM SKU for the user (workload) node pool. Null or empty = same as the system pool."
  type        = string
  default     = null
}

variable "user_node_count" {
  description = "Node count for the user (workload) node pool."
  type        = number
  default     = 2

  validation {
    condition     = var.user_node_count >= 0 && var.user_node_count <= 1000
    error_message = "user_node_count must be between 0 and 1000."
  }
}

# ------------------------------------------------------------- Optional inputs --
variable "kubernetes_version" {
  description = "Kubernetes version. Null = AKS default for the region."
  type        = string
  default     = null
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object IDs granted 'Azure Kubernetes Service RBAC Cluster Admin'."
  type        = list(string)
  default     = []
}

variable "grant_deployer_cluster_admin" {
  description = "Grant the identity running Terraform cluster admin (needed for 'az aks command invoke' from the pipeline)."
  type        = bool
  default     = true
}

variable "app_gateway_certificate_kv_uri" {
  description = "Optional Key Vault secret URI (versionless) of a PFX certificate. When set, App Gateway serves HTTPS and redirects HTTP to HTTPS."
  type        = string
  default     = null
}

variable "enable_encryption_at_host" {
  description = "Enable host-based encryption on node VMs. Requires the Microsoft.Compute/EncryptionAtHost feature on the subscription."
  type        = bool
  default     = true
}

variable "enable_vnet_flow_logs" {
  description = "Enable VNet flow logs + Traffic Analytics (CIS 6.4-6.6). Requires the regional Network Watcher to exist."
  type        = bool
  default     = false
}

variable "network_watcher_resource_group" {
  description = "Resource group of the regional Network Watcher (only used when enable_vnet_flow_logs = true)."
  type        = string
  default     = "NetworkWatcherRG"
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "app_gateway_min_capacity" {
  description = "App Gateway autoscale minimum instances."
  type        = number
  default     = 2
}

variable "app_gateway_max_capacity" {
  description = "App Gateway autoscale maximum instances (must fit in the App Gateway subnet)."
  type        = number
  default     = 10
}

# ------------------------------------------------------------ Address space ----
# AKS vNet /22. With Azure CNI Overlay pods use pod_cidr, so the node subnet only
# needs node IPs: /24 = 251 nodes. The remaining /23 is free for growth.
variable "aks_vnet_address_prefix" {
  type    = string
  default = "10.0.0.0/22"
}

variable "aks_node_subnet_prefix" {
  type    = string
  default = "10.0.0.0/24"
}

variable "aks_ingress_subnet_prefix" {
  description = "Subnet hosting the AKS internal load balancer frontend IP(s) used by App Gateway."
  type        = string
  default     = "10.0.1.0/28"
}

variable "aks_private_endpoint_subnet_prefix" {
  type    = string
  default = "10.0.1.16/28"
}

# App Gateway vNet /24. AGW subnet /25 = 123 usable IPs, well above the max
# autoscale capacity; the other /25 is free.
variable "agw_vnet_address_prefix" {
  type    = string
  default = "10.1.0.0/24"
}

variable "agw_subnet_prefix" {
  type    = string
  default = "10.1.0.0/25"
}

# Overlay ranges - must not overlap any network you peer or route to.
variable "pod_cidr" {
  type    = string
  default = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "172.16.0.10"
}

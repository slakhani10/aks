# ------------------------------------------------------------- Required inputs --
variable "resource_group_name" {
  description = "Name of the EXISTING resource group. Used as the naming prefix; its region is used for every resource."
  type        = string
}

variable "system_node_vm_size" {
  description = "VM SKU for the system node pool."
  type        = string
  default     = "Standard_B2as_v2"
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

variable "runner_vnet_name" {
  description = <<-EOT
    Optional name of the private GitHub runner vNet (created by ../runner, e.g.
    "<rg>-vnet-runner") in the same resource group. When set, the AKS vNet is
    peered with it, the runner may reach the AKS vNet on TCP 443 only (private
    API server + Key Vault private endpoint), and the private DNS zones of the
    API server and Key Vault are linked to it. Null = no runner connectivity.
  EOT
  type        = string
  default     = null
}

variable "additional_tags" {
  description = "Optional extra tags added to every resource. Resource group tags are always copied and win on key conflicts."
  type        = map(string)
  default     = {}
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
  default     = 1
}

variable "app_gateway_max_capacity" {
  description = "App Gateway autoscale maximum instances (must fit in the App Gateway subnet)."
  type        = number
  default     = 2
}

# ------------------------------------------------------------ Address space ----
# Only the four top-level ranges are inputs. Subnets are carved out of the vNet
# ranges automatically (see locals in network.tf), so they always line up.
# All four ranges must be IPv4, must not overlap each other, and must not overlap
# any network you peer or route to. Overlaps are rejected at plan time.

variable "aks_vnet_cidr" {
  description = <<-EOT
    Address space of the AKS vNet. Must be /23 or larger (/16-/23). Carved into:
      node subnet              /24 (1st /24)  - Azure CNI Overlay: nodes only, 251 nodes
      internal ingress subnet  /28 (start of the 2nd /24)
      private endpoint subnet  /28 (next /28)
    Anything left over (e.g. the other /23 of a /22) is free for growth.
  EOT
  type        = string
  default     = "10.0.0.0/22"

  validation {
    condition     = can(cidrnetmask(var.aks_vnet_cidr)) && tonumber(split("/", var.aks_vnet_cidr)[1]) >= 16 && tonumber(split("/", var.aks_vnet_cidr)[1]) <= 23
    error_message = "aks_vnet_cidr must be a valid IPv4 CIDR between /16 and /23 (e.g. 10.0.0.0/22)."
  }

  validation {
    condition     = can(cidrnetmask(var.aks_vnet_cidr)) && cidrsubnet(var.aks_vnet_cidr, 0, 0) == var.aks_vnet_cidr
    error_message = "aks_vnet_cidr must start on its network boundary (e.g. 10.0.0.0/22, not 10.0.1.0/22)."
  }
}

variable "agw_vnet_cidr" {
  description = <<-EOT
    Address space of the Application Gateway vNet. Must be /25 or larger (/16-/25).
    The App Gateway subnet is the first /25 (123 usable IPs, well above the max
    autoscale capacity); anything left over is free.
  EOT
  type        = string
  default     = "10.1.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.agw_vnet_cidr)) && tonumber(split("/", var.agw_vnet_cidr)[1]) >= 16 && tonumber(split("/", var.agw_vnet_cidr)[1]) <= 25
    error_message = "agw_vnet_cidr must be a valid IPv4 CIDR between /16 and /25 (e.g. 10.1.0.0/24)."
  }

  validation {
    condition     = can(cidrnetmask(var.agw_vnet_cidr)) && cidrsubnet(var.agw_vnet_cidr, 0, 0) == var.agw_vnet_cidr
    error_message = "agw_vnet_cidr must start on its network boundary (e.g. 10.1.0.0/24)."
  }
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod range (not routable outside the cluster). Each node gets a /24, so /16 = up to 256 nodes. Allowed /12-/20."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.pod_cidr)) && tonumber(split("/", var.pod_cidr)[1]) >= 12 && tonumber(split("/", var.pod_cidr)[1]) <= 20 && cidrsubnet(var.pod_cidr, 0, 0) == var.pod_cidr
    error_message = "pod_cidr must be a valid IPv4 network CIDR between /12 and /20 (e.g. 10.244.0.0/16)."
  }
}

variable "service_cidr" {
  description = "Kubernetes service range. The cluster DNS service uses the 10th address. Allowed /12-/24."
  type        = string
  default     = "172.16.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.service_cidr)) && tonumber(split("/", var.service_cidr)[1]) >= 12 && tonumber(split("/", var.service_cidr)[1]) <= 24 && cidrsubnet(var.service_cidr, 0, 0) == var.service_cidr
    error_message = "service_cidr must be a valid IPv4 network CIDR between /12 and /24 (e.g. 172.16.0.0/16)."
  }
}

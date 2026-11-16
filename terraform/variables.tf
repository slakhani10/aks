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

# ------------------------------------------------- Central private DNS zones ---
# Leave dns_zone_resource_group_name unset to create the zones locally (default).
# Set it to use and link EXISTING zones (e.g. created by ../dns-zones) - in another
# subscription when dns_zone_subscription_id is also set. See dns.tf.
# Workflow input: central_dns_zones = "<subscription name or ID>/<resource group>".
variable "dns_zone_subscription_id" {
  description = "Subscription ID of the central private DNS zones. Null = this deployment's subscription."
  type        = string
  default     = null

  validation {
    condition     = var.dns_zone_subscription_id == null || var.dns_zone_subscription_id == "" || can(regex("^[0-9a-fA-F-]{36}$", var.dns_zone_subscription_id))
    error_message = "dns_zone_subscription_id must be a subscription ID (GUID). The workflow resolves subscription names to IDs."
  }
}

variable "dns_zone_resource_group_name" {
  description = "Resource group of the central private DNS zones. Null/empty = create the zones locally."
  type        = string
  default     = null
}

variable "kv_private_dns_zone_name" {
  description = "Name of the central Key Vault private DNS zone."
  type        = string
  default     = "privatelink.vaultcore.azure.net"
}

variable "aks_private_dns_zone_name" {
  description = "Name of the private API server DNS zone. Null = privatelink.<region>.azmk8s.io (must match the cluster's region)."
  type        = string
  default     = null
}

# Private DNS zones for services the workloads reach over private endpoints. They
# are created (local mode) or looked up (central mode) and linked to the AKS vNet
# and the runner vNet, so a registry / database added later resolves privately
# from pods and pipelines. Set a name to "" to skip that zone.
variable "acr_private_dns_zone_name" {
  description = "Azure Container Registry private endpoint zone (also holds the <registry>.<region>.data records). Empty = skip."
  type        = string
  default     = "privatelink.azurecr.io"
}

variable "postgres_private_dns_zone_name" {
  description = "Azure Database for PostgreSQL flexible server private endpoint zone. Empty = skip."
  type        = string
  default     = "privatelink.postgres.database.azure.com"

  validation {
    condition     = var.postgres_private_dns_zone_name == null || var.postgres_private_dns_zone_name == "" || endswith(var.postgres_private_dns_zone_name, "postgres.database.azure.com")
    error_message = "postgres_private_dns_zone_name must end with postgres.database.azure.com."
  }
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

# ------------------------------------------------------------ Address space ----
# Only three top-level ranges are inputs. Subnets are carved out of the vNet range
# automatically (see locals in network.tf), so they always line up. All ranges must
# be IPv4, must not overlap each other (or the runner vNet, if connected), and must
# not overlap any network you peer or route to. Overlaps are rejected at plan time.

variable "aks_vnet_cidr" {
  description = <<-EOT
    Address space of the AKS vNet (the only vNet of the environment). Must be /22 or
    larger (/16-/22). Carved into:
      node subnet              1st /24          - Azure CNI Overlay: nodes only, 251 nodes
      private endpoint subnet  /28 in the 2nd /24 (x.x.1.16/28)
      AGfC association subnet  3rd /24          - App Gateway for Containers needs exactly /24
    The rest (e.g. the 4th /24 of a /22) is free for growth.
  EOT
  type        = string
  default     = "10.0.0.0/22"

  validation {
    condition     = can(cidrnetmask(var.aks_vnet_cidr)) && tonumber(split("/", var.aks_vnet_cidr)[1]) >= 16 && tonumber(split("/", var.aks_vnet_cidr)[1]) <= 22
    error_message = "aks_vnet_cidr must be a valid IPv4 CIDR between /16 and /22 (e.g. 10.0.0.0/22)."
  }

  validation {
    condition     = can(cidrnetmask(var.aks_vnet_cidr)) && cidrsubnet(var.aks_vnet_cidr, 0, 0) == var.aks_vnet_cidr
    error_message = "aks_vnet_cidr must start on its network boundary (e.g. 10.0.0.0/22, not 10.0.1.0/22)."
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

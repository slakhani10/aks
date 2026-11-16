variable "resource_group_name" {
  description = "EXISTING resource group of the secure AKS environment (naming prefix and region)."
  type        = string
}

variable "app_name" {
  description = "Application / Kubernetes service name. Names the server, database and private endpoint."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$", var.app_name))
    error_message = "app_name must be a lowercase DNS label: letters, digits and '-', starting with a letter, at most 40 characters."
  }
}

variable "postgres_private_dns_zone_id" {
  description = "Resource ID of the privatelink.postgres.database.azure.com zone (local or central). The workflow reads it from the AKS deployment output private_dns_zone_ids.postgres."
  type        = string

  validation {
    condition     = can(regex("(?i)/providers/Microsoft\\.Network/privateDnsZones/[^/]*postgres\\.database\\.azure\\.com$", var.postgres_private_dns_zone_id))
    error_message = "postgres_private_dns_zone_id must be the ID of a private DNS zone ending in postgres.database.azure.com."
  }
}

variable "sku_name" {
  description = "Compute SKU, e.g. B_Standard_B1ms (burstable), GP_Standard_D2ds_v5 (general purpose)."
  type        = string
  default     = "B_Standard_B1ms"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_", var.sku_name))
    error_message = "sku_name must look like B_Standard_B1ms, GP_Standard_D2ds_v5 or MO_Standard_E2ds_v5."
  }
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"

  validation {
    condition     = contains(["13", "14", "15", "16", "17"], var.postgres_version)
    error_message = "postgres_version must be one of 13, 14, 15, 16, 17."
  }
}

variable "storage_mb" {
  description = "Storage size in MB (32768 = 32 GiB). Can only grow."
  type        = number
  default     = 32768

  validation {
    condition     = contains([32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4193280, 4194304, 8388608, 16777216, 33553408], var.storage_mb)
    error_message = "storage_mb must be a supported size, e.g. 32768, 65536, 131072."
  }
}

variable "backup_retention_days" {
  description = "Point-in-time restore window (7-35 days)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "geo_redundant_backup_enabled" {
  description = "Geo-redundant backups (can't be changed after creation)."
  type        = bool
  default     = false
}

variable "database_name" {
  description = "Database to create. Null = app_name with '-' replaced by '_'."
  type        = string
  default     = null
}

variable "entra_admin_object_id" {
  description = "Optional Entra ID group (recommended) or principal that becomes the server's Entra administrator."
  type        = string
  default     = null
}

variable "entra_admin_principal_name" {
  description = "Display name of entra_admin_object_id (required with it)."
  type        = string
  default     = null
}

variable "entra_admin_principal_type" {
  description = "Group, User or ServicePrincipal."
  type        = string
  default     = "Group"

  validation {
    condition     = contains(["Group", "User", "ServicePrincipal"], var.entra_admin_principal_type)
    error_message = "entra_admin_principal_type must be Group, User or ServicePrincipal."
  }
}

variable "additional_tags" {
  description = "Optional extra tags. Resource group tags are always copied and win on key conflicts."
  type        = map(string)
  default     = {}
}

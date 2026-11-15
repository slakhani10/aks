# ------------------------------------------------------------- Required inputs --
variable "resource_group_name" {
  description = "Name of the EXISTING resource group (same one the AKS environment uses). Used as the naming prefix; its region is used for every resource."
  type        = string
}

# ------------------------------------------------------------- Optional inputs --
variable "runner_vnet_cidr" {
  description = <<-EOT
    Address space of the runner vNet, /16-/28. The runner subnet is the first /28
    (11 usable IPs = up to 11 runner VMs); anything left over is free for growth.
    Must not overlap the AKS vNet, App Gateway vNet, pod or service ranges, because
    the AKS deployment peers this vNet.
  EOT
  type        = string
  default     = "10.2.0.0/26"

  validation {
    condition     = can(cidrnetmask(var.runner_vnet_cidr)) && tonumber(split("/", var.runner_vnet_cidr)[1]) >= 16 && tonumber(split("/", var.runner_vnet_cidr)[1]) <= 28 && cidrsubnet(var.runner_vnet_cidr, 0, 0) == var.runner_vnet_cidr
    error_message = "runner_vnet_cidr must be a valid IPv4 network CIDR between /16 and /28 (e.g. 10.2.0.0/26)."
  }
}

variable "runner_vm_size" {
  description = "VM SKU for the runner(s). Must support Trusted Launch (Gen2)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "runner_count" {
  description = "Number of runner VMs."
  type        = number
  default     = 1

  validation {
    condition     = var.runner_count >= 1 && var.runner_count <= 11
    error_message = "runner_count must be between 1 and 11 (the /28 runner subnet has 11 usable IPs)."
  }
}

variable "runner_version" {
  description = "GitHub Actions runner version to install (e.g. 2.330.0), or \"latest\". Runners self-update after registration."
  type        = string
  default     = "latest"
}

variable "enable_encryption_at_host" {
  description = "Enable host-based encryption on the runner VMs. Requires the Microsoft.Compute/EncryptionAtHost feature on the subscription."
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "Optional extra tags added to every resource. Resource group tags are always copied and win on key conflicts."
  type        = map(string)
  default     = {}
}

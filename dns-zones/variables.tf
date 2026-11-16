variable "resource_group_name" {
  description = "EXISTING resource group (in the DNS subscription) that will hold the private DNS zones."
  type        = string
}

variable "aks_region" {
  description = "Azure region of the AKS cluster(s) that will use the API server zone (privatelink.<region>.azmk8s.io), e.g. northcentralus. Null/empty = the resource group's region."
  type        = string
  default     = null

  validation {
    condition     = var.aks_region == null || can(regex("^[a-z0-9]*$", coalesce(var.aks_region, "x")))
    error_message = "aks_region must be an Azure region name in lowercase without spaces, e.g. northcentralus."
  }
}

variable "additional_tags" {
  description = "Optional extra tags. Resource group tags are always copied and win on key conflicts."
  type        = map(string)
  default     = {}
}

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
  }

  # Remote state in Azure Storage. Values are supplied at init time:
  #   terraform init -backend-config="resource_group_name=..." \
  #                  -backend-config="storage_account_name=..." \
  #                  -backend-config="container_name=tfstate" \
  #                  -backend-config="key=<resource-group>-dns-links.tfstate"
  # Authentication uses Entra ID (no storage account keys).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

# Default provider: the AKS environment's subscription (ARM_SUBSCRIPTION_ID) -
# used to read its vNets.
provider "azurerm" {
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

# Subscription holding the central private DNS zones; the links are created there.
provider "azurerm" {
  alias                           = "dns"
  subscription_id                 = var.dns_zone_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Remote state in Azure Storage. Values are supplied at init time:
  #   terraform init -backend-config="resource_group_name=..." \
  #                  -backend-config="storage_account_name=..." \
  #                  -backend-config="container_name=tfstate" \
  #                  -backend-config="key=<resource-group>.tfstate"
  # Authentication uses Entra ID (no storage account keys).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # The deployment identity is scoped to a resource group, so it cannot register
  # resource providers. Register them once per subscription (see README).
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {
    key_vault {
      # CIS: keep vaults recoverable - never purge on destroy.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    storage {
      # The flow-log storage account has public network access disabled, so the
      # provider must not try to reach its data plane from the runner.
      data_plane_available = false
    }
  }
}

# Subscription holding CENTRAL private DNS zones (see dns.tf). When
# dns_zone_subscription_id is null this is the deployment subscription
# (ARM_SUBSCRIPTION_ID), so the alias is harmless when zones are local.
provider "azurerm" {
  alias                           = "dns"
  subscription_id                 = var.dns_zone_subscription_id == "" ? null : var.dns_zone_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

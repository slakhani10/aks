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
  #                  -backend-config="key=dns-zones-<subscription-id>-<resource-group>.tfstate"
  # Authentication uses Entra ID (no storage account keys).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # Target subscription = the one holding the DNS zones. The workflow resolves the
  # subscription name to its ID and sets ARM_SUBSCRIPTION_ID.
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

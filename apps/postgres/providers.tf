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

  # Remote state in Azure Storage, one state per application. Values are supplied
  # at init time (the workflow uses key = <resource-group>-app-<service>-postgres.tfstate).
  # The state holds the generated admin password: keep the state container private
  # and Entra-ID-only (no storage account keys), as for the other roots.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

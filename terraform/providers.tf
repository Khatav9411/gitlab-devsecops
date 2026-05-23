terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # For a real POC, configure a remote backend (Azure Storage) instead of local state.
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "tfstateXXXX"
  #   container_name       = "tfstate"
  #   key                  = "aks-poc.tfstate"
  # }
}

provider "azurerm" {
  features {}
}

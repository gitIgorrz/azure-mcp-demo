terraform {
  required_version = "~> 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # HCP Terraform — DPC/OIDC credentials injected at runtime (ADR-007).
  # Remove or override this block for local development (set TF_CLOUD_HOSTNAME=none).
  cloud {
    organization = "gitIgorrz"
    workspaces {
      name = "azure-mcp-demo"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # All mutating features disabled — no accidental resource recreation.
  features {}
}

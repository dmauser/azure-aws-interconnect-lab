provider "azurerm" {
  # Subscription and tenant are pinned so a stray `az account set` cannot
  # retarget the deployment at the wrong subscription.
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id

  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.tags
  }
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

provider "awscc" {
  region  = var.aws_region
  profile = var.aws_profile
}

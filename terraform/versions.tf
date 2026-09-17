terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # Creates the Azure Multicloud Interconnect circuit in interconnect_mode
    # "create". azurerm cannot: its sku.tier validator only accepts
    # Basic/Local/Premium/Standard and rejects MultiCloud outright.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    # Creates the AWS side of the pair. The classic hashicorp/aws provider has
    # no resource for AWS Interconnect - multicloud; awscc exposes it as
    # AWS::Interconnect::Connection via Cloud Control.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

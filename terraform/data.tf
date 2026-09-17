##############################################################################
# Locals, identity guardrails, and shared inputs
##############################################################################

locals {
  tags = merge(
    {
      project    = "azure-aws-interconnect-lab"
      managed_by = "terraform"
      purpose    = "azure-aws-multicloud-interconnect-lab"
    },
    var.tags,
  )

  creating_interconnect = var.interconnect_mode == "create"

  # The rest of the config attaches to the interconnect through these two IDs
  # and never needs to know which mode produced them. one() is used instead of a
  # bare [0] so the unused branch collapses to null rather than erroring on an
  # empty list.
  circuit_id = local.creating_interconnect ? one(azapi_resource.mci[*].id) : var.express_route_circuit_id
  dxgw_id    = local.creating_interconnect ? one(aws_dx_gateway.lab[*].id) : var.dx_gateway_id

  # Public IP allowed to SSH in, either supplied or auto-detected.
  my_cidr = var.my_public_ip != null ? var.my_public_ip : "${chomp(data.http.my_ip[0].response_body)}/32"

  generate_key   = var.ssh_public_key == null
  ssh_public_key = local.generate_key ? tls_private_key.lab[0].public_key_openssh : var.ssh_public_key

  private_key_path = local.generate_key ? abspath("${path.module}/../ssh/${var.prefix}.pem") : "<your existing private key>"
}

##############################################################################
# Caller public IP (only fetched when not supplied explicitly)
##############################################################################

data "http" "my_ip" {
  count = var.my_public_ip == null ? 1 : 0
  url   = "https://ifconfig.me/ip"
}

##############################################################################
# Lab-scoped SSH key, shared by both clouds
##############################################################################

# NOTE: the private key is stored in Terraform state. Acceptable for a throwaway
# lab with a local backend; do not reuse this pattern for anything real.
resource "tls_private_key" "lab" {
  count = local.generate_key ? 1 : 0

  # RSA 4096 rather than ed25519: Azure Linux VM provisioning requires RSA.
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  count = local.generate_key ? 1 : 0

  filename        = "${path.module}/../ssh/${var.prefix}.pem"
  content         = tls_private_key.lab[0].private_key_openssh
  file_permission = "0600"
}

##############################################################################
# AWS identity + AMI
##############################################################################

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

##############################################################################
# Guardrails: fail the plan early rather than half-building across two clouds
##############################################################################

resource "terraform_data" "guardrails" {
  input = {
    aws_account       = data.aws_caller_identity.current.account_id
    azure_sub         = var.azure_subscription_id
    interconnect_mode = var.interconnect_mode
  }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.aws_account_id
      error_message = "Wrong AWS account. Expected ${var.aws_account_id} but the '${var.aws_profile}' profile resolves to ${data.aws_caller_identity.current.account_id}."
    }

    precondition {
      condition     = cidrhost(var.azure_supernet_cidr, 0) != cidrhost(var.aws_vpc_cidr, 0)
      error_message = "azure_supernet_cidr and aws_vpc_cidr must not share a network address; routes would be ambiguous over the interconnect."
    }

    # Hub and spoke are peered, so their address spaces must be disjoint.
    precondition {
      condition     = cidrhost(var.azure_hub_vnet_cidr, 0) != cidrhost(var.azure_vnet_cidr, 0)
      error_message = "azure_hub_vnet_cidr and azure_vnet_cidr must not overlap; VNet peering rejects overlapping address spaces."
    }

    # Both BYO identifiers are required in "existing" mode and meaningless in
    # "create" mode, where Terraform produces them itself.
    precondition {
      condition     = local.creating_interconnect || try(length(trimspace(var.express_route_circuit_id)) > 0, false)
      error_message = "express_route_circuit_id is required when interconnect_mode = \"existing\". Run scripts/00-configure to discover your Multicloud Interconnect circuit, or set interconnect_mode = \"create\" to have Terraform build one."
    }

    # DXGW IDs are bare UUIDs, so only a non-empty check is meaningful here.
    precondition {
      condition     = local.creating_interconnect || try(length(trimspace(var.dx_gateway_id)) > 0 && var.dx_gateway_id != "REPLACE-ME", false)
      error_message = "dx_gateway_id is required when interconnect_mode = \"existing\". Run scripts/01-discover.ps1 to find the Direct Connect Gateway bound to your interconnect, or set interconnect_mode = \"create\" to have Terraform build one."
    }

    # Preview ceiling. Asking for anything else yields an opaque API rejection.
    precondition {
      condition     = !local.creating_interconnect || var.interconnect_bandwidth_mbps == 1000
      error_message = "Azure Multicloud Interconnect only offers 1 Gbps during preview, so interconnect_bandwidth_mbps must be 1000."
    }
  }
}

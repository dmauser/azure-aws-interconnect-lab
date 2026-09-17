##############################################################################
# Provider-managed interconnect (interconnect_mode = "create" only)
#
# Creates the transport itself: the Azure Multicloud Interconnect circuit and
# the paired AWS Interconnect connection. Everything here is count-gated, so
# the default "existing" mode produces zero resources in this file.
#
# Azure-first handshake:
#
#   azapi_resource.mci            Azure mints an activationKey for the circuit
#            |
#            | activationKey (sensitive: it authorises the pairing)
#            v
#   awscc_interconnect_connection AWS redeems the key, pairing the two clouds
#            |
#            | attach_point
#            v
#   aws_dx_gateway.lab            where the interconnect lands in AWS
#
# The DXGW is then reused by aws.tf's association, exactly as a bring-your-own
# DXGW would be.
##############################################################################

# The Azure side. azurerm cannot express this: its sku.tier validator accepts
# only Basic/Local/Premium/Standard and rejects MultiCloud before any API call,
# so the raw ARM surface is the only route.
resource "azapi_resource" "mci" {
  count = var.interconnect_mode == "create" ? 1 : 0

  type      = "Microsoft.Network/expressRouteCircuits@${var.azure_mci_api_version}"
  name      = "erc-${var.prefix}-aws"
  parent_id = azurerm_resource_group.lab.id

  # The hub region, not the resource group's region. An ARM resource may sit in
  # a different region from its resource group, and placing the circuit in the
  # region that matches its peering location is far less confusing than leaving
  # it in whatever region the VM happens to use.
  location = var.azure_hub_location

  # The MultiCloud tier is a preview construct absent from the provider's
  # embedded ARM schema, which would otherwise reject a valid body at plan time.
  schema_validation_enabled = false

  body = {
    sku = {
      name   = "MultiCloud_MeteredData"
      tier   = "MultiCloud"
      family = "MeteredData"
    }
    properties = {
      allowClassicOperations = false
      serviceProviderProperties = {
        serviceProviderName = "AWS"
        peeringLocation     = var.interconnect_peering_location
        bandwidthInMbps     = var.interconnect_bandwidth_mbps
      }
    }
  }

  # These tags are not decoration. The portal uses them to surface the circuit
  # under Multicloud Interconnect rather than as a plain ExpressRoute circuit.
  tags = merge(local.tags, {
    MultiCloudCircuit  = "true"
    MultiCloudProvider = "AWS"
    MultiCloudRegion   = var.interconnect_peering_location
  })

  # activationKey is only returned on api-version 2025-09-01 and later. See the
  # azure_mci_api_version variable for why lowering it fails silently.
  response_export_values = [
    "properties.activationKey",
    "properties.serviceProviderProvisioningState",
  ]

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

# The AWS attach point. An interconnect always lands on a Direct Connect
# Gateway, never directly on a VPC or VGW.
resource "aws_dx_gateway" "lab" {
  count = var.interconnect_mode == "create" ? 1 : 0

  name            = "dxgw-${var.prefix}"
  amazon_side_asn = tostring(var.dx_gateway_asn)
}

# The AWS side of the pair. hashicorp/aws has no resource for AWS Interconnect -
# multicloud, so this comes from awscc (Cloud Control's
# AWS::Interconnect::Connection).
resource "awscc_interconnect_connection" "lab" {
  count = var.interconnect_mode == "create" ? 1 : 0

  # AWS constrains this to ^[-a-zA-Z0-9_ ]+$ -- no angle brackets, parentheses
  # or punctuation beyond hyphen and underscore, so it cannot read "Azure <-> AWS".
  description = "Azure to AWS multicloud interconnect ${var.prefix}"

  # Redeeming the key is what pairs the clouds. bandwidth and remote_account are
  # deliberately omitted: they apply to the AWS-initiated flow and are mutually
  # exclusive with this one. Bandwidth is carried inside the key itself.
  activation_key = one(azapi_resource.mci[*].output.properties.activationKey)

  attach_point = {
    direct_connect_gateway = one(aws_dx_gateway.lab[*].id)
  }

  # The awscc provider has no default_tags, so local.tags is applied by hand and
  # reshaped into the key/value pairs this resource expects.
  tags = [for k, v in local.tags : { key = k, value = v }]
}

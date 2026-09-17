##############################################################################
# Naming / tagging
##############################################################################

variable "prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "mcilab"
}

variable "tags" {
  description = "Extra tags merged into the default tag set on both clouds."
  type        = map(string)
  default     = {}
}

##############################################################################
# Lab mode
##############################################################################

variable "interconnect_mode" {
  description = <<-EOT
    Where the provider-managed interconnect itself comes from. This is a
    DIFFERENT layer from create_interconnect, and the distinction matters:

      interconnect_mode   - who owns the CIRCUIT PAIR (Azure MCI circuit +
                            AWS Interconnect connection). The transport itself.
      create_interconnect - whether this lab ATTACHES to that transport
                            (ER connection + DXGW association).

    "existing" (default) - bring your own. You already created the Azure
        Multicloud Interconnect circuit and its paired AWS Interconnect
        connection, by hand or otherwise. Supply express_route_circuit_id and
        dx_gateway_id. Terraform never creates or destroys them.

    "create" - Terraform builds the pair for you, Azure-first:
        1. azapi creates the Azure MultiCloud circuit and reads back the
           activation key Azure mints for it.
        2. aws_dx_gateway creates the attach point.
        3. awscc_interconnect_connection redeems that activation key, which is
           what actually pairs the two clouds.

    COST WARNING: "create" is not free. Azure MCI carries no Azure service or
    egress charge during preview, but the AWS Interconnect connection is billed
    per port-hour at the requested bandwidth. "existing" stays the default so a
    first `terraform apply` can never quietly provision a billed 1 Gbps port.
  EOT
  type        = string
  default     = "existing"

  validation {
    condition     = contains(["existing", "create"], var.interconnect_mode)
    error_message = "interconnect_mode must be either \"existing\" or \"create\"."
  }
}

variable "create_interconnect" {
  description = <<-EOT
    Whether Terraform builds the two resources that actually join the clouds:
    the Azure ExpressRoute connection and the AWS Direct Connect gateway
    association.

    true  - build everything, end to end. The lab is live after one apply.

    false - "demo mode". Build both landing zones and the ExpressRoute gateway,
            but leave the clouds unjoined, so cross-cloud ping fails. Flip this
            to true and re-apply to complete the link in front of an audience.

    Demo mode still builds the ExpressRoute gateway, because that is the slow
    resource (~25 min) and nobody wants to watch it. What remains is the
    interesting part: the connection (~13 min) and the DXGW association.
  EOT
  type        = bool
  default     = true
}

##############################################################################
# Azure
##############################################################################

variable "azure_subscription_id" {
  description = <<-EOT
    Azure subscription that will own the lab AND that owns the existing
    Multicloud Interconnect circuit. No default on purpose: run
    scripts/00-configure to detect it and write terraform.tfvars.
  EOT
  type        = string
}

variable "azure_tenant_id" {
  description = <<-EOT
    Entra ID tenant of the subscription above. Leave null to let the azurerm
    provider infer it from your current az login.
  EOT
  type        = string
  default     = null
}

variable "azure_location" {
  description = <<-EOT
    Azure region for the SPOKE VNet and the Linux VM.

    This does NOT have to match the gateway region, and often cannot. Some
    subscriptions report every VM SKU as NotAvailableForSubscription at Location
    scope in the gateway's region, which is what forced the hub/spoke split
    here. Check before you change it:

      az vm list-skus -l <region> --size Standard_B1s --output table

    The ExpressRoute gateway cannot live here; see azure_hub_location.
  EOT
  type        = string
  default     = "eastus2"
}

variable "azure_hub_location" {
  description = <<-EOT
    Azure region for the HUB VNet and the ExpressRoute gateway.

    ER-AWS-Lab is a MultiCloud-tier circuit, which the platform treats as a
    LOCAL ExpressRoute circuit. A Local circuit can only be connected to the one
    designated Azure region for its peering location -- "useast" maps to East US.
    Connecting a gateway from any other region fails with:

      InvalidParameter: your circuit in useast cannot be connected to <region>
      on a Local circuit.

    MultiCloud tier has no Standard/Premium upgrade path, so this MUST be the
    region that matches your circuit's serviceProviderProperties.peeringLocation.
    scripts/00-configure reads that off the circuit and sets this for you.
    Gateways are not virtual machines, so a subscription's VM SKU restriction in
    this region does not apply here.
  EOT
  type        = string
  default     = "eastus"
}

variable "express_route_circuit_id" {
  description = <<-EOT
    Resource ID of an EXISTING Azure Multicloud Interconnect circuit.
    Passed as a plain string rather than looked up with a data source because
    the MultiCloud SKU tier is a preview construct.

    REQUIRED when interconnect_mode = "existing"; this lab then never creates or
    destroys the circuit. IGNORED when interconnect_mode = "create", where the
    circuit is built by azapi instead.

    No default on purpose: scripts/00-configure discovers it for you.
  EOT
  type        = string
  default     = null
}

variable "azure_vnet_cidr" {
  description = <<-EOT
    Spoke VNet address space (holds the Linux VM). Must not overlap the hub VNet,
    because the two are peered. Kept inside 10.100.0.0/16 so the AWS security
    group rule and the Azure/AWS non-overlap guardrail need no special casing.
  EOT
  type        = string
  default     = "10.100.1.0/24"
}

variable "azure_vm_subnet_cidr" {
  description = "Azure workload subnet, inside azure_vnet_cidr."
  type        = string
  default     = "10.100.1.0/24"
}

variable "azure_hub_vnet_cidr" {
  description = <<-EOT
    Hub VNet address space (holds only the GatewaySubnet). Must not overlap the
    spoke VNet.
  EOT
  type        = string
  default     = "10.100.0.0/24"
}

variable "azure_supernet_cidr" {
  description = <<-EOT
    Supernet covering both the hub and spoke VNets. Used for the AWS security
    group rule and the Azure/AWS overlap guardrail, so adding another Azure
    spoke inside this range needs no AWS-side change. ExpressRoute still
    advertises the individual VNet prefixes, not this supernet.
  EOT
  type        = string
  default     = "10.100.0.0/16"
}

variable "azure_gateway_subnet_cidr" {
  description = "GatewaySubnet, inside azure_hub_vnet_cidr. /27 is the documented minimum for an ExpressRoute gateway."
  type        = string
  default     = "10.100.0.0/27"
}

variable "azure_ergw_sku" {
  description = <<-EOT
    ExpressRoute virtual network gateway SKU. Standard is the cheapest
    ExpressRoute-capable SKU (~USD 0.19/hr) and is ~85% of this lab's cost.
  EOT
  type        = string
  default     = "Standard"
}

variable "azure_vm_size" {
  description = "Azure VM size. Standard_B1s is the cheapest burstable size with 1 GB RAM."
  type        = string
  default     = "Standard_B1s"
}

variable "azure_vm_admin_username" {
  description = "Admin username on the Azure VM."
  type        = string
  default     = "azureuser"
}

variable "azure_auto_shutdown_time" {
  description = "Daily auto-shutdown time for the Azure VM (HHmm, 24h). Set to null to disable."
  type        = string
  default     = "2000"
}

variable "azure_auto_shutdown_timezone" {
  description = "Windows timezone name for the auto-shutdown schedule."
  type        = string
  default     = "Central Standard Time"
}

##############################################################################
# AWS
##############################################################################

variable "aws_region" {
  description = "AWS region hosting the lab VPC. Must be the region local to the interconnect."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile (SSO or credentials) used by the aws provider."
  type        = string
  default     = "mcilab"
}

variable "aws_account_id" {
  description = <<-EOT
    Expected AWS account ID. Guards against applying into the wrong account.
    No default on purpose: scripts/00-configure detects it from your current
    AWS credentials.
  EOT
  type        = string
}

variable "dx_gateway_id" {
  description = <<-EOT
    ID of an EXISTING Direct Connect Gateway that the AWS Interconnect -
    multicloud connection is attached to. On AWS the interconnect attach point
    is ALWAYS a Direct Connect Gateway.

    REQUIRED when interconnect_mode = "existing"; discover it with
    scripts/01-discover.ps1. This lab then never creates or destroys the DXGW
    or the interconnect.

    IGNORED when interconnect_mode = "create", where a DXGW is created and used
    as the new connection's attach point.
  EOT
  type        = string
  default     = null
}

##############################################################################
# interconnect_mode = "create" only
##############################################################################

variable "interconnect_bandwidth_mbps" {
  description = <<-EOT
    Bandwidth of the interconnect pair, in Mbps. Azure Multicloud Interconnect
    offers 1 Gbps only during preview, so 1000 is the sole safe value today.
    Billed on the AWS side. Only used when interconnect_mode = "create".
  EOT
  type        = number
  default     = 1000
}

variable "interconnect_peering_location" {
  description = <<-EOT
    Interconnect peering location, as Azure names it (for example "useast").
    This is NOT an Azure region: it selects the physical facility where the two
    clouds meet, and it is what forces azure_hub_location, because a MultiCloud
    circuit behaves as a LOCAL circuit and only accepts a gateway from the one
    matching region. Only used when interconnect_mode = "create".
  EOT
  type        = string
  default     = "useast"
}

variable "azure_mci_api_version" {
  description = <<-EOT
    ARM API version used to create and read the MultiCloud circuit.

    Do not lower this without checking. The circuit's activationKey property --
    the token that pairs Azure with AWS -- is simply ABSENT from the response on
    2025-05-01 and earlier. It is not empty, it is not an error: the field is not
    returned at all, so the AWS side would be handed a null and the pairing would
    fail with no obvious cause. 2025-09-01 is the earliest version that returns it.
  EOT
  type        = string
  default     = "2025-09-01"
}

variable "dx_gateway_asn" {
  description = <<-EOT
    Amazon-side BGP ASN for the Direct Connect Gateway created in
    interconnect_mode = "create". 64512 is the default private ASN; it appears
    in the AS path Azure learns (12076-64512).
  EOT
  type        = number
  default     = 64512
}

variable "aws_vpc_cidr" {
  description = "AWS VPC address space. Must not overlap azure_supernet_cidr."
  type        = string
  default     = "10.200.0.0/16"
}

variable "aws_subnet_cidr" {
  description = "AWS workload subnet."
  type        = string
  default     = "10.200.1.0/24"
}

variable "aws_instance_type" {
  description = "EC2 instance type. t4g.nano (Graviton) is the cheapest general-purpose size."
  type        = string
  default     = "t4g.nano"
}

##############################################################################
# Access
##############################################################################

variable "my_public_ip" {
  description = <<-EOT
    Your public IP in CIDR form (e.g. 203.0.113.4/32) for the SSH allow rules.
    Leave null to auto-detect via https://ifconfig.me/ip.
  EOT
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = <<-EOT
    Existing SSH public key material to authorise on both VMs.
    Leave null to generate a lab-scoped RSA 4096 key into ../ssh/.
  EOT
  type        = string
  default     = null
}

##############################################################################
# Tuning
##############################################################################

variable "mtu" {
  description = <<-EOT
    MTU applied to both VMs. ExpressRoute supports a maximum TCP/UDP payload of
    1400 bytes and does not support fragmentation, so 1400 avoids PMTU blackholes.
  EOT
  type        = number
  default     = 1400
}

##############################################################################
# Observability
##############################################################################

variable "enable_observability" {
  description = <<-EOT
    Create the VNet flow log, Log Analytics workspace and Network Watcher
    Connection Monitor. Set false to run the lab as a pure connectivity test
    with no ingestion cost.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = <<-EOT
    Create the VNet flow log and its storage account. Requires
    enable_observability = true.

    Defaults to FALSE because flow logs write to blob storage using SHARED KEY
    authentication, and many subscriptions deny that through Azure Policy
    ("Storage accounts should prevent shared key access"). Where that policy
    applies, the storage account cannot be created at all and the apply fails
    with:

      403 KeyBasedAuthenticationNotPermitted

    There is no Entra-only alternative for flow logs today. Set this to true
    only if you know shared key access is permitted in your subscription.
    Leaving it false still gives you the Log Analytics workspace and the
    Connection Monitor, which is the part that actually proves the cross-cloud
    path.
  EOT
  type        = bool
  default     = false
}

variable "enable_traffic_analytics" {
  description = <<-EOT
    Enrich the flow logs with Traffic Analytics. Requires enable_observability.
    Adds Log Analytics ingestion cost on top of raw flow log storage.
  EOT
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = <<-EOT
    Days of raw flow logs retained in the storage account. Kept short because
    this is a lab; the workspace retention is separate and fixed at 30 days,
    which is the minimum billable value.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.flow_log_retention_days >= 1 && var.flow_log_retention_days <= 365
    error_message = "flow_log_retention_days must be between 1 and 365."
  }
}

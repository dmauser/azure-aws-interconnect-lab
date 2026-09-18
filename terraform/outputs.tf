output "azure_vm_public_ip" {
  description = "Public IP of the Azure VM (SSH entry point)."
  value       = azurerm_public_ip.vm.ip_address
}

output "azure_vm_private_ip" {
  description = "Private IP of the Azure VM - this is the address AWS must reach."
  value       = azurerm_network_interface.vm.private_ip_address
}

output "aws_vm_public_ip" {
  description = "Public IP of the AWS VM (SSH entry point)."
  value       = aws_instance.vm.public_ip
}

output "aws_vm_private_ip" {
  description = "Private IP of the AWS VM - this is the address Azure must reach."
  value       = aws_instance.vm.private_ip
}

output "ssh_private_key_path" {
  description = "Private key authorised on both VMs."
  value       = local.private_key_path
}

output "allowed_public_ip" {
  description = "Public IP allowed to SSH in. Re-apply if your IP changes."
  value       = local.my_cidr
}

output "dx_gateway_id" {
  description = "Direct Connect Gateway the lab VGW was associated with, whether supplied or created."
  value       = local.dxgw_id
}

output "express_route_circuit_id" {
  description = "Multicloud Interconnect circuit the lab gateway was connected to, whether supplied or created."
  value       = local.circuit_id
}

output "interconnect_mode" {
  description = "Whether the interconnect pair was brought by the operator (\"existing\") or built by Terraform (\"create\")."
  value       = var.interconnect_mode
}

output "interconnect_connection_id" {
  description = "AWS Interconnect - multicloud connection ID (mcc-...). Null unless interconnect_mode = \"create\"."
  value       = one(awscc_interconnect_connection.lab[*].connection_id)
}

# The activation key authorises pairing this Azure circuit with an AWS account,
# so it is treated as a credential: sensitive, and never echoed by the scripts
# or committed anywhere.
output "interconnect_activation_key" {
  description = "Activation key minted by Azure and redeemed on the AWS side. Null unless interconnect_mode = \"create\"."
  value       = one(azapi_resource.mci[*].output.properties.activationKey)
  sensitive   = true
}

output "interconnect_built" {
  description = "Whether Terraform joined the two clouds, or left that for a live demo."
  value       = var.create_interconnect
}
# Consumed by scripts/02-verify and scripts/99-destroy so that resource names
# live in exactly one place. Hardcoding them in the scripts meant a prefix
# change silently broke verification against names that no longer existed.
output "resource_names" {
  description = "Names of the resources the helper scripts need to address."
  value = {
    resource_group  = azurerm_resource_group.lab.name
    er_gateway      = azurerm_virtual_network_gateway.ergw.name
    er_connection   = var.create_interconnect ? azurerm_virtual_network_gateway_connection.ergw[0].name : null
    hub_vnet        = azurerm_virtual_network.hub.name
    spoke_vnet      = azurerm_virtual_network.lab.name
    azure_vm        = azurerm_linux_virtual_machine.vm.name
    aws_vm          = aws_instance.vm.tags["Name"]
    aws_route_table = aws_route_table.vm.tags["Name"]
    aws_vpn_gateway = aws_vpn_gateway.lab.id
    aws_vpc         = aws_vpc.lab.id
    prefix          = var.prefix

    probe_enabled         = var.enable_latency_probe
    probe_container_group = var.enable_latency_probe ? azurerm_container_group.probe[0].name : null
    probe_subnet          = var.enable_latency_probe ? azurerm_subnet.probe[0].name : null
    probe_dashboard_port  = var.probe_dashboard_port
  }
}

output "probe_dashboard_url" {
  description = <<-EOT
    Latency dashboard. Served from the spoke VM's public IP and locked by NSG to
    my_public_ip, because the hub prober only ever gets a private address and
    this subscription cannot host a Container App or App Service in East US.
  EOT
  value       = var.enable_latency_probe ? "http://${azurerm_public_ip.vm.ip_address}:${var.probe_dashboard_port}/" : null
}

output "probe_vantage_points" {
  description = "Where each prober runs, and therefore what its numbers mean."
  value = var.enable_latency_probe ? {
    hub   = "azure-hub-${var.azure_hub_location} (Container Instances, beside the ExpressRoute gateway - the honest interconnect number)"
    spoke = "azure-spoke-${var.azure_location} (VM - includes the inter-region hop the region split forces)"
  } : null
}

# Same rationale as resource_names: the helper scripts should never carry their
# own copy of an identifier or a CIDR that Terraform already knows.
output "azure_subscription_id" {
  description = "Subscription the lab was deployed into."
  value       = var.azure_subscription_id
}

output "aws_profile" {
  description = "AWS named profile the lab was deployed with."
  value       = var.aws_profile
}

output "cidrs" {
  description = "Address spaces the verification script asserts on."
  value = {
    azure_supernet = var.azure_supernet_cidr
    azure_hub      = var.azure_hub_vnet_cidr
    azure_spoke    = var.azure_vnet_cidr
    aws_vpc        = var.aws_vpc_cidr
    aws_subnet     = var.aws_subnet_cidr
  }
}

output "next_steps" {
  description = "Copy-paste commands to validate the private cross-cloud path."
  value       = <<-EOT
    ${var.create_interconnect ? "" : "\n    !! DEMO MODE - the clouds are NOT joined yet.\n    !! Cross-cloud ping is EXPECTED to fail until you run:\n    !!   terraform apply -var create_interconnect=true\n    !! or: pwsh scripts/03-interconnect.ps1 -Action Connect\n"}
    ── SSH ────────────────────────────────────────────────────────────────────
    Azure : ssh -i "${local.private_key_path}" ${var.azure_vm_admin_username}@${azurerm_public_ip.vm.ip_address}
    AWS   : ssh -i "${local.private_key_path}" ec2-user@${aws_instance.vm.public_ip}

    ── Test the private path (run from inside each VM) ─────────────────────────
    From Azure -> AWS : ping -c 4 ${aws_instance.vm.private_ip}
    From AWS -> Azure : ping -c 4 ${azurerm_network_interface.vm.private_ip_address}

    MTU probe (1400 MTU => 1372 byte payload must succeed, 1373 must fail):
      ping -M do -s 1372 -c 2 <remote-private-ip>

    Confirm the path never leaves private space:
      traceroute -n <remote-private-ip>

    Throughput (server side first, then client):
      iperf3 -s
      iperf3 -c <remote-private-ip> -t 10

    ── Control plane checks (run from your workstation) ────────────────────────
    pwsh scripts/02-verify.ps1

  EOT
}

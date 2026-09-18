# Project Context

- **Owner:** Scribe
- **Project:** az-mcloud-ix — Terraform + PowerShell lab proving private VM-to-VM connectivity between Azure and AWS over an AWS Interconnect – multicloud link paired with an Azure Multicloud Interconnect (Preview) circuit.
- **Stack:** Terraform (providers: `azapi`, `azurerm`, `awscc`, `hashicorp/aws`), PowerShell 7 (primary) with bash parity for four scripts, Ubuntu/Amazon Linux VMs via cloud-init.
- **Created:** 2026-09-18T14:50:58Z

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-09-18T14:50:58Z — Day-1 seed (Multicloud Network Engineer)

- The path is: Azure spoke VNet → VNet peering with gateway transit → hub VNet `GatewaySubnet` → ExpressRoute gateway → ExpressRoute connection → circuit → AWS Direct Connect gateway → VGW → VPC subnet.
- **This is not a partner/ExpressRoute-reseller setup.** There is no BGP session, VLAN tag, MD5 key, link-local peering, or private VIF for us to configure — the underlay is provider-managed. Do not add resources that try to configure it.
- On AWS the interconnect's attach point is always a Direct Connect Gateway; read it from `attachPoint.directConnectGateway` rather than assuming.
- ExpressRoute advertises the spoke prefix to AWS automatically via gateway transit — that is why the hub/spoke split works.
- Use `propagating_vgws` on the AWS route table, not the standalone propagation resource (it races VGW attachment).
- Never attach an NSG or a default-route UDR to `GatewaySubnet`.
- ExpressRoute-type gateways get a platform-managed public IP; setting `ip_configuration.public_ip_address_id` is rejected.
- MTU is 1400 on both VMs (a `lab-mtu.service` unit is installed by cloud-init). Probe with `ping -M do -s 1372` (must pass) / `-s 1373` (must fail).
- A failed ExpressRoute connection can leave an orphan that blocks gateway deletion even though it never reached state; it is removed with the VPN-connection delete command despite being an ExpressRoute connection.
- Connection Monitor probes the Azure VM → AWS VM **private** IP over ICMP and TCP/22 with traceroute; it catches asymmetric routing that a plain ping hides.
- Flow logs attach to the spoke VNet only — the ER gateway is a platform-managed VMSS whose NICs are not exposed.
- Reference material: `docs/control-plane.md` (healthy route dumps), `docs/sample-routes.txt`, `scripts/04-routes.ps1` (read-only dump both ends).
- **Validation rule:** cloud-platform facts get validated against Microsoft Learn (Azure) or AWS docs (AWS) before I assert them; the docs win over recollection.

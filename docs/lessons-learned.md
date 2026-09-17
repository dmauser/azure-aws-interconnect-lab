# Lessons learned

Everything below was learned by hitting it. Ordered by how much time it cost.

> Building the lab? Start at the [README](../README.md). This document is the
> post-mortem — read it when something breaks, or before you build the same thing
> somewhere else.

## 1. A `MultiCloud` circuit is a **Local** circuit — the gateway region is not negotiable

This was the single biggest time sink: **three gateway builds, ~75 minutes of pure
provisioning**, before the real constraint surfaced.

`ER-AWS-Lab` reports `sku.tier = MultiCloud`. Nothing in the circuit's properties says
"Local". But the control plane evaluates it as a Local circuit, and a Local circuit
attaches only to the **one designated Azure region** for its peering location
(`useast` → **East US**). The truth only appears when the *connection* is created:

```
Status: "InvalidParameter"
Message: "The creation of the virtual network gateway connection failed because your
circuit in useast cannot be connected to East US 2 on a Local circuit. A Local
ExpressRoute circuit can only connect to a designated Azure region. Please upgrade the
circuit to Standard SKU or Premium SKU."
```

Three traps stacked here:

- **The gateway succeeds in the wrong region.** `westus` and `eastus2` both built a
  perfectly healthy ExpressRoute gateway in ~25 min, *then* failed at the connection.
  You pay the full gateway build time before learning anything.
- **The suggested fix is a dead end.** There is no Standard/Premium variant of the
  MultiCloud tier, so "upgrade the circuit" is not actionable.
- **The docs point the wrong way.** The
  [MCI limits page](https://learn.microsoft.com/azure/multicloud-interconnect/availability-limits)
  lists Australia East / East US / Germany West Central / West US as supported regions,
  which reads as "any of these four works". For a *given* circuit, only the region
  matching its peering location works.

> **Rule of thumb:** for a Multicloud Interconnect circuit, put the ExpressRoute gateway
> in the Azure region that matches the circuit's `serviceProviderProperties.peeringLocation`.
> Don't infer it from the supported-regions list.

## 2. The VM had to go in East US 2 — East US had no capacity for it

**The Azure VM in this lab lives in East US 2, and that is not a design preference — it
is forced.** East US could not give the subscription a VM at all.

`Standard_B1s` failed in `eastus` with `SkuNotAvailable`. Checking further showed **all
1420 VM sizes** in `eastus` were blocked for this subscription — at `type: Location`, not
`type: Zone`:

```powershell
az vm list-skus -l eastus --resource-type virtualMachines `
  --query "[?name=='Standard_B1s'].restrictions"
```

East US is one of Azure's oldest and most heavily subscribed regions, and it routinely
runs out of headroom. When it does, the platform stops offering SKUs to subscriptions
that have no existing footprint there, and it surfaces as a *restriction* rather than as
an explicit "region is full" message. That is why the error reads like an entitlement
problem when the underlying cause is capacity.

Two things to take away:

- **Check which restriction `type` you're looking at.** `type: Zone` is routine and
  harmless for a non-zonal VM — it just means "not in that availability zone". Only
  `type: Location` means the subscription genuinely cannot deploy in the region at all.
- **Don't wait on a quota request.** This is not quota, so raising quota does not clear
  it. The realistic options are to pick a different region (what this lab does), or to
  ask support to allow-list the subscription in that region, which is slow.

Since the VM has to move but the gateway cannot (lesson 1), the two regions end up
different — which is exactly what forces the hub/spoke shape in lesson 3.

> **This is subscription- and time-specific.** Yours may well be able to build a VM in
> East US, in which case you can collapse hub and spoke into a single VNet. Check first:
>
> ```powershell
> az vm list-skus -l eastus --size Standard_B1s --all -o table
> ```

## 3. The two constraints collide — hence hub/spoke

Gateway *must* be in East US (lesson 1). The VM *could not* be in East US (lesson 2).

The resolution: **gateways are not virtual machines**, so the VM capacity restriction
doesn't apply to them. Put the ExpressRoute gateway in an East US hub VNet with nothing
else in it, put the VM in an **East US 2** spoke, and peer them with
`allow_gateway_transit` + `use_remote_gateways`. ExpressRoute then advertises the spoke
prefix to AWS automatically. Cost delta is cross-region peering data transfer — pennies
for a lab.

This is worth remembering generally: **a workload region and a connectivity region do not
have to be the same region.**

## 4. Terraform state and Azure can desynchronise badly after a failed apply

Several distinct failures, all from the same root cause — a partially-applied change:

- **Deleting and recreating a resource group in one apply races itself.** The RG delete
  returned "complete", Terraform immediately recreated it, and Azure's backend was still
  tearing down the old RG — which deleted the newly created children. The tell was an RG
  create taking 43s instead of ~2s. Newly created public IPs vanished with
  `Provider produced inconsistent result after apply ... Root object was present, but now absent`.
- **Subnet IDs are region-independent**, so when the VNet moved regions Terraform saw *no
  diff* on `azurerm_subnet` and never recreated the subnets. The VNet came up with zero
  subnets and the gateway failed with `InvalidResourceReference`.
- **The VNet silently dropped out of state** across failed applies, so the next apply
  tried to create it and hit `already exists ... needs to be imported`.

What actually worked:

```powershell
terraform apply -refresh-only -auto-approve   # resync state with reality
terraform import <addr> <resource-id>         # re-adopt orphans
terraform plan -out=tfplan                    # save the plan
terraform apply tfplan                        # apply the SAVED plan
```

**Apply a saved plan file after a failed run.** `terraform apply -auto-approve` re-plans
from scratch, and if state drifted it will happily try to recreate things that exist.
When a region changes, deleting the RG out-of-band and waiting for it to be *fully* gone
(`az group exists` → `false`) is more reliable than letting one apply delete and recreate it.

## 5. Azure injects `ip_tags` that force an infinite replacement loop

This subscription stamps `ip_tags = { FirstPartyUsage = "/Unprivileged" }` onto public
IPs. Terraform reads it as drift, tries to remove it, and `ip_tags` forces replacement —
so **every** plan wants to replace the public IP. The destroy then fails anyway:

```
PublicIPAddressCannotBeDeleted: ... still allocated to resource .../nic-mcilab-vm
```

Fix:

```hcl
lifecycle {
  ignore_changes = [ip_tags]
}
```

## 6. A failed ExpressRoute connection leaves an orphan that blocks gateway deletion

The failed `conn-mcilab-to-aws` was never written to Terraform state, but it *did* exist
in Azure. Deleting the gateway then failed with `VirtualNetworkGatewayCannotBeDeleted`.
Remove the orphan first:

```powershell
az network vpn-connection delete -g rg-mcilab-azure -n conn-mcilab-to-aws
```

Note the command is `vpn-connection` even for an ExpressRoute connection.

## 7. VNet flow logs need storage **shared keys** — which policy often forbids

The apply that built this lab succeeded on every resource on the critical path and failed
on exactly one: `azurerm_storage_account.flowlogs`.

```
403 Key based authentication is not permitted on this storage account.
KeyBasedAuthenticationNotPermitted
```

The subscription carries an Azure Policy that sets `allowSharedKeyAccess = false` on
storage accounts. That is a good default — but **VNet flow logs write to the storage
account with the account key**, and there is no Entra-ID-only alternative for the flow
log writer. Microsoft-managed identity is not an option for this data path. So on a
subscription with that policy, flow logs simply cannot be enabled to storage.

Two things made this worse than it had to be:

- **The failure is sticky.** The account is created before the provider tries to read
  its queue properties, so the resource lands in state in a state Terraform then cannot
  *refresh* — every later `plan` fails with the same 403 before it can produce a plan.
  Recovering means `terraform state rm 'azurerm_storage_account.flowlogs[0]'` followed by
  `az storage account delete`, not just flipping a variable.
- **It took the wrong things down with it.** Flow logs were originally gated on the same
  `enable_observability` switch as Log Analytics and Connection Monitor, so one blocked
  resource poisoned the whole observability stack.

The fix is a **separate switch**, defaulted off:

```hcl
enable_observability = true   # Log Analytics + Connection Monitor  (works everywhere)
enable_flow_logs     = false  # VNet flow logs -> storage           (needs shared keys)
```

Connection Monitor is the better signal for this lab anyway: it measures the actual
cross-cloud path continuously, whereas flow logs only record that packets happened.

> **Check before you enable it:**
> `az policy assignment list --query "[?contains(displayName,'shared key')]"`, or simply
> try `az storage account create ... --allow-shared-key-access true` and see if it is denied.

## 8. Small things that still cost real time

| Trap | Reality |
|---|---|
| `aws ... -o json` | **AWS CLI needs `--output json`.** `-o` is Azure-CLI-only and fails with `Unknown options: -o, json`. Cost the most debugging per character of any item here. |
| `aws interconnect list-connections` field names | Returns `id`, not `name` or `connectionId`. The attach point is `attachPoint.directConnectGateway`. |
| `terraform destroy -target=azurerm_x.y` in PowerShell | PowerShell mangles it into `-target=azurerm_x`. Quote the whole argument: `'-target=azurerm_x.y'`. |
| ER gateway `public_ip_address_id` | Rejected by azurerm 4.x — ExpressRoute gateways get a platform-managed public IP. Also saves ~$4/mo. |
| `aws_vpn_gateway_route_propagation` | Races VGW attachment and fails with `couldn't find resource`. Use `propagating_vgws = [...]` inline on `aws_route_table` instead. |
| AWS security group naming | `name` cannot begin with `sg-`. The `Name` *tag* can. |
| MTU | ExpressRoute caps TCP/UDP payload at 1400 bytes and does not fragment. Clamp both VMs to MTU 1400 and probe with `ping -M do -s 1372` (pass) / `-s 1373` (fail). |
| `GatewaySubnet` | Never attach an NSG or a `0.0.0.0/0` UDR to it. |
| Gateway timing | ~25 min to create, ~9 min to delete. Set `timeouts` generously and expect to wait. |

## 9. What was right from the start

Worth recording so it isn't re-litigated:

- **No BGP, VLAN, MD5, or 169.254.x.x peering anywhere.** The managed interconnect owns
  the underlay. Every instinct from a Megaport/Equinix ExpressRoute build is wrong here.
- **The AWS attach point is always a Direct Connect Gateway**, already created and bound
  to the interconnect. Reuse it; never try to create it.
- **VGW over Transit Gateway** — DXGW→VGW association is free, a TGW attachment is ~$36/mo.
- **Discovery before Terraform.** `01-discover.ps1` supplied the DXGW id, the circuit id
  and the "zero existing gateway connections" check that the preview limit requires.


---

## Gotchas quick reference

- **MTU 1400** on both VMs; `lab-mtu.service` handles it.
- **Never** put an NSG or `0.0.0.0/0` UDR on `GatewaySubnet`.
- **The AWS prefix is learned, not static** — `propagating_vgws` on the VPC route table.
- **The gateway must be in `eastus`; the VM must not be.** See
  [Why hub/spoke](../README.md#why-hubspoke-instead-of-one-vnet).
- **Your public IP is auto-detected** via `ifconfig.me` and pinned into the NSG and
  security group. If it changes, re-run `terraform apply` or set `my_public_ip`.
- **AWS CLI uses `--output json`, not `-o json`.**
- **The ExpressRoute gateway takes ~25 min to create.** Timeouts are set to 90m.
- **`enable_flow_logs` defaults to `false`** — flow logs require storage shared-key
  access, which many subscriptions deny by policy. Log Analytics and Connection Monitor
  are on a separate switch (`enable_observability`) and are unaffected.

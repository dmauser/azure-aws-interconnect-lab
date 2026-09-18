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

**Re-verified later, when the latency probe was added:** still 1420 of 1420 SKUs
restricted at `type: Location`. Months apart, same answer. Treat this as structural for
this subscription, not as a transient blip worth retrying.

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

## 4. The East US compute hunt: ACA inherits the VM capacity wall, App Service does not

Adding the [latency probe](../README.md#latency-probe) needed **something that runs code
in East US**, beside the ExpressRoute gateway, because the whole point was to measure the
path from as close to the circuit as possible. Lesson 2 already ruled out a VM. The
assumption was that some PaaS compute would sidestep a VM capacity restriction.

**Two of the three candidates did not.** The order they were tried in, and what each
actually said:

| Candidate | Result | The signal |
|---|---|---|
| Another VM | Impossible | 1420/1420 SKUs restricted, `type: Location`. |
| **Azure Container Apps** | **Blocked — capacity** | Environment creation runs for **~6 minutes**, then HTTP 400 `AKSCapacityHeavyUsage`: *"AKS is experiencing heavy usage in region eastus"*. |
| **Azure App Service** | **Blocked — quota** | P0v3, B1 and S1 all fail immediately with *"Operation cannot be completed without additional quota … Current Limit (`<sku>` VMs): 0"*. |
| **Azure Container Instances**, VNet-injected | **Works** | Deploys into a delegated subnet in the hub VNet and reaches the AWS private IP over ExpressRoute. |

Three things here cost real time.

**Container Apps is AKS underneath, so it inherits the VM capacity wall.** This was the
genuine surprise. ACA presents as serverless PaaS with no node concept in the API, which
strongly implies it is insulated from regional VM capacity. It is not — a managed
environment is backed by an AKS cluster, and when the region cannot hand out compute, the
environment cannot be created either. **If a region cannot give you a VM, assume it also
cannot give you a Container Apps environment until proven otherwise.**

The misleading part is the shape of the failure. It is not an instant rejection like a
`SkuNotAvailable`; it spends **six minutes provisioning first**, which reads as success
right up until it isn't. Two of those six-minute waits were spent assuming the first was
a transient blip.

**App Service failed for a completely different reason wearing similar clothes.** "Current
Limit (`<sku>` VMs): 0" also mentions VMs and also blocks the deployment — but it is
**quota**, not capacity. That distinction matters: unlike the VM and ACA cases, a quota
request could in principle clear it. Read the noun in the error. `Current Limit … 0` is
quota; `restrictions: [{type: Location}]` and `HeavyUsage` are capacity.

**Container Instances with VNet injection was the one that worked**, and it brought its
own constraints:

- **`NET_RAW` is granted.** A raw ICMP socket opens successfully, so true ICMP ping works
  from ACI. Unprivileged ICMP *datagram* sockets are denied — `ping_group_range` is not
  set in the container's namespace — which is irrelevant once raw sockets are available,
  but it will mislead you if you test with a `ping` binary that prefers the datagram path.
- **The subnet must be delegated** to `Microsoft.ContainerInstance/containerGroups` before
  the group will deploy, and once delegated it can hold nothing else.
- **A VNet-injected container group gets a private IP only** — there is no public ingress.
  Fine for a prober, which is why the collector and dashboard had to stay on the East US 2
  VM. Microsoft also recommends a **/24 or larger** subnet and warns that smaller ones can
  fail "subnet full"; this lab runs a `/27` for one 0.5-vCPU group and it is reliable, but
  that is below the documented recommendation.
- **ExpressRoute reachability worked first try** to the AWS EC2 private IP `10.200.1.219`.
- **The first samples are garbage.** The very first probe from a freshly created container
  group returned `No route to host`, and one early sample came back at **1636 ms** before
  the numbers settled into the 3–4 ms band. VNet route programming takes a few seconds
  after the group starts. This looks exactly like a broken path — it is not. **Discard
  warmup samples**, or you are benchmarking Azure provisioning rather than the
  interconnect.
- **Docker Hub does not work from here.** Any `index.docker.io` pull fails with
  `RegistryErrorResponse`. Microsoft documents this: anonymous Docker Hub pulls are
  rate-limited and ACI's egress IPs are shared, so the limit is routinely already spent
  before your pull lands. It is not a retry problem and not a tag problem — it is a
  registry problem. The probe uses **`mcr.microsoft.com/azurelinux/base/python:3.12`**;
  any `mcr.microsoft.com` image pulls without authentication. Wanting a specific Docker
  Hub image means supplying registry credentials or mirroring into ACR, both of which cost
  more than changing base image.

> **The useful generalisation:** in a capacity-constrained region, rank compute by how
> much VM it hides. VMs and AKS-backed services (ACA) fail on capacity; App Service fails
> on quota; Container Instances got through. Test the cheapest candidate first and read
> the error's noun before assuming the next one will behave differently.

## 5. Terraform state and Azure can desynchronise badly after a failed apply

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

## 6. Azure injects `ip_tags` that force an infinite replacement loop

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

## 7. A failed ExpressRoute connection leaves an orphan that blocks gateway deletion

The failed `conn-mcilab-to-aws` was never written to Terraform state, but it *did* exist
in Azure. Deleting the gateway then failed with `VirtualNetworkGatewayCannotBeDeleted`.
Remove the orphan first:

```powershell
az network vpn-connection delete -g rg-mcilab-azure -n conn-mcilab-to-aws
```

Note the command is `vpn-connection` even for an ExpressRoute connection.

## 8. VNet flow logs need storage **shared keys** — which policy often forbids

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

### Follow-up: the policy was Modify, not Deny — and a tag exempts it

Re-testing later showed the control in this tenant is a **Modify**-effect policy, which
makes it nastier than "denied":

```powershell
az storage account create ... --allow-shared-key-access true   # succeeds, exit code 0
az storage account show ... --query allowSharedKeyAccess       # false
```

The create **succeeds** and is silently rewritten. `az deployment group validate` also
returns `"error": null`, because there is nothing to deny. Neither the exit code nor an
ARM validate will tell you anything is wrong — **only reading the property back does.**

Tagging the account `SecurityControl = Ignore` exempts it from the policy. Measured
side-by-side in `rg-mcilab-azure`, same command, same region, only the tag differing:

| Storage account | Requested | `allowSharedKeyAccess` read back |
|---|---|---|
| untagged | `true` | **`false`** |
| `SecurityControl=Ignore` | `true` | **`true`** |

So `enable_flow_logs = true` is viable in this subscription, and
`azurerm_storage_account.flowlogs` carries the tag plus an explicit
`shared_access_key_enabled = true` so that a future `plan` shows drift if the exemption
ever stops applying.

Two caveats worth keeping:

- **`SecurityControl: Ignore` is not a documented Azure feature.** It returns zero hits
  across Microsoft Learn. It is a Microsoft-internal convention honoured by internal
  policy definitions, so it is meaningless in a tenant that does not look for it — and it
  does nothing at all against a *Deny*-effect implementation of the same control.
- **It is an exemption from a security control**, appropriate for a throwaway lab and not
  a pattern to carry into anything real.

## 9. ExpressRoute FastPath is a dead end for this lab, twice over

Once the [latency probe](../README.md#latency-probe) put a number on the region split —
**~4 ms of RTT at p50, roughly half the total** — the obvious next question was whether
ExpressRoute **FastPath** could claw it back. FastPath is exactly the right-shaped idea:
it bypasses the ExpressRoute gateway in the data path, and "VNet peering over FastPath"
specifically targets the spoke→hub→gateway detour this lab is forced into.

It does not apply here, and it fails **two independent eligibility checks**, so there is
no partial workaround:

| Requirement | This lab | Verdict |
|---|---|---|
| Gateway SKU must be `UltraPerformance`, `ErGw3AZ`, `ErGwScale` ≥ 10 scale units, or a vWAN ER gateway ≥ 5 scale units | `ergw-mcilab` is **`Standard`** | ✗ |
| **VNet peering over FastPath** requires **ExpressRoute Direct** | The circuit is a **provider** circuit (Multicloud Interconnect) | ✗ |

The first is money: an `UltraPerformance` gateway is dramatically more expensive than
`Standard`, and `Standard` is already ~85% of this lab's bill. The second cannot be bought
at all — ExpressRoute Direct is a different product from a provider-managed circuit, and
a Multicloud Interconnect circuit is by definition the latter.

The misleading signal is the FastPath documentation itself: the feature matrix lists
peering-over-FastPath as a supported scenario with no gateway-side caveat visible until
you cross-read the ExpressRoute Direct column. It looks available, and it reads as a
configuration flag, which is why it is worth writing down as closed.

> **Do not re-propose FastPath as a latency fix for this topology.** If the ~4 ms
> matters, the lever is the region split (lesson 3), not the gateway — collapse hub and
> spoke into one VNet on a subscription that can actually build a VM in the gateway
> region. Source:
> [About ExpressRoute FastPath](https://learn.microsoft.com/azure/expressroute/about-fastpath).

## 10. `interconnect_mode = "create"` had never been run end to end — and was broken three ways

The lab defaults to `interconnect_mode = "existing"`, so the `create` path — where
Terraform builds the MCI circuit and the AWS Interconnect itself — went a long time
without ever being run end to end. It did not work. Standing up a second, fully
independent instance of the lab in a clean subscription surfaced three separate defects,
each hidden behind the one before it.

### Bug one: the circuit create is rejected outright

`azapi_resource.mci` sent a body carrying only `serviceProviderProperties`. ARM rejects
that in about **one second**:

```
MultiCloudCircuitActivationKeyOrPartnerAccountIdMissing
Interconnect provider circuit creation requires one of ActivationKey or
PartnerAccountId to be specified.
```

The two fields are not alternatives you may pick between — they **select the direction of
the handshake**, and are mutually exclusive:

| Input | Flow | Who mints the key |
|---|---|---|
| `properties.partnerAccountId` | **Azure-first** — what this lab does | Azure mints it, redeemable only by that AWS account |
| `properties.activationKey` | AWS-first | AWS minted it; Azure redeems it |

The fix is one line, and the path matters:

```hcl
properties = {
  allowClassicOperations = false
  partnerAccountId       = var.aws_account_id   # NOT inside serviceProviderProperties
  serviceProviderProperties = { ... }
}
```

Verified by PUTting a throwaway circuit directly: it provisioned to `Succeeded` and
`properties.activationKey` came back as a 360-character value — exactly what
`awscc_interconnect_connection` redeems.

**Why inspecting a working circuit does not reveal this.** A `GET` on an
already-paired circuit returns `activationKey` but **no `partnerAccountId`**. It is a
create-time input, not round-tripped state, so reading a healthy circuit to infer the
required body actively misleads you — especially if that circuit was built the AWS-first
way, where the field genuinely was never set.

### Two debugging lessons that cost more than the fix

**Terraform holds diagnostics until the whole apply settles.** The circuit failed at
19:08:54, but nothing was printed until the ExpressRoute gateway finished ~25 minutes
later. The tell is in the progress log:

```
azapi_resource.mci[0]: Creating...          <- and then never again
azurerm_virtual_network_gateway.ergw: Still creating... [12m50s elapsed]
```

A resource that says `Creating...` and then **never emits a `Still creating...` line**
has already finished or failed. Everything still in flight keeps ticking every 10s.

**Read the Azure activity log instead of waiting.** `az monitor activity-log list` gives
you the real ARM error while the apply is still running, which turns a 25-minute blind
wait into a 30-second answer. Note `eventTimestamp` comes back as a `DateTime`, not a
string, so `.Substring()` on it fails.

### The second `create`-mode bug: the pairing is asynchronous on both sides

Fixing `partnerAccountId` exposed the next one. The circuit and the AWS interconnect both
create in seconds, but the *pairing* does not:

| Time | Event |
|---|---|
| 14:47 | Circuit created (15s), `awscc_interconnect_connection` created (14s) |
| 14:47 | AWS connection `state: pending`, Azure `serviceProviderProvisioningState: Provisioning` |
| 15:00 | AWS connection reaches `available` |
| 15:01 | Azure circuit reaches `Provisioned` |

Terraform builds the ExpressRoute connection as soon as the circuit exists, which lands
squarely inside that ~15 minute window and fails:

```
ServiceProviderNotProvisioned
The current cross connection provisioning state 'NotProvisioned' of this
service key '<guid>' prevents this operation.
```

**`depends_on` does not fix this.** It orders the API *calls*, and the AWS call returns
long before the pairing finishes. Something has to actually check the state.

The fix is `data.azapi_resource.mci_state` — a re-read of the circuit that `depends_on`
the AWS connection — feeding a `precondition` on the ExpressRoute connection. So
`interconnect_mode = "create"` is a **two-apply flow**: the first apply builds everything
and stops with a plain-English message, and a second apply ~15 minutes later attaches the
connection. Nothing needs cleaning up in between.

> **Do not "fix" this with a `local-exec` waiter.** That was tried first and is worse than
> nothing — see below.

### `az ... wait --custom` is not a trustworthy waiter

The obvious fix was `az network express-route wait --custom "…=='Provisioned'"` in a
`local-exec`. It fails in two independent ways, and **both failure modes look like
success**:

| Test | Expected | Actual |
|---|---|---|
| `az network express-route wait --custom` with a **true** condition | returns immediately | ran the **full 120s timeout**, exit 0 |
| same, with an **impossible** condition | non-zero exit | `{}`, **exit 0** |
| `az resource wait --custom` with a **true** condition | returns immediately | **2s, exit 0** ✅ |
| `az resource wait --custom` with an **impossible** condition | non-zero exit | `{}`, **exit 0** after timeout |

Two separate lessons:

1. **`az network express-route wait --custom` never matches.** `az resource wait` against
   the raw ARM JSON (`properties.serviceProviderProvisioningState`) does work — 2s versus
   a 24s timeout is an unambiguous signal.
2. **Neither errors on timeout.** They exit 0. A waiter that silently gives up is
   indistinguishable from one that succeeded, so the apply proceeds and fails anyway.

And on Windows there is a third problem. Terraform's `local-exec` shells out through
`cmd /C`, and Go escapes embedded quotes as `\"`, which **cmd does not understand**. The
JMESPath arrives corrupted, the condition never matches, and — because of point 2 — the
command still exits 0. Verified: the same true condition returned in **2s** run directly
but took the **full 69s timeout** through `cmd`.

> **Always mutation-test a waiter.** Point it at a condition that can never be true. If it
> still exits 0, it is not a waiter. A `precondition` was chosen instead precisely because
> it cannot be silently wrong.

### A third bug, found while recovering: `[0]` breaks `refresh-only`

The documented recovery from a failed apply starts with
`terraform apply -refresh-only -auto-approve`. That command itself failed:

```
Error: Invalid index
  azurerm_virtual_network_gateway_connection.ergw is empty tuple
```

`outputs.tf` reached into count-gated resources with `var.x ? resource.y[0].name : null`.
In a refresh-only plan after a partial apply, the resource is declared with `count = 1`
but has **zero instances in state**, and `[0]` hard-fails — blocking the exact recovery
procedure it is needed for. Fixed by using `one(resource.y[*].name)`, which yields `null`
instead. That is already the idiom used elsewhere in this repo; `outputs.tf` was the
straggler.

## 11. Small things that still cost real time

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
| ACI probe warmup | The **first** probe from a freshly created container group returns `No route to host`, and one early sample came back at **1636 ms**. VNet route programming takes a few seconds. Discard warmup samples or you are benchmarking Azure provisioning, not the interconnect. |
| ACI images | Docker Hub fails with `RegistryErrorResponse`. Use `mcr.microsoft.com` — see lesson 4. |
| ACI subnet | Must be delegated to `Microsoft.ContainerInstance/containerGroups`, and Microsoft recommends **/24 or larger**. A `/27` works for one small group but is below the documented recommendation. |
| `draw.io --export` for the SVGs | Three separate traps, all silent. Five Azure icons live inside draw.io's own `app.asar`, so the CLI cannot inline them and writes `file:///C:/Users/<you>/...` refs instead — broken for every other reader, and a local path leaked into git. **`--embed-images` does not fix it.** There is no `--background` flag either; pass one and the colour is treated as a positional input file (`input file/directory not found: #ffffff`), while `-b/--border` is border *width*. And each export salts every gradient id with a fresh 20-char token, so an unchanged diagram still produces a whole-file diff. `scripts/render-diagrams.ps1` handles all three — use it instead of calling `draw.io` directly. |

## 12. What was right from the start

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
- **`interconnect_mode = "create"` needs `properties.partnerAccountId`** on the circuit —
  at the `properties` level, not inside `serviceProviderProperties`. Without it the PUT
  fails in ~1s, but Terraform will not tell you until the 25-minute gateway finishes.
- **`create` mode is a two-apply flow.** The provider pairing takes ~15 minutes; the first
  apply stops on a precondition, the second attaches the ExpressRoute connection.
- **Never trust `az ... wait --custom`.** It exits 0 on timeout, and
  `az network express-route wait` never matches at all. Mutation-test any waiter against a
  condition that cannot be true.
- **A resource stuck at `Creating...` with no `Still creating...` lines has already
  failed.** Check `az monitor activity-log list` rather than waiting out the apply.
- **AWS CLI uses `--output json`, not `-o json`.**
- **The ExpressRoute gateway takes ~25 min to create.** Timeouts are set to 90m.
- **`enable_flow_logs` defaults to `false`** — flow logs require storage shared-key
  access, which many subscriptions deny by policy. Log Analytics and Connection Monitor
  are on a separate switch (`enable_observability`) and are unaffected.
- **If a region cannot give you a VM, assume it cannot give you a Container Apps
  environment either** — ACA is AKS-backed. It fails after ~6 minutes with
  `AKSCapacityHeavyUsage`, not immediately.
- **Read the noun in the error.** `Current Limit … 0` is *quota* (App Service) and can be
  raised; `type: Location` and `HeavyUsage` are *capacity* and cannot.
- **ACI images must come from `mcr.microsoft.com`.** Docker Hub pulls fail with
  `RegistryErrorResponse`.
- **Discard the ACI probe's warmup samples** — the first one fails outright and an early
  one hit 1636 ms before settling.
- **ExpressRoute FastPath is not available here** — wrong gateway SKU *and* a provider
  circuit rather than ExpressRoute Direct. Don't re-propose it as a latency fix.

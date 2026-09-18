# Copilot instructions — `azure-aws-interconnect-lab`

Terraform + PowerShell lab that proves **private VM-to-VM connectivity between Azure and
AWS** over an already-provisioned **AWS Interconnect – multicloud** link. Read `README.md`
for the topology and runbook before changing anything.

## The one thing to internalise

This is **not** a Megaport/Equinix/partner-router ExpressRoute setup. The link is
[AWS Interconnect – multicloud](https://docs.aws.amazon.com/interconnect/latest/userguide/what-is-interconnect.html)
paired with [Azure Multicloud Interconnect (Preview)](https://learn.microsoft.com/azure/multicloud-interconnect/overview).

- **There is no BGP session, VLAN tag, MD5 key, 169.254.x.x peering, or private VIF to
  configure.** AWS and Microsoft own the underlay. Do not add resources that try to.
- **On AWS the interconnect's attach point is always a Direct Connect Gateway.** Read it
  from `attachPoint.directConnectGateway` in `aws interconnect list-connections`.
- **On Azure the attach point is a normal ExpressRoute VNet gateway + ExpressRoute
  connection** to the circuit resource ID.
- Preview limits: 1 Gbps only, **exactly one gateway connection per interconnect**, and a
  constrained region set. The bandwidth ceiling is enforced as a `precondition` on
  `terraform_data.guardrails`, not as a variable `validation` block — the only two
  `validation` blocks in `variables.tf` are on `interconnect_mode` and
  `flow_log_retention_days`.
- No Azure service or egress charge during preview.

`docs/lessons-learned.md` is the post-mortem for everything that went wrong building this,
ordered by time cost, and `docs/control-plane.md` shows what a healthy route dump looks
like on each side. Read them before debugging connectivity — most dead ends are already
written down there.

## The region split is forced — hub/spoke is not a preference

**This is already built; it is not a contingency.** The ExpressRoute gateway lives in a hub
VNet at `var.azure_hub_location` (`eastus`) and the VM lives in a spoke VNet at
`var.azure_location` (`eastus2`), peered with `allow_gateway_transit` +
`use_remote_gateways`. Two independent constraints collide:

- **A `MultiCloud` circuit is evaluated as a *Local* circuit**, so it attaches only to the
  single Azure region matching its `serviceProviderProperties.peeringLocation` (`useast` →
  East US). Nothing in the circuit's properties says "Local", and the gateway builds
  happily in the wrong region — you only find out ~25 min later when the *connection*
  fails with `cannot be connected to East US 2 on a Local circuit`. Do not infer the
  gateway region from the MCI supported-regions doc page; read it from the circuit.
- **The lab subscription cannot deploy VMs in `eastus` at all** — all ~1420 SKUs report a
  restriction of `type: Location` (not `type: Zone`). That is capacity, not quota, so a
  quota request will not clear it.

Gateways are not VMs, so the VM restriction does not apply to the gateway. Hence: gateway
in the hub, VM in the spoke. ExpressRoute advertises the spoke prefix to AWS automatically
via gateway transit. **Do not "simplify" this into a single VNet** without first checking
`az vm list-skus -l eastus --size Standard_B1s --all -o table`; a collapse is only valid on
a subscription that can build VMs in the gateway region.

## Two layers, two switches — do not conflate them

| Layer | Resources | Switch |
|---|---|---|
| **Transport** — the Azure MCI circuit and its paired AWS Interconnect connection | `azapi_resource.mci`, `awscc_interconnect_connection.lab`, `aws_dx_gateway.lab` | `var.interconnect_mode` (`existing` \| `create`) |
| **Attachment** — this lab hooking onto that transport | `azurerm_virtual_network_gateway_connection.ergw`, `aws_dx_gateway_association.lab` | `var.create_interconnect` (bool, demo mode) |

`interconnect_mode = "existing"` is the default and **must stay** the default: `create`
provisions an AWS Interconnect port that is billed per port-hour.

In `existing` mode the circuit and the interconnect live outside this repo. They are
referenced **by ID through variables only** — never as managed resources, never via
`import`, and `terraform destroy` must leave both intact.

Everything downstream reads `local.circuit_id` and `local.dxgw_id`, which resolve from
whichever mode is active. **Never reference `var.express_route_circuit_id` or
`var.dx_gateway_id` directly outside `data.tf`** — doing so silently breaks `create` mode,
where both are null.

### Provider split, and why it is not optional

- The Azure circuit is created with **`azapi`**, not `azurerm`. `azurerm`'s `sku.tier`
  validator rejects `MultiCloud` before any API call:
  `expected sku.0.tier to be one of ["Basic" "Local" "Premium" "Standard"]`.
- The AWS side is created with **`awscc`** (`AWS::Interconnect::Connection`); the classic
  `hashicorp/aws` provider has no resource for AWS Interconnect – multicloud.
- `var.azure_mci_api_version` must stay at **`2025-09-01` or later**. Earlier versions omit
  the circuit's `activationKey` from the response entirely — not empty, absent — so the AWS
  side receives a null key and the pairing fails with no useful error.
- The activation key is a **credential**. Keep it `sensitive`, never log or echo it.

## Layout

| Path | Role |
|---|---|
| `terraform/azure.tf` | hub VNet + `GatewaySubnet`, spoke VNet + VM subnet, both peerings, NSG, ER gateway, ER connection, VM |
| `terraform/aws.tf` | VPC, subnet, IGW, route table, VGW, DXGW association, SG, EC2 |
| `terraform/interconnect.tf` | `interconnect_mode = "create"` only: the circuit/interconnect pair |
| `terraform/observability.tf` | Log Analytics, Connection Monitor, optional VNet flow logs (see below) |
| `terraform/data.tf` | locals (`circuit_id`, `dxgw_id`), my-IP lookup, SSH keypair, AMI lookup, `terraform_data.guardrails` preconditions |
| `terraform/variables.tf` | every input; identifiers have **no defaults** so the lab cannot deploy into the wrong account |
| `terraform/outputs.tf` | includes `resource_names`, which the scripts consume instead of hardcoding names |
| `terraform/providers.tf` | subscription/tenant pinned so a stray `az account set` cannot retarget the deploy |
| `scripts/00-prereqs.ps1` | tooling + auth check. Requires `-AwsAccountId` and `-AzureSubscription` |
| `scripts/aws-login.ps1` | stores the `mcilab` AWS profile; never echoes the secret |
| `scripts/00-configure.ps1` / `.sh` | interactive setup: tooling, sign-in, mode choice, discovery, writes `terraform.tfvars` |
| `scripts/01-discover.ps1` | **authoritative** — dumps circuit + interconnect + DXGW state to `discovery.json`. Requires `-CircuitName`, `-InterconnectName`, `-AzureSubscription` |
| `scripts/02-verify.ps1` / `.sh` | post-deploy: learned routes, propagation, DXGW state, ping/MTU. `-SkipDataPlane` for control-plane only |
| `scripts/04-routes.ps1` / `.sh` | read-only routing dump on both ends, incl. advertised routes and BGP peer status |
| `scripts/99-destroy.ps1` / `.sh` | teardown + confirms the ER gateway is gone |
| `docs/lessons-learned.md` | post-mortem; check here first when something breaks |
| `docs/control-plane.md` | what a healthy route dump looks like on each side |

There is no `03-` script; the numbering gap is intentional.

Azure and AWS stay in separate files in one root module so either side can be `-target`ed
while debugging. Add new guardrails as `precondition` blocks on `terraform_data.guardrails`.

**Scripts must never hardcode resource names or identifiers.** Read
`terraform output -json resource_names` (and `azure_subscription_id` / `aws_profile` /
`cidrs`). A previous rename broke verification precisely because names were duplicated into
the scripts. `99-destroy.ps1` reads its outputs *before* destroying, since they vanish with
the state.

## Observability has its own two switches — same trap, different layer

`var.enable_observability` (default `true`) gates the Log Analytics workspace and the
Network Watcher Connection Monitor. `var.enable_flow_logs` (default **`false`**) gates the
VNet flow logs and their storage account, and is deliberately separate.

Flow logs write to blob storage with **shared-key** auth, which many subscriptions deny by
policy (`403 KeyBasedAuthenticationNotPermitted`). There is no Entra-only alternative.
**Do not merge these two switches** — they were merged once, and one blocked storage
account poisoned the whole observability stack. Worse, the failure is sticky: the account
lands in state in a condition Terraform cannot refresh, so every later `plan` fails with
the same 403. Recovery is
`terraform state rm 'azurerm_storage_account.flowlogs[0]'` plus `az storage account delete`
— not just flipping the variable back.

In this lab's tenant the control is a **Modify**-effect policy, not Deny: the create
succeeds with exit code 0 and `az deployment group validate` returns `"error": null`,
while `allowSharedKeyAccess` is silently rewritten to `false`. **Never conclude the policy
is absent from a clean create or a clean validate — read the property back.**
`azurerm_storage_account.flowlogs` carries `SecurityControl = Ignore`, which exempts it,
plus an explicit `shared_access_key_enabled = true` so drift shows up in `plan` if the
exemption ever stops working. That tag is a Microsoft-internal convention with zero
presence in Microsoft Learn — it is meaningless in tenants that don't look for it, and
useless against a Deny-effect version of the same control.

Connection Monitor is the signal that matters here: it probes the Azure VM → AWS VM
*private* IP continuously over ICMP and TCP/22 with traceroute, which catches asymmetric
routing that a plain ping hides. Flow logs attach to the **spoke VNet only** — the ER
gateway is a platform-managed VMSS whose NICs are not exposed, so a hub flow log captures
nothing.

## Validating a change

```powershell
cd terraform
terraform fmt -recursive          # every .tf here is gofmt-style aligned; keep it that way
terraform validate
terraform plan -out=tfplan        # the guardrail preconditions fire here, before any API call
```

`terraform validate` and `fmt` need no credentials; `plan` does, because
`terraform_data.guardrails` resolves `data.aws_caller_identity`. There is no test suite —
**`plan` is the unit test and `02-verify.ps1` is the integration test.**

To exercise one side without a 25-minute gateway build, `-target` it — but **quote the
whole argument**, because PowerShell otherwise mangles `-target=azurerm_x.y` into
`-target=azurerm_x`:

```powershell
terraform plan '-target=aws_instance.vm'
pwsh scripts/02-verify.ps1 -SkipDataPlane   # control plane only, no SSH
pwsh scripts/04-routes.ps1 -Json | ConvertFrom-Json
```

**After a failed apply, always apply a saved plan file.** `terraform apply -auto-approve`
re-plans from scratch and will happily try to recreate resources that already exist if
state drifted. Resync first with `terraform apply -refresh-only -auto-approve`, re-adopt
orphans with `terraform import`, then `plan -out=tfplan` and apply *that file*.

## Conventions

- **PowerShell is primary, but bash parity is maintained.** Scripts are `NN-verb.ps1`, run
  with `pwsh`, Windows paths with `\`. Four of them ship a `.sh` twin —
  `00-configure`, `02-verify`, `04-routes`, `99-destroy` — and README documents both call
  styles side by side. **If you change behaviour or flags in one of those four, change the
  twin in the same commit or the pair silently diverges.** `00-prereqs.ps1`, `01-discover.ps1`
  and `aws-login.ps1` are PowerShell-only by design. The bash twins need `jq`.
- **AWS CLI uses `--output json`. `-o json` is Azure-CLI-only** and fails with
  `Unknown options: -o, json`. This has bitten this repo before — check every new call site.
- **Every resource name derives from `var.prefix`** (`mcilab`). If you change it, update the
  hardcoded `rg-mcilab-azure` / `ergw-mcilab` / `rt-mcilab-vm` strings in
  `scripts/02-verify.ps1` and `scripts/99-destroy.ps1`.
- **Cost minimisation is a hard requirement**, not a nice-to-have. Before adding any
  resource, check it against the cost table in `README.md`. Specifically: VGW not Transit
  Gateway, ER gateway `Standard` not `ErGw1Az`, public IPs not Bastion/SSM endpoints,
  `Standard_LRS` disks, auto-shutdown on the Azure VM.
- **Secrets never land in git.** `*.tfvars`, `*.tfstate*`, `ssh/`, `discovery.json`,
  `apply.log` are gitignored. The lab SSH key is Terraform-generated and therefore in
  state — acceptable only because this is a throwaway lab on a local backend.

## Platform gotchas that cost real debugging time

- **When evaluating an Azure region for the VM, filter SKU restrictions on `type: Location`.**
  `type: Zone` is routine and harmless for a non-zonal VM. Only `Location` means the
  subscription genuinely cannot deploy there — and that is capacity, not quota, so a quota
  request will not clear it. See the region-split section above.
- **Public IPs carry an injected `ip_tags` value** (`FirstPartyUsage = "/Unprivileged"`) on
  this subscription. Terraform reads it as drift, and `ip_tags` forces replacement, so
  *every* plan wants to replace the public IP — and the destroy then fails with
  `PublicIPAddressCannotBeDeleted`. The `lifecycle { ignore_changes = [ip_tags] }` block is
  what stops the loop; don't remove it.
- **A failed ExpressRoute connection leaves an orphan that blocks gateway deletion**
  (`VirtualNetworkGatewayCannotBeDeleted`) even though it was never written to state.
  Delete it with `az network vpn-connection delete` — the command is `vpn-connection` even
  for an ExpressRoute connection.
- **ExpressRoute-type gateways get a platform-managed public IP.** Setting
  `ip_configuration.public_ip_address_id` is rejected by azurerm 4.x.
- **Use `propagating_vgws` on `aws_route_table`**, not the standalone
  `aws_vpn_gateway_route_propagation` resource — the latter races VGW attachment and fails
  with `couldn't find resource`.
- **AWS security group `name` cannot begin with `sg-`** (the `Name` tag can).
- **`aws interconnect list-connections` returns `id`**, not `name` or `connectionId`.
- **MTU 1400 on both VMs.** ExpressRoute caps TCP/UDP payload at 1400 bytes and does not
  fragment. Cloud-init installs a `lab-mtu.service` unit on each side. Probe it with
  `ping -M do -s 1372` (must pass) and `-s 1373` (must fail).
- **Never attach an NSG or a `0.0.0.0/0` UDR to `GatewaySubnet`.**
- **The ER gateway takes ~25 min to create and ~9 min to delete.** `timeouts` blocks are
  set to 90m; don't remove them.
- **Subnet IDs are region-independent**, so moving a VNet between regions produces *no*
  diff on `azurerm_subnet` — the VNet comes back with zero subnets and the gateway fails
  with `InvalidResourceReference`. Deleting the RG out-of-band and waiting for
  `az group exists` → `false` beats letting one apply delete and recreate it.

## Workflow

```powershell
pwsh scripts/00-prereqs.ps1 -AwsAccountId <id> -AzureSubscription <sub>   # tooling + auth
pwsh scripts/aws-login.ps1       # first run only: stores the mcilab AWS profile
pwsh scripts/01-discover.ps1 -CircuitName <name> -InterconnectName <name> -AzureSubscription <sub>
cd terraform; terraform init; terraform plan -out=tfplan; terraform apply tfplan
pwsh scripts/02-verify.ps1
pwsh scripts/04-routes.ps1       # read-only routing dump when a direction looks broken
pwsh scripts/99-destroy.ps1      # run when done - ~85% of cost is the ER gateway
```

`00-configure.ps1` wraps prereqs + discovery + `terraform.tfvars` generation in one
interactive pass; it takes `-NonInteractive` and `-InterconnectMode` for scripted runs.
The three scripts above have `Mandatory` parameters and will prompt if you omit them.

Discovery is the highest-risk step and its output drives the defaults in `variables.tf`.
If gateway wiring changes, re-run `01-discover.ps1` rather than assuming cached values.

<!-- BEGIN SQUAD WIRING — appended by Squad init 2026-09-18. Everything above this marker is hand-written; do not modify it. -->

---

## Squad — AI team wiring

This repository uses **Squad**, an AI team framework. Team state lives in `.squad/`.
Everything above this marker is the authoritative description of the lab itself and takes
precedence over anything here.

### Before starting work on an issue

1. Read `.squad/team.md` for the roster and remits.
2. Read `.squad/routing.md` for who owns what.
3. If the issue carries a `squad:{member}` label, read `.squad/agents/{member}/charter.md`
   and work within that member's domain and conventions.
4. Read `.squad/decisions.md` for standing team decisions.

### The team

| Member | Remit |
|---|---|
| 🏗️ **Ripley** — Lead | `terraform/` root module, variable/output contracts, `terraform_data.guardrails`, state recovery, scope calls. Terraform review gate. |
| 🌐 **Dallas** — Multicloud Network Engineer | The end-to-end path and every networking resource on both clouds; routing, propagation, and MTU diagnosis. |
| ⚙️ **Parker** — Automation Engineer | Everything under `scripts/`, including strict parity between the four PowerShell/bash twins. |
| 📝 **Lambert** — Docs & Post-Mortem Curator | `README.md`, `docs/**`, the time-cost-ordered post-mortem, the topology diagrams. |
| 🔒 **Bishop** — Cost & Secrets Guardian | Cost review against the README cost table, secrets/gitignore/exposure review. Verdicts only — never implements. |
| 📋 Scribe | Session logs, decision merges. Silent. |
| 🔄 Ralph | Work queue and backlog monitor. |

### Repo-specific rules Squad members must honour

These are restatements of rules established above, repeated here because they are the ones
agents most often break:

- **Never run live-infrastructure commands autonomously.** `terraform apply`,
  `terraform destroy`, and `az`/`aws` write operations are operator-run. `terraform fmt`,
  `validate`, and `plan` are the agent-safe gates.
- **`terraform plan` is the unit test; `scripts/02-verify.ps1` is the integration test.**
  There is no test suite to run.
- **A change to any of `00-configure`, `02-verify`, `04-routes`, `99-destroy` must change
  both the `.ps1` and the `.sh` twin in the same commit.**
- **Never hardcode resource names in scripts** — read `terraform output -json resource_names`.
- **Cost minimisation is a hard requirement.** New resources go past Bishop and the README
  cost table.
- **Secrets never land in git:** `*.tfvars`, `*.tfstate*`, `ssh/`, `discovery.json`,
  `apply.log`. The circuit activation key is a credential.

### Branch and PR conventions

- Branch: `squad/{issue-number}-{kebab-case-slug}`
- PR body references the issue (`Closes #{n}`) and names the member whose domain it sits in.
- Decisions that affect others go to `.squad/decisions/inbox/{member}-{brief-slug}.md`;
  the Scribe merges them into `.squad/decisions.md`.

<!-- END SQUAD WIRING -->


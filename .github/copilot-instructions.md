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
- Preview limits: 1 Gbps only, **exactly one gateway connection per interconnect**, and
  the region set is constrained (`var.azure_location` carries a `validation` block —
  keep it in sync). This lab uses `eastus2`; see the gotchas below for why.
- No Azure service or egress charge during preview.

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
| `terraform/azure.tf` | VNet, subnets, NSG, ER gateway, ER connection, VM |
| `terraform/aws.tf` | VPC, subnet, IGW, route table, VGW, DXGW association, SG, EC2 |
| `terraform/interconnect.tf` | `interconnect_mode = "create"` only: the circuit/interconnect pair |
| `terraform/data.tf` | locals (`circuit_id`, `dxgw_id`), my-IP lookup, SSH keypair, AMI lookup, `terraform_data.guardrails` preconditions |
| `terraform/variables.tf` | every input; identifiers have **no defaults** so the lab cannot deploy into the wrong account |
| `terraform/outputs.tf` | includes `resource_names`, which the scripts consume instead of hardcoding names |
| `scripts/00-configure.ps1` / `.sh` | interactive setup: tooling, sign-in, mode choice, discovery, writes `terraform.tfvars` |
| `scripts/01-discover.ps1` | **authoritative** — dumps circuit + interconnect + DXGW state to `discovery.json` |
| `scripts/02-verify.ps1` | post-deploy: learned routes, propagation, DXGW state, ping/MTU |
| `scripts/99-destroy.ps1` | teardown + confirms the ER gateway is gone |

Azure and AWS stay in separate files in one root module so either side can be `-target`ed
while debugging. Add new guardrails as `precondition` blocks on `terraform_data.guardrails`.

**Scripts must never hardcode resource names or identifiers.** Read
`terraform output -json resource_names` (and `azure_subscription_id` / `aws_profile` /
`cidrs`). A previous rename broke verification precisely because names were duplicated into
the scripts. `99-destroy.ps1` reads its outputs *before* destroying, since they vanish with
the state.

## Conventions

- **PowerShell, not bash.** Windows paths with `\`. Scripts are `NN-verb.ps1`, run with `pwsh`.
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

- **The lab subscription could not deploy VMs in `eastus`** — every SKU reports
  `NotAvailableForSubscription` at `type: Location` (not merely `type: Zone`). The
  ExpressRoute gateway also does not work from `westus` against this useast-peered
  circuit. The Azure side therefore uses **`eastus2`**, which is in the same East US
  metro and only zone-restricts `Standard_B1s`. When evaluating a region, filter
  restrictions on `Location`; zonal restrictions are normal and harmless for a
  non-zonal VM. Note `eastus2` is outside the documented MCI region list — if the
  ExpressRoute connection is rejected, move the gateway to an `eastus` hub VNet and
  peer the `eastus2` VM VNet to it with gateway transit.
- **ExpressRoute-type gateways get a platform-managed public IP.** Setting
  `ip_configuration.public_ip_address_id` is rejected by azurerm 4.x.
- **Use `propagating_vgws` on `aws_route_table`**, not the standalone
  `aws_vpn_gateway_route_propagation` resource — the latter races VGW attachment and fails
  with `couldn't find resource`.
- **AWS security group `name` cannot begin with `sg-`** (the `Name` tag can).
- **`aws interconnect list-connections` returns `id`**, not `name` or `connectionId`.
- **MTU 1400 on both VMs.** ExpressRoute caps TCP/UDP payload at 1400 bytes and does not
  fragment. Cloud-init installs a `lab-mtu.service` unit on each side.
- **Never attach an NSG or a `0.0.0.0/0` UDR to `GatewaySubnet`.**
- **The ER gateway takes 20-30 min to create and 10-20 min to delete.** Explicit
  `timeouts` blocks are set; don't remove them.

## Workflow

```powershell
pwsh scripts/00-prereqs.ps1      # tooling + auth
pwsh scripts/aws-login.ps1       # stores the mcilab AWS profile
pwsh scripts/01-discover.ps1     # ALWAYS re-run before changing gateway wiring
cd terraform; terraform init; terraform plan -out=tfplan; terraform apply tfplan
pwsh scripts/02-verify.ps1
pwsh scripts/99-destroy.ps1      # run when done - ~85% of cost is the ER gateway
```

Discovery is the highest-risk step and its output drives the defaults in `variables.tf`.
If gateway wiring changes, re-run `01-discover.ps1` rather than assuming cached values.


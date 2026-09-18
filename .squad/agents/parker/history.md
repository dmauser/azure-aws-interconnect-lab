# Project Context

- **Owner:** Scribe
- **Project:** az-mcloud-ix — Terraform + PowerShell lab proving private VM-to-VM connectivity between Azure and AWS over an AWS Interconnect – multicloud link paired with an Azure Multicloud Interconnect (Preview) circuit.
- **Stack:** Terraform (providers: `azapi`, `azurerm`, `awscc`, `hashicorp/aws`), PowerShell 7 (primary) with bash parity for four scripts, Ubuntu/Amazon Linux VMs via cloud-init.
- **Created:** 2026-09-18T14:50:58Z

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-09-18T14:50:58Z — Day-1 seed (Automation Engineer)

- Script inventory: `00-prereqs.ps1` (PS-only), `00-configure.ps1`/`.sh`, `01-discover.ps1` (PS-only, authoritative, writes `discovery.json`), `02-verify.ps1`/`.sh`, `04-routes.ps1`/`.sh`, `99-destroy.ps1`/`.sh`, `aws-login.ps1` (PS-only).
- **Four twins must stay in lockstep:** `00-configure`, `02-verify`, `04-routes`, `99-destroy`. Behaviour or flag changes land in both in the same commit. The bash twins need `jq`.
- **Never hardcode resource names.** Read `terraform output -json resource_names`, plus `azure_subscription_id`, `aws_profile`, `cidrs`. A rename previously broke verification because names had been duplicated into the scripts.
- `99-destroy` must read outputs **before** destroying — they vanish with the state.
- **`-o json` is Azure-CLI-only.** AWS CLI needs `--output json` or it fails with `Unknown options: -o, json`. Check every new AWS call site.
- `aws interconnect list-connections` returns `id` — not `name`, not `connectionId`.
- Windows/PowerShell: use backslash paths; quote the whole `-target` argument (`terraform plan '-target=aws_instance.vm'`) or PowerShell truncates it at the dot; use `;` not `&&` before PowerShell keywords.
- `02-verify` has `-SkipDataPlane` for control-plane-only runs (no SSH). `04-routes` has `-Json`.
- `00-configure` wraps prereqs + discovery + `terraform.tfvars` generation; it takes `-NonInteractive` and `-InterconnectMode` for scripted runs.
- The gap at `03-` in the numbering is intentional.
- `aws-login.ps1` stores the `mcilab` AWS profile and must never echo the secret.

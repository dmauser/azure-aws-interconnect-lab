# Project Context

- **Owner:** Scribe
- **Project:** az-mcloud-ix — Terraform + PowerShell lab proving private VM-to-VM connectivity between Azure and AWS over an AWS Interconnect – multicloud link paired with an Azure Multicloud Interconnect (Preview) circuit.
- **Stack:** Terraform (providers: `azapi`, `azurerm`, `awscc`, `hashicorp/aws`), PowerShell 7 (primary) with bash parity for four scripts, Ubuntu/Amazon Linux VMs via cloud-init.
- **Created:** 2026-09-18T14:50:58Z

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-09-18T14:50:58Z — Day-1 seed (Cost & Secrets Guardian)

- **Cost minimisation is a hard requirement**, not a preference. Every proposed resource gets checked against the cost table in `README.md` before approval.
- Standing least-cost decisions: VGW instead of Transit Gateway; `Standard` ExpressRoute gateway instead of `ErGw1Az`; public IPs instead of Bastion/SSM endpoints; `Standard_LRS` disks; auto-shutdown on the Azure VM.
- The ER gateway is the overwhelming majority of lab cost and takes roughly 25 minutes to build / 9 minutes to delete. An idle lab left standing is a defect — `99-destroy` exists for a reason.
- **Secrets:** the circuit activation key is a credential — `sensitive`, never logged or echoed. `var.azure_mci_api_version` must stay at a version that actually returns the key, or the AWS side receives null and pairing fails with no useful error.
- Gitignored and must stay that way: `*.tfvars`, `*.tfstate*`, `ssh/`, `discovery.json`, `apply.log`.
- The lab SSH key is Terraform-generated and therefore in state — acceptable only because this is a throwaway lab on a local backend. Say so whenever the backend question comes up.
- **Two observability switches, deliberately separate:** `enable_observability` (Log Analytics + Connection Monitor, default on) and `enable_flow_logs` (flow logs + storage account, default off). Merging them once poisoned the whole observability stack with one blocked storage account, and the failure is sticky — recovery requires removing it from state and deleting it out of band.
- **A clean exit code proves nothing about policy.** In this tenant the relevant control is Modify-effect: create succeeds, validate reports no error, and the setting is silently rewritten. Always read the property back.
- The `SecurityControl = Ignore` tag is an internal convention with no public documentation — meaningless in tenants that don't look for it and useless against a Deny-effect control. Do not treat it as a general solution.
- Exposure review: operator SSH scoped to a single address on both clouds; cross-cloud access scoped to the peer CIDR. AWS security group `name` cannot begin with `sg-` (the `Name` tag can).

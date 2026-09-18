# Project Context

- **Owner:** Scribe
- **Project:** az-mcloud-ix — Terraform + PowerShell lab proving private VM-to-VM connectivity between Azure and AWS over an AWS Interconnect – multicloud link paired with an Azure Multicloud Interconnect (Preview) circuit.
- **Stack:** Terraform (providers: `azapi`, `azurerm`, `awscc`, `hashicorp/aws`), PowerShell 7 (primary) with bash parity for four scripts, Ubuntu/Amazon Linux VMs via cloud-init.
- **Created:** 2026-09-18T14:50:58Z

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-09-18T14:50:58Z — Day-1 seed (Lead / Terraform root-module owner)

- I own `terraform/` as a single root module with Azure and AWS in separate files so either side can be `-target`ed while debugging.
- **`terraform plan` is the unit test; `scripts/02-verify.ps1` is the integration test.** There is no test suite. `terraform fmt -recursive` and `terraform validate` are the credential-free gates.
- Two independent switches that must never be conflated: `var.interconnect_mode` (transport: `existing` | `create`) and `var.create_interconnect` (attachment/demo mode). `existing` is and stays the default — `create` provisions a billed AWS Interconnect port.
- Downstream resources read `local.circuit_id` / `local.dxgw_id`. Referencing `var.express_route_circuit_id` or `var.dx_gateway_id` outside `data.tf` silently breaks `create` mode where both are null.
- New invariants go on `terraform_data.guardrails` as `precondition` blocks. The only two variable `validation` blocks are on `interconnect_mode` and `flow_log_retention_days`.
- The hub (ER gateway, one region) / spoke (VM, another region) split is forced by two independent constraints and is already built — not a contingency. Do not collapse it without proving the subscription can build VMs in the gateway region.
- `azapi` is required for the circuit because `azurerm`'s SKU tier validator rejects the MultiCloud tier before any API call. `awscc` is required on the AWS side because the classic AWS provider has no resource for this connection type.
- After a failed apply: `apply -refresh-only`, re-adopt orphans with `import`, then `plan -out=tfplan` and apply *that file*. Never `apply -auto-approve` after drift.
- Do not remove the `timeouts` blocks or `lifecycle { ignore_changes = [ip_tags] }` — both encode reproduced failures.
- `docs/lessons-learned.md` is the post-mortem ordered by time cost. Read it before debugging.

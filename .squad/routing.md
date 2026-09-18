# Work Routing

How to decide who handles what in `az-mcloud-ix`.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Terraform root module, variables, outputs, guardrails | 🏗️ Ripley | Add a `precondition`, change a variable contract, restructure `data.tf`, adjust provider pinning |
| State recovery after a failed apply | 🏗️ Ripley | Refresh-only resync, `terraform import` of an orphan, saved-plan apply |
| Scope, trade-offs, "should we build this at all" | 🏗️ Ripley | Region/topology decisions, mode defaults, architectural proposals |
| Azure + AWS networking resources | 🌐 Dallas | VNet/peering/`GatewaySubnet`/ER gateway + connection, VPC/subnet/route table/VGW/DXGW association, NSG + security group |
| Connectivity diagnosis | 🌐 Dallas | Route dump analysis, missing propagation, asymmetric routing, MTU black-holing, one-way reachability |
| PowerShell and bash scripts | ⚙️ Parker | Any change under `scripts/`, new flags, output parsing, prereq checks |
| Twin parity | ⚙️ Parker | Any edit to `00-configure`, `02-verify`, `04-routes`, `99-destroy` — both twins, same commit |
| README, `docs/**`, diagrams | 📝 Lambert | Runbook updates, post-mortem entries, control-plane reference, drawio/SVG/Mermaid |
| Cost review | 🔒 Bishop | Any new resource, SKU or tier change, "can we leave this running" |
| Secrets, gitignore, exposure review | 🔒 Bishop | Activation-key handling, state/tfvars hygiene, NSG and security-group scope |
| Review gate — Terraform | 🏗️ Ripley | Review before apply; rejection triggers the lockout protocol |
| Review gate — cost / security | 🔒 Bishop | Independent gate; verdicts only, never implements the fix |
| Verification runs | ⚙️ Parker + 🌐 Dallas | Parker owns the script, Dallas interprets the result |
| Session logging | 📋 Scribe | Automatic — never needs routing |
| Backlog / work queue | 🔄 Ralph | Issue triage sweep, PR follow-ups |

## Pairing Patterns

These pairs come up constantly — spawn them together rather than serially:

- **Terraform networking change** → Ripley (module correctness) + Dallas (path correctness), plus Bishop if a resource is added.
- **Script change** → Parker (implementation) + Lambert (README call-style docs) in parallel.
- **New failure discovered** → Dallas (diagnosis) + Lambert (post-mortem entry written from the diagnosis).
- **Anything that adds a resource** → Bishop reviews cost and exposure in parallel with implementation, not after.

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Ripley (Lead) |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, **Ripley** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work (docs and cost review can start from requirements).
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent to report what a variable defaults to.
4. **When two agents could handle it**, pick the one whose domain is the primary concern. Terraform *structure* is Ripley; Terraform *routing semantics* is Dallas.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Never route a `.ps1` edit without also routing its `.sh` twin** when the script is one of the four twinned pairs.
7. **Never route live-infrastructure commands to an agent.** `terraform apply`, `terraform destroy`, and `az`/`aws` write operations are operator-run unless the user explicitly asks and confirms.
8. **Reviewer rejection lockout applies.** If Ripley or Bishop rejects work, the original author does not revise it — a different agent does.

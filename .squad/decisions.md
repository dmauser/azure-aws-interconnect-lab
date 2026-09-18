# Squad Decisions

## Active Decisions

### 2026-09-18T14:50:58Z: Team cast and roster established
**By:** Squad (Coordinator), Init Mode
**What:** Hired five specialists — Ripley (Lead / Terraform root-module owner), Dallas (Multicloud Network Engineer), Parker (Automation Engineer, PowerShell + bash parity), Lambert (Docs & Post-Mortem Curator), Bishop (Cost & Secrets Guardian / reviewer) — alongside the built-in Scribe and Ralph.
**Why:** The repo is a focused single-purpose lab with five recurring work domains: Terraform root-module structure, cross-cloud networking, script parity, docs/post-mortem curation, and cost + secrets review. Deliberately sized small rather than a broad generic roster.

### 2026-09-18T14:50:58Z: Agents do not run live-infrastructure commands
**By:** Squad (Coordinator), Init Mode
**What:** `terraform apply`, `terraform destroy`, and `az`/`aws` write operations are operator-run, not agent-run, unless the user explicitly asks and confirms. Agents may run `terraform fmt -recursive`, `terraform validate`, and `terraform plan`.
**Why:** The ER gateway takes roughly 25 minutes to build and dominates lab cost; a stray apply or destroy is expensive and slow to undo. `plan` is the unit test and is safe.

### 2026-09-18T14:50:58Z: Twin parity is a routing rule, not a convention
**By:** Squad (Coordinator), Init Mode
**What:** Any behaviour or flag change to `00-configure`, `02-verify`, `04-routes`, or `99-destroy` must land in both the `.ps1` and `.sh` twin in the same commit. Routing never sends one without the other.
**Why:** Silent divergence between twins is a documented recurring failure mode in this repo.

### 2026-09-18T14:50:58Z: Two independent review gates
**By:** Squad (Coordinator), Init Mode
**What:** Ripley gates Terraform correctness; Bishop independently gates cost and secrets/exposure. Bishop produces verdicts only and never implements the fix. Reviewer rejection lockout applies — a rejected author does not revise their own work.
**Why:** Cost minimisation and secrets discipline are hard requirements here, and folding them into the Terraform review would let them be traded away in the same conversation that creates the resource.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
- Agents write proposed decisions to `.squad/decisions/inbox/{name}-{slug}.md`; the Scribe merges them here

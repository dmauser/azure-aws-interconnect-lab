---
updated_at: 2026-09-18T14:50:58Z
focus_area: Team cast — roster established, no lab work in flight
active_issues: []
---

# What We're Focused On

The team was just hired (Alien cast: Ripley, Dallas, Parker, Lambert, Bishop, plus Scribe
and Ralph). No lab work is in flight.

The lab itself is a Terraform + PowerShell proof of private VM-to-VM connectivity between
Azure and AWS over a provider-managed multicloud interconnect. Standing constraints the
team works under:

- `terraform plan` is the unit test; `scripts/02-verify.ps1` is the integration test.
- Agents do not run `apply`, `destroy`, or cloud write operations.
- Four scripts have bash twins that must never diverge.
- Cost minimisation and secrets discipline are hard requirements, gated by Bishop.

Updated by coordinator at session start.

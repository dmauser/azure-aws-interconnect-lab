# Project Context

- **Owner:** Scribe
- **Project:** az-mcloud-ix — Terraform + PowerShell lab proving private VM-to-VM connectivity between Azure and AWS over an AWS Interconnect – multicloud link paired with an Azure Multicloud Interconnect (Preview) circuit.
- **Stack:** Terraform (providers: `azapi`, `azurerm`, `awscc`, `hashicorp/aws`), PowerShell 7 (primary) with bash parity for four scripts, Ubuntu/Amazon Linux VMs via cloud-init.
- **Created:** 2026-09-18T14:50:58Z

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-09-18T14:50:58Z — Day-1 seed (Docs & Post-Mortem Curator)

- Doc surface I own: `README.md`, `docs/lessons-learned.md`, `docs/control-plane.md`, `docs/sample-routes.txt`, the drawio source and its light/dark SVG exports, and the Mermaid twin embedded in the README.
- `README.md` is structured as a jump table → Architecture → Prerequisites checklist → Cost → Deploy → Verify → Configuration, and it documents **both** PowerShell and bash call styles side by side for the four twinned scripts.
- `docs/lessons-learned.md` is **ordered by time cost**, not chronologically. A new entry is inserted at the rank its cost earns.
- The most valuable field in a post-mortem entry is the **misleading signal** — the thing that looked like the cause and wasn't. That is what burns the hours.
- `docs/control-plane.md` is the "what healthy looks like" reference that Dallas diffs suspect route dumps against. Keep it current when the topology changes.
- The README carries a cost badge and a cost table; cost claims must track the real resource set. Drift gets flagged to Bishop rather than silently edited.
- Diagram change order: `.drawio` source → export both SVGs (light + dark) → update the Mermaid block so all three agree.
- Cross-link, don't duplicate: the README points at the docs rather than restating them.

### 2026-02-19 — Latency probe documentation (README, diagrams, post-mortem)

**Toolchain that works for regenerating the SVGs** (no `drawio` on PATH):

```powershell
$exe='C:\Users\dmauser\AppData\Local\Programs\draw.io\draw.io.exe'   # 31.4.5
& $exe -x -f svg --theme light --embed-svg-images -b 12 -o out.svg src.drawio
Start-Sleep -Seconds 8      # export is ASYNC - the CLI returns before the file lands
```

- There is **no `--background` flag**; passing one makes drawio treat the colour as an
  input filename. `--svg-theme` is deprecated in favour of `--theme`.
- **Both** themes now export `background: transparent` - the light one too. Both need a
  post-export string replace to `#ffffff` / `#0d1117`.
- `-b 12` reproduces the committed border geometry. `--embed-svg-images` is required.
- Verify with: `data-cell-id` count (27), `xlink:href="file:` count (must be **0**), and
  the width/height pair (1654x688).
- **Always do a PNG visual check** - `-f png -b 12 -s 1`, then `view` it. Structural
  checks passed twice while the render was visibly broken.

**draw.io layout traps found the hard way:**
- Icon labels are bottom-anchored and centred, so a long label spreads left and right of
  the icon centre and collides with any orthogonal edge lane routed below it.
- Edge labels default to the midpoint of the whole edge; on a long vertical lane near the
  canvas edge the label overhangs off-canvas. Shortening the label beats fiddling with
  `<mxPoint as="offset">`.
- Two edges entering the same node side need different fractional `entryY` (0.3 / 0.7),
  and the *outer* lane should take the *higher* entry point or the two cross.
- Dark theme does **not** invert explicit `fillColor` values - only defaults and text, so
  the palette is identical across both exports.
- Entity refs inside `mxCell value`: `&#10;` newline, `&#183;` middot, `&#8212;` em-dash,
  `&#9654;`/`&#9664;` for arrows.

**Mermaid can be validated locally** - `npx -y @mermaid-js/mermaid-cli -i x.mmd -o x.png
-w 1800`. Worth doing; it caught nothing this time but it is cheap and the block is inside
a `<details>` where breakage is invisible on GitHub until someone expands it.

**Anchor checking is now mandatory after any lessons-learned heading edit.** README
deep-links to lesson numbers. A short PowerShell function that GitHub-slugs every heading
and resolves every `](#...)` / `](docs/lessons-learned.md#...)` link caught the numbering
drift immediately - I had briefly given the Docker Hub finding its own number, which
silently shifted FastPath from 9 to 10 and broke a README link. Folded it into lesson 4.

**Repo conventions confirmed:** measurement plane = teal `#0E7490` dashed (new, mine);
transport stays Azure `#0078D4` / fabric `#52525B` / AWS `#ED7100`. Never state a cloud
price as fact - the ACI cost row lists billing dimensions only.

**Session tooling note:** the `cn_*` network-desk tools were **not registered** this
session (`tool_search_tool` returned nothing twice). Used the Microsoft Learn MCP server
instead, which confirmed the FastPath SKU/Direct requirements, ACI subnet delegation, the
/24 recommendation, the documented Docker Hub `RegistryErrorResponse`, and per-second
vCPU/memory billing. Azure claims are therefore sourced, not assumed.

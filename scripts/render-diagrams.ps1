#Requires -Version 7.0
<#
.SYNOPSIS
    Regenerates docs/az-aws-interconnect.svg and -dark.svg from the drawio source.

.DESCRIPTION
    Not a lab-lifecycle script, so it deliberately sits outside the NN-verb.ps1 numbering
    and has no bash twin - it needs the draw.io desktop app, which is Windows/GUI tooling.

    Two things about this export are non-obvious, and both silently corrupt the SVGs if
    you just run `draw.io --export` by hand:

    1. Five Azure icons live inside draw.io's own app.asar archive. The CLI cannot inline
       them, so it writes `file:///C:/Users/<you>/AppData/...` references instead. Those
       render as broken images for everyone else and leak a local path into git.
       `--embed-images` does NOT fix this. This script transplants the matching data-URIs
       out of the committed SVGs, matching each <image> by its x/y/width/height.
    2. There is no `--background` flag. Passing one makes draw.io treat the colour as a
       positional input file ("input file/directory not found: #ffffff"). The background
       has to be written into the root <svg style> afterwards.

    Because the icon donor is the committed SVG, at least one good copy must exist in git.
    If an icon cannot be resolved the script fails rather than writing a broken diagram.

.EXAMPLE
    pwsh scripts/render-diagrams.ps1
.EXAMPLE
    pwsh scripts/render-diagrams.ps1 -DonorRef HEAD~1
#>
[CmdletBinding()]
param(
    # Git ref to pull the embedded icon data-URIs from.
    [string]$DonorRef = 'HEAD',
    # Path to the draw.io desktop executable.
    [string]$DrawioPath = "$env:LOCALAPPDATA\Programs\draw.io\draw.io.exe"
)

$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel).Trim()
$source   = Join-Path $repoRoot 'docs\az-aws-interconnect.drawio'

$targets = @(
    [pscustomobject]@{ Theme = 'light'; File = 'docs/az-aws-interconnect.svg';      Background = '#ffffff' }
    [pscustomobject]@{ Theme = 'dark';  File = 'docs/az-aws-interconnect-dark.svg'; Background = '#0d1117' }
)

if (-not (Test-Path $DrawioPath)) { throw "draw.io not found at '$DrawioPath'. Install it or pass -DrawioPath." }
if (-not (Test-Path $source))     { throw "Diagram source not found at '$source'." }

# Parse every <image> element into a geometry-keyed map of href values.
function Get-ImageMap {
    param([string]$Svg)
    $map = @{}
    foreach ($m in [regex]::Matches($Svg, '<image\b[^>]*?>')) {
        $tag  = $m.Value
        $href = [regex]::Match($tag, 'xlink:href="([^"]*)"')
        if (-not $href.Success) { continue }
        $key = @('x', 'y', 'width', 'height') | ForEach-Object {
            $a = [regex]::Match($tag, "\b$_=`"([^`"]*)`"")
            if ($a.Success) { $a.Groups[1].Value } else { '' }
        }
        $map[($key -join '|')] = $href.Groups[1].Value
    }
    return $map
}

foreach ($t in $targets) {
    $outPath = Join-Path $repoRoot ($t.File -replace '/', '\')
    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) "mcilab-$($t.Theme)-$PID.svg"

    Write-Host "==> exporting $($t.Theme) theme" -ForegroundColor Cyan
    & $DrawioPath --export --format svg --svg-theme $t.Theme --border 12 --scale 1 `
        --output $tmp $source | Out-Null
    if (-not (Test-Path $tmp)) { throw "draw.io produced no output for the $($t.Theme) theme." }

    $svg = [System.IO.File]::ReadAllText($tmp)

    # Donor icons come from the committed copy of this same file.
    $donor = Get-ImageMap (git show "${DonorRef}:$($t.File)" | Out-String)

    $transplanted = [System.Collections.Generic.List[string]]::new()
    $unresolved   = [System.Collections.Generic.List[string]]::new()

    $svg = [regex]::Replace($svg, '<image\b[^>]*?>', {
        param($m)
        $tag  = $m.Value
        $href = [regex]::Match($tag, 'xlink:href="([^"]*)"')
        if (-not $href.Success -or $href.Groups[1].Value.StartsWith('data:')) { return $tag }

        $key = @('x', 'y', 'width', 'height') | ForEach-Object {
            $a = [regex]::Match($tag, "\b$_=`"([^`"]*)`"")
            if ($a.Success) { $a.Groups[1].Value } else { '' }
        }
        $name = $href.Groups[1].Value.Split('/')[-1]
        $sub  = $donor[($key -join '|')]

        if (-not $sub -or -not $sub.StartsWith('data:')) {
            $unresolved.Add("$name at $($key -join ',')") | Out-Null
            return $tag
        }
        $transplanted.Add($name) | Out-Null
        return $tag.Replace("xlink:href=`"$($href.Groups[1].Value)`"", "xlink:href=`"$sub`"")
    })

    if ($unresolved.Count -gt 0) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        throw ("Could not resolve $($unresolved.Count) icon(s) from ${DonorRef}:$($t.File):`n  " +
               ($unresolved -join "`n  ") +
               "`nThe diagram moved an icon, so the donor no longer matches by geometry. " +
               "Export once from the draw.io GUI (which embeds them) and commit that as the new donor.")
    }

    # There is no --background flag; write it into the root <svg style> instead.
    $bg  = $t.Background
    $svg = [regex]::Replace($svg, '(<svg[^>]*?style=")([^"]*)(")', {
        param($m)
        $style = [regex]::Replace($m.Groups[2].Value, 'background(-color)?:\s*[^;]+;', '').Trim()
        "$($m.Groups[1].Value)$style background: $bg; background-color: $bg;$($m.Groups[3].Value)"
    }, 1)

    # draw.io salts every gradient/clip-path id with a fresh 20-character token per export,
    # so two byte-identical diagrams still produce a whole-file diff. Pin it to a stable
    # value - the ids are document-local, so the name itself carries no meaning.
    $salt = [regex]::Match($svg, 'id="drawio-svg-(.{20})-')
    if ($salt.Success) {
        $svg = $svg.Replace("drawio-svg-$($salt.Groups[1].Value)", 'drawio-svg-mcilab')
    }

    [System.IO.File]::WriteAllText($outPath, $svg)
    Remove-Item $tmp -ErrorAction SilentlyContinue

    $leaked = [regex]::Matches($svg, 'xlink:href="file:///[^"]*"').Count
    if ($leaked -gt 0) { throw "$($t.File) still contains $leaked local file:/// reference(s)." }

    $style = [regex]::Match($svg, '<svg[^>]*style="([^"]*)"').Groups[1].Value
    Write-Host ("    {0}  icons transplanted: {1}  style: {2}" -f $t.File, $transplanted.Count, $style) -ForegroundColor Green
}

Write-Host "`nDone. Both SVGs regenerated." -ForegroundColor Green
Write-Host "Review them before committing - docs/latency-dashboard.png is a separate artifact" -ForegroundColor DarkGray
Write-Host "and must be recaptured by hand if the dashboard UI changed." -ForegroundColor DarkGray

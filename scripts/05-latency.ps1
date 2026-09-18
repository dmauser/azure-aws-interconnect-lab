<#
.SYNOPSIS
    Reads the latency collector and compares the two vantage points.

.DESCRIPTION
    The lab's headline latency number was always measured from the VM, which
    lives in the spoke region because this subscription cannot build a VM in the
    gateway's region. That measurement includes an inter-region hop that has
    nothing to do with the interconnect.

    This script reads both vantage points from the collector and prints the
    difference, which is the part of the spoke figure that the forced region
    split is responsible for:

      1. Container group state for the hub prober
      2. Collector health
      3. Per-vantage percentiles for TCP and ICMP
      4. The region-split delta at p50

    Read-only. It changes nothing on either cloud.

.PARAMETER Window
    Look-back window. Accepts 15m, 1h, 6h, 24h, 7d or a bare number of seconds.
    Defaults to 1h.

.PARAMETER Json
    Emit the raw collector summary instead of formatted tables.

.EXAMPLE
    pwsh scripts/05-latency.ps1

.EXAMPLE
    pwsh scripts/05-latency.ps1 -Window 24h

.EXAMPLE
    pwsh scripts/05-latency.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string]$Window = '1h',
    [string]$AzureSubscription,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$tfDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'
$tf    = terraform -chdir="$tfDir" output -json | ConvertFrom-Json

if (-not $tf.resource_names) {
    throw "Terraform output 'resource_names' is missing. Run 'terraform apply' with the current configuration first."
}

$names = $tf.resource_names.value

if (-not $names.probe_enabled) {
    Write-Host ''
    Write-Host 'The latency probe is not deployed (enable_latency_probe = false).' -ForegroundColor Yellow
    Write-Host 'Set it to true and re-apply to collect measurements.'
    return
}

if (-not $AzureSubscription) { $AzureSubscription = $tf.azure_subscription_id.value }

$baseUrl = ($tf.probe_dashboard_url.value).TrimEnd('/')

if ($Json) { $InformationPreference = 'SilentlyContinue' }

function Write-Section {
    param([string]$Text)
    if ($Json) { return }
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Text, [string]$Color = 'DarkGray')
    if ($Json) { return }
    Write-Host "  $Text" -ForegroundColor $Color
}

function Format-Ms {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return ('{0:N2}' -f $Value)
}

##############################################################################
if (-not $Json) {
    Write-Host ''
    Write-Host "Latency probe  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
    Write-Host "  collector : $baseUrl"
    Write-Host "  window    : $Window"
}

##############################################################################
Write-Section '1/4  Hub prober (container group)'
##############################################################################
try {
    $cg = az container show --name $names.probe_container_group `
        --resource-group $names.resource_group `
        --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json

    $state   = $cg.containers[0].instanceView.currentState.state
    $restarts = $cg.containers[0].instanceView.restartCount
    Write-Note "state        : $state"
    Write-Note "private IP   : $($cg.ipAddress.ip)"
    Write-Note "restarts     : $restarts"

    if ($state -ne 'Running') {
        Write-Note 'the hub prober is not running; only the spoke vantage point will have data.' 'Yellow'
    }
    if ($restarts -gt 3) {
        Write-Note "restart count is high - check 'az container logs'." 'Yellow'
    }
}
catch {
    Write-Note "could not read the container group: $($_.Exception.Message)" 'Yellow'
}

##############################################################################
Write-Section '2/4  Collector health'
##############################################################################
$health = $null
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/healthz" -TimeoutSec 20
    Write-Note "status       : $($health.status)"
    Write-Note "samples held : $($health.samples)"
}
catch {
    Write-Note "collector unreachable at $baseUrl : $($_.Exception.Message)" 'Yellow'
    Write-Note 'If this times out, the NSG may not permit your current public IP.' 'Yellow'
    Write-Note 'Re-run 00-configure (or set probe_dashboard_allowed_cidrs) and re-apply.' 'Yellow'
    if (-not $Json) { return }
}

##############################################################################
Write-Section '3/4  Percentiles by vantage point'
##############################################################################
$summary = $null
try {
    $summary = Invoke-RestMethod -Uri "$baseUrl/api/summary?window=$Window" -TimeoutSec 30
}
catch {
    Write-Note "could not read the summary: $($_.Exception.Message)" 'Yellow'
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 12
    return
}

$vantages = @()
if ($summary) { $vantages = @($summary.PSObject.Properties.Name | Sort-Object) }

if (-not $vantages) {
    Write-Note 'no samples in this window yet.' 'Yellow'
    Write-Note 'A freshly applied probe needs a minute or two before it reports.' 'Yellow'
}

$rows = foreach ($name in $vantages) {
    $v = $summary.$name
    foreach ($metric in @('tcp_ms', 'icmp_ms')) {
        $m = $v.$metric
        if (-not $m -or $null -eq $m.p50) { continue }
        [pscustomobject]@{
            vantage = $name
            metric  = if ($metric -eq 'tcp_ms') { "tcp/$($v.tcp_port)" } else { 'icmp' }
            samples = $m.count
            min     = Format-Ms $m.min
            p50     = Format-Ms $m.p50
            p95     = Format-Ms $m.p95
            p99     = Format-Ms $m.p99
            max     = Format-Ms $m.max
            'loss%' = if ($null -eq $m.loss_pct) { '-' } else { '{0:N1}' -f $m.loss_pct }
        }
    }
}

if ($rows) {
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Note 'All figures are milliseconds round-trip to the AWS instance PRIVATE IP.'
}

foreach ($name in $vantages) {
    if (-not $summary.$name.icmp_supported) {
        Write-Note "$name reports ICMP unsupported - it lacks the raw socket capability, so only TCP is measured." 'Yellow'
    }
}

##############################################################################
Write-Section '4/4  Cost of the region split'
##############################################################################
# This is the number the whole probe exists to produce.
$hub   = $vantages | Where-Object { $_ -like '*hub*' }   | Select-Object -First 1
$spoke = $vantages | Where-Object { $_ -like '*spoke*' } | Select-Object -First 1

if ($hub -and $spoke) {
    $h = $summary.$hub.tcp_ms.p50
    $s = $summary.$spoke.tcp_ms.p50

    if ($null -ne $h -and $null -ne $s) {
        $delta = $s - $h
        $pct   = if ($s -gt 0) { 100.0 * $delta / $s } else { 0 }

        Write-Host ("  {0,-26} p50 {1,8} ms" -f $hub, (Format-Ms $h)) -ForegroundColor Green
        Write-Host ("  {0,-26} p50 {1,8} ms" -f $spoke, (Format-Ms $s)) -ForegroundColor Yellow
        Write-Host ''
        Write-Host ("  region-split cost : {0} ms  ({1:N0}% of the spoke figure)" -f (Format-Ms $delta), $pct) -ForegroundColor White
        Write-Note 'That much of the spoke measurement is the inter-region hop, not the interconnect.'
    }
    else {
        Write-Note 'not enough data in both vantage points yet.' 'Yellow'
    }
}
else {
    Write-Note 'need both a hub and a spoke vantage point to compute the delta.' 'Yellow'
}

if (-not $Json) {
    Write-Host ''
    Write-Host "  Live chart: $baseUrl" -ForegroundColor Cyan
    Write-Host ''
}

<#
.SYNOPSIS
    Validates the private Azure <-> AWS path over the multicloud interconnect.

.DESCRIPTION
    Checks the control plane on both sides (are the remote prefixes actually
    being learned?) and then the data plane (can the VMs reach each other over
    private addresses?).

    Run after `terraform apply`.
#>
[CmdletBinding()]
param(
    [string]$AwsProfile,
    [string]$AzureSubscription,
    [switch]$SkipDataPlane
)

$ErrorActionPreference = 'Stop'

$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
}

$tfDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'
$tf    = terraform -chdir="$tfDir" output -json | ConvertFrom-Json

if (-not $tf.resource_names) {
    throw "Terraform output 'resource_names' is missing. Run 'terraform apply' with the current configuration first."
}

# Resource names and identity come from Terraform, never from hardcoded
# defaults. A prefix change used to silently break this script by leaving it
# querying names that no longer existed.
$names = $tf.resource_names.value

if (-not $AwsProfile)        { $AwsProfile        = $tf.aws_profile.value }
if (-not $AzureSubscription) { $AzureSubscription = $tf.azure_subscription_id.value }

$azPrivate  = $tf.azure_vm_private_ip.value
$azPublic   = $tf.azure_vm_public_ip.value
$awsPrivate = $tf.aws_vm_private_ip.value
$awsPublic  = $tf.aws_vm_public_ip.value
$keyPath    = $tf.ssh_private_key_path.value

$interconnectBuilt = $tf.interconnect_built.value
$azureCidr      = $tf.cidrs.value.azure_supernet
$azureSpokeCidr = $tf.cidrs.value.azure_spoke
$awsCidr        = $tf.cidrs.value.aws_vpc

if (-not $interconnectBuilt) {
    Write-Host "`n*** DEMO MODE ***" -ForegroundColor Yellow
    Write-Host "create_interconnect = false, so the clouds are NOT joined." -ForegroundColor Yellow
    Write-Host "Every cross-cloud check below is EXPECTED to fail until you run:" -ForegroundColor Yellow
    Write-Host "  pwsh scripts/03-interconnect.ps1 -Action Connect`n" -ForegroundColor Yellow
}

function Test-CidrContains {
    param([string]$Outer, [string]$Inner)
    $o = $Outer -split '/'; $i = $Inner -split '/'
    $outerLen = [int]$o[1]; $innerLen = [int]$i[1]
    if ($innerLen -lt $outerLen) { return $false }

    $toUInt = {
        param($ip)
        $b = ([ipaddress]$ip).GetAddressBytes()
        [array]::Reverse($b)
        [System.BitConverter]::ToUInt32($b, 0)
    }

    if ($outerLen -eq 0) { return $true }
    # Compare only the network bits. Avoids a mask constant entirely: PowerShell
    # parses 0xFFFFFFFF as Int32 -1, and casting that to an unsigned type throws.
    $shift = 32 - $outerLen
    return (((& $toUInt $o[0]) -shr $shift) -eq ((& $toUInt $i[0]) -shr $shift))
}

$failures = @()

##############################################################################
Write-Host "`n=== Control plane: Azure gateway learned routes ===" -ForegroundColor Cyan
##############################################################################

$rgName = $names.resource_group
$gwName = $names.er_gateway

$learned = az network vnet-gateway list-learned-routes `
    --name $gwName --resource-group $rgName `
    --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json

if ($learned -and $learned.value) {
    $learned.value |
        Select-Object network, nextHop, origin, asPath, sourcePeer |
        Format-Table -AutoSize | Out-String | Write-Host

    if ($learned.value.network -contains $awsCidr) {
        Write-Host "  [ok] Azure is learning $awsCidr from AWS." -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] Azure is NOT learning $awsCidr." -ForegroundColor Red
        $failures += 'Azure gateway is not learning the AWS prefix'
    }
}
else {
    Write-Host "  [FAIL] no learned routes returned; the ExpressRoute connection may still be provisioning." -ForegroundColor Red
    $failures += 'No learned routes on the Azure gateway'
}

##############################################################################
Write-Host "`n=== Control plane: AWS VPC route table propagation ===" -ForegroundColor Cyan
##############################################################################

$rts = (aws ec2 describe-route-tables `
    --filters "Name=tag:Name,Values=$($names.aws_route_table)" `
    --profile $AwsProfile --output json | ConvertFrom-Json).RouteTables

if ($rts -and $rts.Count -gt 0) {
    $routes = $rts[0].Routes
    $routes | Select-Object DestinationCidrBlock, GatewayId, Origin, State |
        Format-Table -AutoSize | Out-String | Write-Host

    # ExpressRoute advertises the individual VNet prefixes (hub /24 and spoke
    # /24), not the 10.100.0.0/16 supernet, so match on containment.
    $propagated = $routes | Where-Object {
        $_.DestinationCidrBlock -and (Test-CidrContains $azureCidr $_.DestinationCidrBlock)
    }
    $spoke = $propagated | Where-Object { $_.DestinationCidrBlock -eq $azureSpokeCidr }

    if ($spoke) {
        Write-Host "  [ok] AWS route table has $azureSpokeCidr (origin: $($spoke.Origin))." -ForegroundColor Green
    }
    elseif ($propagated) {
        Write-Host "  [FAIL] AWS learned $($propagated.DestinationCidrBlock -join ', ') but not the spoke prefix $azureSpokeCidr." -ForegroundColor Red
        $failures += 'AWS route table has not learned the Azure spoke prefix'
    }
    else {
        Write-Host "  [FAIL] AWS route table is missing every prefix inside $azureCidr." -ForegroundColor Red
        $failures += 'AWS route table has not learned the Azure prefixes'
    }
}
else {
    Write-Host "  [FAIL] route table $($names.aws_route_table) not found." -ForegroundColor Red
    $failures += 'AWS route table not found'
}

##############################################################################
Write-Host "`n=== Control plane: Direct Connect Gateway association ===" -ForegroundColor Cyan
##############################################################################

$dxGwId = $tf.dx_gateway_id.value
$assocs = (aws directconnect describe-direct-connect-gateway-associations `
    --direct-connect-gateway-id $dxGwId `
    --profile $AwsProfile --output json | ConvertFrom-Json).directConnectGatewayAssociations

foreach ($a in $assocs) {
    Write-Host ("  {0} -> {1} ({2})  prefixes: {3}" -f `
        $a.associationState, $a.associatedGateway.id, $a.associatedGateway.type,
        (($a.associatedGateway.region), ($a.allowedPrefixesToDirectConnectGateway.cidr -join ',') -join ' '))
}
if ($assocs | Where-Object { $_.associationState -eq 'associated' }) {
    Write-Host '  [ok] at least one association is in state "associated".' -ForegroundColor Green
}
else {
    Write-Host '  [FAIL] no association in state "associated".' -ForegroundColor Red
    $failures += 'DXGW association is not associated'
}

##############################################################################
if (-not $SkipDataPlane) {
    Write-Host "`n=== Data plane: VM to VM over private addresses ===" -ForegroundColor Cyan

    # Terraform writes the key with inherited ACLs, which OpenSSH rejects as
    # "UNPROTECTED PRIVATE KEY FILE". Strip inheritance and grant the current
    # user read-only before attempting any SSH.
    if (Test-Path $keyPath) {
        $winPath = (Resolve-Path $keyPath).Path
        icacls $winPath /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [warn] could not tighten permissions on $winPath; SSH may refuse the key." -ForegroundColor Yellow
        }
    }

    $sshOpts = @('-i', $keyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=15')

    Write-Host "`n  Azure ($azPrivate) -> AWS ($awsPrivate)" -ForegroundColor Yellow
    $out = & ssh @sshOpts "azureuser@$azPublic" "ping -c 4 -W 3 $awsPrivate; echo '--- MTU probe ---'; ping -M do -s 1372 -c 2 -W 3 $awsPrivate" 2>&1
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) { $failures += 'Azure -> AWS ping failed' }

    Write-Host "`n  AWS ($awsPrivate) -> Azure ($azPrivate)" -ForegroundColor Yellow
    $out = & ssh @sshOpts "ec2-user@$awsPublic" "ping -c 4 -W 3 $azPrivate; echo '--- traceroute ---'; traceroute -n -w 2 -m 8 $azPrivate" 2>&1
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) { $failures += 'AWS -> Azure ping failed' }
}

##############################################################################
if ($names.probe_enabled) {
    Write-Host "`n=== Latency probe ===" -ForegroundColor Cyan

    # Control-plane only, so this still runs under -SkipDataPlane. It answers
    # "are both vantage points reporting?" - 05-latency.ps1 is where the actual
    # numbers live.
    $cgState = az container show --name $names.probe_container_group `
        --resource-group $rgName --subscription $AzureSubscription `
        --query "containers[0].instanceView.currentState.state" -o tsv 2>$null

    if ($cgState -eq 'Running') {
        Write-Host "  [ok] hub prober $($names.probe_container_group) is running." -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] hub prober $($names.probe_container_group) is '$cgState', not Running." -ForegroundColor Red
        $failures += 'latency probe container group is not running'
    }

    $probeUrl = ($tf.probe_dashboard_url.value).TrimEnd('/')
    try {
        $summary = Invoke-RestMethod -Uri "$probeUrl/api/summary?window=15m" -TimeoutSec 20
        $reporting = @($summary.PSObject.Properties.Name)

        foreach ($v in $reporting) {
            Write-Host "  [ok] $v reporting ($($summary.$v.samples) samples in 15m)." -ForegroundColor Green
        }

        if ($reporting.Count -lt 2) {
            # One vantage point cannot produce the hub-versus-spoke delta, which
            # is the only reason the probe exists.
            Write-Host "  [warn] only $($reporting.Count) vantage point(s) reporting; expected 2." -ForegroundColor Yellow
            Write-Host '         A freshly applied probe needs a minute or two before both appear.' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  [warn] collector unreachable at $probeUrl : $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '         Check that the NSG permits your current public IP on the dashboard port.' -ForegroundColor Yellow
    }
}

##############################################################################
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($failures.Count -eq 0) {
    Write-Host '  All checks passed - the private cross-cloud path is up.' -ForegroundColor Green
    exit 0
}
Write-Host "  $($failures.Count) check(s) failed:" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
exit 1

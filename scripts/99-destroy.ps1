<#
.SYNOPSIS
    Tears down the lab and confirms the expensive resource is actually gone.

.DESCRIPTION
    The ExpressRoute virtual network gateway is ~85% of this lab's running cost
    (~USD 140/month), so this script verifies its deletion rather than trusting
    a clean `terraform destroy` exit code.

    The Multicloud Interconnect circuit and the AWS Interconnect connection are
    only managed by this repo when interconnect_mode = "create". In that mode
    Terraform destroys both, and this script verifies the billable AWS port is
    really gone. With the default "existing" mode both are left intact.

    Expect 10-20 minutes, dominated by ExpressRoute gateway deletion.
#>
[CmdletBinding()]
param(
    [string]$AwsProfile,
    [string]$AzureSubscription,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
}

$tfDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'terraform'

# Read everything needed for the post-destroy checks BEFORE destroying, because
# `terraform output` returns nothing once the state has been emptied.
$tf = terraform -chdir="$tfDir" output -json 2>$null | ConvertFrom-Json

if ($tf -and $tf.resource_names) {
    $names            = $tf.resource_names.value
    $rg               = $names.resource_group
    $prefix           = $names.prefix
    $vgwName          = "vgw-$($names.prefix)"
    $probeGroup       = $names.probe_container_group
    $interconnectMode = $tf.interconnect_mode.value
    if (-not $AwsProfile)        { $AwsProfile        = $tf.aws_profile.value }
    if (-not $AzureSubscription) { $AzureSubscription = $tf.azure_subscription_id.value }
}
else {
    Write-Host 'No Terraform outputs found - falling back to prefix-based names.' -ForegroundColor Yellow
    $prefix           = Read-Host 'Resource name prefix (e.g. mcilab)'
    $rg               = "rg-$prefix-azure"
    $vgwName          = "vgw-$prefix"
    $probeGroup       = "ci-$prefix-probe"
    $interconnectMode = 'existing'
    if (-not $AwsProfile)        { $AwsProfile        = Read-Host 'AWS profile' }
    if (-not $AzureSubscription) { $AzureSubscription = Read-Host 'Azure subscription id' }
}

if (-not $Force) {
    Write-Host "`nThis destroys the lab VNet, VPC, both gateways and both VMs." -ForegroundColor Yellow
    if ($interconnectMode -eq 'create') {
        Write-Host "interconnect_mode = 'create': the Multicloud circuit AND the AWS" -ForegroundColor Yellow
        Write-Host "interconnect connection were built by Terraform and WILL ALSO BE DESTROYED." -ForegroundColor Yellow
    }
    else {
        Write-Host "Your existing interconnect circuit and AWS connection are NOT touched." -ForegroundColor Yellow
    }
    $answer = Read-Host 'Type DESTROY to continue'
    if ($answer -ne 'DESTROY') { Write-Host 'Aborted.'; exit 1 }
}

Write-Host "`n=== terraform destroy ===" -ForegroundColor Cyan
terraform -chdir="$tfDir" destroy -auto-approve
$tfExit = $LASTEXITCODE

Write-Host "`n=== Verifying the ExpressRoute gateway is gone ===" -ForegroundColor Cyan
$rgExists = az group exists --name $rg --subscription $AzureSubscription -o tsv 2>$null

if ($rgExists -eq 'true') {
    $gws = az network vnet-gateway list --resource-group $rg --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json
    if ($gws -and $gws.Count -gt 0) {
        Write-Host "  [FAIL] $($gws.Count) virtual network gateway(s) still exist in $rg - YOU ARE STILL BEING BILLED." -ForegroundColor Red
        $gws | ForEach-Object { Write-Host "         - $($_.name) ($($_.sku.name))" -ForegroundColor Red }
        exit 1
    }
    Write-Host "  [ok] no virtual network gateways remain in $rg." -ForegroundColor Green

    # The container group is a fraction of the gateway's cost, but it bills per
    # second for as long as it exists, so a leftover one bills forever quietly.
    if ($probeGroup) {
        $cgs = az container list --resource-group $rg --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json
        if ($cgs -and $cgs.Count -gt 0) {
            Write-Host "  [FAIL] $($cgs.Count) container group(s) still exist in $rg - STILL BILLING." -ForegroundColor Red
            $cgs | ForEach-Object { Write-Host "         - $($_.name)" -ForegroundColor Red }
            exit 1
        }
        Write-Host "  [ok] no container groups remain in $rg." -ForegroundColor Green
    }

    Write-Host "  [note] resource group $rg still exists." -ForegroundColor Yellow
}
else {
    Write-Host "  [ok] resource group $rg no longer exists." -ForegroundColor Green
}

Write-Host "`n=== Verifying the DXGW association is released ===" -ForegroundColor Cyan
$vgws = (aws ec2 describe-vpn-gateways `
    --filters "Name=tag:Name,Values=$vgwName" "Name=state,Values=available,pending" `
    --profile $AwsProfile --output json 2>$null | ConvertFrom-Json).VpnGateways

if ($vgws -and $vgws.Count -gt 0) {
    Write-Host "  [FAIL] virtual private gateway still present: $($vgws[0].VpnGatewayId)" -ForegroundColor Red
    exit 1
}
Write-Host '  [ok] no lab virtual private gateway remains.' -ForegroundColor Green

# In create mode Terraform owns the transport itself. The AWS interconnect is a
# billable port, so an orphan here quietly costs real money - which is exactly
# the class of failure this script exists to catch.
if ($interconnectMode -eq 'create') {
    Write-Host "`n=== Verifying the Terraform-built interconnect pair is gone ===" -ForegroundColor Cyan

    if ($rgExists -eq 'true') {
        $circuits = az network express-route list --resource-group $rg --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json
        if ($circuits -and $circuits.Count -gt 0) {
            Write-Host "  [FAIL] $($circuits.Count) ExpressRoute circuit(s) still exist in $rg." -ForegroundColor Red
            $circuits | ForEach-Object { Write-Host "         - $($_.name)" -ForegroundColor Red }
            exit 1
        }
    }
    Write-Host '  [ok] no Multicloud circuit remains.' -ForegroundColor Green

    # Matched on description because Terraform sets it from the prefix, and the
    # DXGW it attached to has been destroyed by this point.
    $desc  = "Azure to AWS multicloud interconnect $prefix"
    $conns = @((aws interconnect list-connections --profile $AwsProfile --output json 2>$null |
                ConvertFrom-Json).connections |
               Where-Object { $_.description -eq $desc -and $_.state -notin @('deleted', 'deleting') })

    if ($conns.Count -gt 0) {
        Write-Host '  [FAIL] AWS interconnect connection still present - YOU ARE STILL BEING BILLED.' -ForegroundColor Red
        $conns | ForEach-Object { Write-Host "         - $($_.id) (state: $($_.state))" -ForegroundColor Red }
        exit 1
    }
    Write-Host '  [ok] no lab AWS interconnect connection remains.' -ForegroundColor Green

    Write-Host "`nTeardown complete. The Terraform-built Multicloud circuit and AWS interconnect were destroyed.`n" -ForegroundColor Cyan
}
else {
    Write-Host "`nTeardown complete. Your existing interconnect circuit and AWS connection are untouched.`n" -ForegroundColor Cyan
}
exit $tfExit

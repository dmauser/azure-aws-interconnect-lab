<#
.SYNOPSIS
    Tears down the lab and confirms the expensive resource is actually gone.

.DESCRIPTION
    The ExpressRoute virtual network gateway is ~85% of this lab's running cost
    (~USD 140/month), so this script verifies its deletion rather than trusting
    a clean `terraform destroy` exit code.

    The Multicloud Interconnect circuit (ER-AWS-Lab) and the AWS Interconnect
    connection (mcc-EXAMPLE01) are NOT managed by this repo and are left intact.

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
    $vgwName          = "vgw-$($names.prefix)"
    $interconnectMode = $tf.interconnect_mode.value
    if (-not $AwsProfile)        { $AwsProfile        = $tf.aws_profile.value }
    if (-not $AzureSubscription) { $AzureSubscription = $tf.azure_subscription_id.value }
}
else {
    Write-Host 'No Terraform outputs found - falling back to prefix-based names.' -ForegroundColor Yellow
    $prefix           = Read-Host 'Resource name prefix (e.g. mcilab)'
    $rg               = "rg-$prefix-azure"
    $vgwName          = "vgw-$prefix"
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

Write-Host "`nTeardown complete. ER-AWS-Lab and mcc-EXAMPLE01 are untouched.`n" -ForegroundColor Cyan
exit $tfExit

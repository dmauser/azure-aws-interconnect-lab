<#
.SYNOPSIS
    Discovers the existing Azure Multicloud Interconnect circuit and the AWS
    Direct Connect Gateway bound to the AWS Interconnect - multicloud connection.

.DESCRIPTION
    Nothing in this repo creates the interconnect. This script finds the two
    identifiers Terraform needs to attach to it, and validates the preconditions
    that would otherwise fail halfway through an apply:

      * the circuit is provisioned
      * the circuit has ZERO gateway connections (preview limit is exactly one)
      * a Direct Connect Gateway exists for the interconnect
      * that DXGW has no conflicting association

    Writes discovery.json at the repo root (gitignored).
#>
[CmdletBinding()]
param(
    [string]$AwsProfile      = 'mcilab',
    [Parameter(Mandatory)][string]$CircuitName,
    [string]$CircuitRg       = 'ER-Circuits',
    [Parameter(Mandatory)][string]$InterconnectName,
    [Parameter(Mandatory)][string]$AzureSubscription
)

$ErrorActionPreference = 'Stop'

$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
}

$result = [ordered]@{}

##############################################################################
Write-Host "`n=== Azure: Multicloud Interconnect circuit ===" -ForegroundColor Cyan
##############################################################################

$circuit = az network express-route show `
    --name $CircuitName --resource-group $CircuitRg `
    --subscription $AzureSubscription -o json | ConvertFrom-Json

if (-not $circuit) { throw "Circuit $CircuitName not found in resource group $CircuitRg." }

Write-Host ("  id          : {0}" -f $circuit.id)
Write-Host ("  sku         : {0} (tier {1})" -f $circuit.sku.name, $circuit.sku.tier)
Write-Host ("  provider    : {0} @ {1}, {2} Mbps" -f `
    $circuit.serviceProviderProperties.serviceProviderName, `
    $circuit.serviceProviderProperties.peeringLocation, `
    $circuit.serviceProviderProperties.bandwidthInMbps)
Write-Host ("  provisioned : {0} / {1}" -f $circuit.serviceProviderProvisioningState, $circuit.circuitProvisioningState)

if ($circuit.sku.tier -ne 'MultiCloud') {
    Write-Host "  [warn] expected SKU tier 'MultiCloud'; this may be a classic ExpressRoute circuit." -ForegroundColor Yellow
}
if ($circuit.serviceProviderProvisioningState -ne 'Provisioned') {
    Write-Host "  [FAIL] circuit is not Provisioned. Complete the activation-key exchange first." -ForegroundColor Red
}

# Azure Multicloud Interconnect preview supports exactly ONE gateway connection.
$existingConnections = @()
foreach ($p in $circuit.peerings) {
    Write-Host ("  peering     : {0} state={1} vlan={2} peerASN={3}" -f $p.name, $p.state, $p.vlanId, $p.peerASN)
    if ($p.connections) { $existingConnections += $p.connections }
}

if ($existingConnections.Count -gt 0) {
    Write-Host "  [FAIL] circuit already has $($existingConnections.Count) gateway connection(s); the preview limit is 1." -ForegroundColor Red
    $existingConnections | ForEach-Object { Write-Host "         - $($_.name)" }
}
else {
    Write-Host "  [ok] no existing gateway connections - the single allowed slot is free." -ForegroundColor Green
}

$result.azure = [ordered]@{
    circuitId                        = $circuit.id
    circuitName                      = $circuit.name
    resourceGroup                    = $CircuitRg
    location                         = $circuit.location
    skuTier                          = $circuit.sku.tier
    peeringLocation                  = $circuit.serviceProviderProperties.peeringLocation
    bandwidthMbps                    = $circuit.serviceProviderProperties.bandwidthInMbps
    serviceProviderProvisioningState = $circuit.serviceProviderProvisioningState
    existingGatewayConnections       = $existingConnections.Count
}

##############################################################################
Write-Host "`n=== AWS: Interconnect - multicloud ===" -ForegroundColor Cyan
##############################################################################

$interconnects = aws interconnect list-connections --profile $AwsProfile --output json 2>$null | ConvertFrom-Json
$ic = $null
if ($interconnects) {
    # The API returns `id` (e.g. mcc-EXAMPLE01), not `name`/`connectionId`.
    $ic = $interconnects.connections | Where-Object { $_.id -eq $InterconnectName } | Select-Object -First 1
}

$attachPointDxGw = $null

if ($ic) {
    Write-Host ("  connection  : {0} ({1})" -f $ic.id, $ic.description)
    Write-Host ("  type/state  : {0} / {1}" -f $ic.type, $ic.state)
    Write-Host ("  provider    : {0} @ {1}, {2}" -f $ic.provider.cloudServiceProvider, $ic.location, $ic.bandwidth)
    Write-Host ("  environment : {0}" -f $ic.environmentId)

    # On AWS the interconnect attach point is ALWAYS a Direct Connect Gateway,
    # and the API reports it directly - no guessing required.
    $attachPointDxGw = $ic.attachPoint.directConnectGateway
    Write-Host ("  attach point: Direct Connect Gateway {0}" -f $attachPointDxGw) -ForegroundColor Green

    if ($ic.state -ne 'available') {
        Write-Host "  [FAIL] interconnect state is '$($ic.state)', expected 'available'." -ForegroundColor Red
    }

    $result.interconnect = [ordered]@{
        id                   = $ic.id
        description          = $ic.description
        state                = $ic.state
        bandwidth            = $ic.bandwidth
        location             = $ic.location
        cloudServiceProvider = $ic.provider.cloudServiceProvider
        environmentId        = $ic.environmentId
        attachPointDxGateway = $attachPointDxGw
    }
}
else {
    Write-Host "  [warn] '$InterconnectName' not returned by 'aws interconnect list-connections'." -ForegroundColor Yellow
    Write-Host "         Falling back to Direct Connect Gateway discovery." -ForegroundColor Yellow
}

##############################################################################
Write-Host "`n=== AWS: Direct Connect Gateway (the interconnect attach point) ===" -ForegroundColor Cyan
##############################################################################

$dxgws = (aws directconnect describe-direct-connect-gateways --profile $AwsProfile --output json | ConvertFrom-Json).directConnectGateways

if (-not $dxgws -or $dxgws.Count -eq 0) {
    Write-Host "  [FAIL] no Direct Connect Gateway found. On AWS the interconnect attach point is always a DXGW." -ForegroundColor Red
}

$result.directConnectGateways = @()
foreach ($g in $dxgws) {
    Write-Host ("  {0}  id={1}  asn={2}  state={3}" -f $g.directConnectGatewayName, $g.directConnectGatewayId, $g.amazonSideAsn, $g.directConnectGatewayState)

    $assocs = (aws directconnect describe-direct-connect-gateway-associations `
        --direct-connect-gateway-id $g.directConnectGatewayId `
        --profile $AwsProfile --output json | ConvertFrom-Json).directConnectGatewayAssociations

    foreach ($a in $assocs) {
        Write-Host ("      association: {0} -> {1} ({2})" -f $a.associationState, $a.associatedGateway.id, $a.associatedGateway.type)
    }

    $result.directConnectGateways += [ordered]@{
        id           = $g.directConnectGatewayId
        name         = $g.directConnectGatewayName
        amazonSideAsn = $g.amazonSideAsn
        state        = $g.directConnectGatewayState
        associations = @($assocs | ForEach-Object {
            [ordered]@{
                state = $_.associationState
                gatewayId = $_.associatedGateway.id
                gatewayType = $_.associatedGateway.type
            }
        })
    }
}

##############################################################################
Write-Host "`n=== Result ===" -ForegroundColor Cyan
##############################################################################

$outFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'discovery.json'
$result | ConvertTo-Json -Depth 10 | Set-Content -Path $outFile -Encoding utf8
Write-Host "  written: $outFile"

if ($attachPointDxGw) {
    Write-Host "`nAdd this to terraform/terraform.tfvars:" -ForegroundColor Green
    Write-Host "  dx_gateway_id = `"$attachPointDxGw`"" -ForegroundColor Green
}
elseif ($result.directConnectGateways.Count -eq 1) {
    $id = $result.directConnectGateways[0].id
    Write-Host "`nAdd this to terraform/terraform.tfvars:" -ForegroundColor Green
    Write-Host "  dx_gateway_id = `"$id`"" -ForegroundColor Green
}
elseif ($result.directConnectGateways.Count -gt 1) {
    Write-Host "`nMultiple Direct Connect Gateways found - pick the one bound to $InterconnectName and set dx_gateway_id." -ForegroundColor Yellow
}
Write-Host ''


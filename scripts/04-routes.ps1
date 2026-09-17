<#
.SYNOPSIS
    Dumps every routing table on both ends of the interconnect.

.DESCRIPTION
    A read-only diagnostic. Where 02-verify answers "is the path up?" with a
    pass/fail, this answers "what does each device actually believe?" and
    prints it, including the two views 02-verify never shows: what Azure
    ADVERTISES to AWS, and the BGP session state behind it.

    Sections:
      Azure  1. ExpressRoute gateway learned routes (what Azure received)
             2. BGP peer status (the sessions carrying them)
             3. Advertised routes per peer (what Azure sent)
             4. Effective routes on the VM NIC (what the data plane uses)
      AWS    5. VPC route table (what the subnet uses)
             6. Virtual private gateway route propagation
             7. Direct Connect gateway association and allowed prefixes
      Guest  8. Kernel routing table on both VMs (-IncludeGuest)

    Every section is independent. One failing section prints a warning and the
    rest still run, because a half-broken path is exactly when you need this.

.PARAMETER IncludeGuest
    Also SSH to both VMs and print their kernel routing tables.

.PARAMETER OutFile
    Also write the full transcript to a file.

.PARAMETER Json
    Emit one JSON object with every section instead of formatted tables.

.EXAMPLE
    pwsh scripts/04-routes.ps1

.EXAMPLE
    pwsh scripts/04-routes.ps1 -IncludeGuest -OutFile routes.txt

.EXAMPLE
    pwsh scripts/04-routes.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string]$AwsProfile,
    [string]$AzureSubscription,
    [switch]$IncludeGuest,
    [string]$OutFile,
    [switch]$Json
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

$names = $tf.resource_names.value

if (-not $AwsProfile)        { $AwsProfile        = $tf.aws_profile.value }
if (-not $AzureSubscription) { $AzureSubscription = $tf.azure_subscription_id.value }

$rgName  = $names.resource_group
$gwName  = $names.er_gateway
$nicName = "nic-$($names.prefix)-vm"

# Collected for -Json. Each key is filled in by its section, or left null if
# that section could not be read.
$data = [ordered]@{
    learnedRoutes   = $null
    bgpPeers        = $null
    advertisedRoutes= $null
    nicEffective    = $null
    awsRouteTable   = $null
    vgwPropagation  = $null
    dxgwAssociation = $null
    guestRoutes     = $null
}

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

function Show-Table {
    param($Rows, [string[]]$Properties)
    if ($Json) { return }
    if (-not $Rows -or @($Rows).Count -eq 0) {
        Write-Note '(empty)' 'Yellow'
        return
    }
    $Rows | Select-Object $Properties | Format-Table -AutoSize | Out-String | Write-Host
}

if ($OutFile) { Start-Transcript -Path $OutFile -Force | Out-Null }

try {
    if (-not $Json) {
        Write-Host ''
        Write-Host "Routing dump  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
        Write-Host "  gateway : $gwName ($rgName)"
        Write-Host "  aws     : profile $AwsProfile"
    }

    ##########################################################################
    Write-Section 'Azure 1/4  ExpressRoute gateway - LEARNED routes (inbound)'
    ##########################################################################
    try {
        $learned = (az network vnet-gateway list-learned-routes `
                --name $gwName --resource-group $rgName `
                --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json).value
        $data.learnedRoutes = $learned
        Show-Table $learned @('network', 'origin', 'asPath', 'sourcePeer', 'nextHop', 'weight')
        Write-Note 'origin Network = local VNet prefix; origin EBgp = learned across the interconnect.'
    }
    catch {
        Write-Note "could not read learned routes: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    Write-Section 'Azure 2/4  BGP peer status'
    ##########################################################################
    $peers = @()
    try {
        $peers = (az network vnet-gateway list-bgp-peer-status `
                --name $gwName --resource-group $rgName `
                --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json).value
        $data.bgpPeers = $peers
        Show-Table $peers @('neighbor', 'asn', 'state', 'connectedDuration', 'routesReceived', 'messagesSent', 'messagesReceived')
        Write-Note 'A short connectedDuration means the session recently re-established.'
    }
    catch {
        Write-Note "could not read BGP peer status: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    Write-Section 'Azure 3/4  ExpressRoute gateway - ADVERTISED routes (outbound)'
    ##########################################################################
    # The direction 02-verify never checks. If AWS cannot reach the Azure
    # spoke, the cause is almost always that the spoke prefix is missing here,
    # which means gateway transit on the hub/spoke peering is not set up.
    $advertised = [ordered]@{}
    $remotePeers = @($peers | Where-Object { $_.state -eq 'Connected' -and $_.neighbor } | Select-Object -ExpandProperty neighbor)
    if (-not $remotePeers) { Write-Note 'no connected BGP peers, skipping.' 'Yellow' }

    foreach ($peer in $remotePeers) {
        if (-not $Json) { Write-Host "  peer $peer" -ForegroundColor Yellow }
        try {
            $adv = (az network vnet-gateway list-advertised-routes `
                    --name $gwName --resource-group $rgName `
                    --subscription $AzureSubscription --peer $peer -o json 2>$null | ConvertFrom-Json).value
            $advertised[$peer] = $adv
            Show-Table $adv @('network', 'origin', 'asPath', 'nextHop')
        }
        catch {
            Write-Note "could not read advertised routes for ${peer}: $($_.Exception.Message)" 'Yellow'
        }
    }
    $data.advertisedRoutes = $advertised

    ##########################################################################
    Write-Section 'Azure 4/4  Effective routes on the VM NIC (data plane)'
    ##########################################################################
    # Learned routes are the gateway's view. This is what the VM's traffic
    # actually follows, after peering, NSGs and system routes are applied.
    try {
        $eff = (az network nic show-effective-route-table `
                --name $nicName --resource-group $rgName `
                --subscription $AzureSubscription -o json 2>$null | ConvertFrom-Json).value
        $data.nicEffective = $eff
        $rows = $eff | ForEach-Object {
            [pscustomobject]@{
                source    = $_.source
                state     = $_.state
                addressPrefix = ($_.addressPrefix -join ',')
                nextHopType   = $_.nextHopType
                nextHopIp     = ($_.nextHopIpAddress -join ',')
            }
        }
        Show-Table $rows @('source', 'state', 'addressPrefix', 'nextHopType', 'nextHopIp')
        Write-Note 'nextHopType VirtualNetworkGateway on the AWS prefix is the one that matters.'
    }
    catch {
        Write-Note "could not read effective routes for ${nicName}: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    Write-Section 'AWS 1/3  VPC route table'
    ##########################################################################
    try {
        $rts = (aws ec2 describe-route-tables `
                --filters "Name=tag:Name,Values=$($names.aws_route_table)" `
                --profile $AwsProfile --output json | ConvertFrom-Json).RouteTables
        $data.awsRouteTable = $rts
        foreach ($rt in $rts) {
            if (-not $Json) { Write-Host "  $($rt.RouteTableId)" -ForegroundColor Yellow }
            Show-Table $rt.Routes @('DestinationCidrBlock', 'GatewayId', 'Origin', 'State')
        }
        Write-Note 'Origin EnableVgwRoutePropagation = learned from Azure across the interconnect.'
    }
    catch {
        Write-Note "could not read the VPC route table: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    Write-Section 'AWS 2/3  Virtual private gateway propagation'
    ##########################################################################
    try {
        $prop = (aws ec2 describe-route-tables `
                --filters "Name=tag:Name,Values=$($names.aws_route_table)" `
                --profile $AwsProfile --output json | ConvertFrom-Json).RouteTables.PropagatingVgws
        $data.vgwPropagation = $prop
        Show-Table $prop @('GatewayId')
        if (-not $prop) {
            Write-Note 'no propagating VGW: AWS will never install the Azure prefixes.' 'Yellow'
        }
    }
    catch {
        Write-Note "could not read VGW propagation: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    Write-Section 'AWS 3/3  Direct Connect gateway association'
    ##########################################################################
    try {
        $assocs = (aws directconnect describe-direct-connect-gateway-associations `
                --direct-connect-gateway-id $tf.dx_gateway_id.value `
                --profile $AwsProfile --output json | ConvertFrom-Json).directConnectGatewayAssociations
        $data.dxgwAssociation = $assocs
        $rows = $assocs | ForEach-Object {
            [pscustomobject]@{
                state          = $_.associationState
                associatedGw   = $_.associatedGateway.id
                type           = $_.associatedGateway.type
                region         = $_.associatedGateway.region
                allowedPrefixes= ($_.allowedPrefixesToDirectConnectGateway.cidr -join ', ')
            }
        }
        Show-Table $rows @('state', 'associatedGw', 'type', 'region', 'allowedPrefixes')
        Write-Note 'allowedPrefixes filters what AWS accepts toward the DXGW; empty means no filter.'
    }
    catch {
        Write-Note "could not read the DXGW association: $($_.Exception.Message)" 'Yellow'
    }

    ##########################################################################
    if ($IncludeGuest) {
        Write-Section 'Guest  kernel routing tables'
        ##########################################################################
        $keyPath = $tf.ssh_private_key_path.value
        if (Test-Path $keyPath) {
            $winPath = (Resolve-Path $keyPath).Path
            icacls $winPath /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
        }
        $sshOpts = @('-i', $keyPath, '-o', 'StrictHostKeyChecking=no',
                     '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=15')
        $guest = [ordered]@{}
        foreach ($t in @(
                @{ Name = 'azure'; User = 'azureuser'; Host = $tf.azure_vm_public_ip.value },
                @{ Name = 'aws';   User = 'ec2-user';  Host = $tf.aws_vm_public_ip.value })) {
            if (-not $t.Host) { continue }
            if (-not $Json) { Write-Host "  $($t.Name) VM ($($t.Host))" -ForegroundColor Yellow }
            $out = & ssh @sshOpts "$($t.User)@$($t.Host)" 'ip route show; echo "--- mtu ---"; ip link show | grep -E "^[0-9]+: (eth|ens)"' 2>&1
            $guest[$t.Name] = $out
            if (-not $Json) { $out | ForEach-Object { Write-Host "    $_" } }
        }
        $data.guestRoutes = $guest
    }

    if ($Json) { $data | ConvertTo-Json -Depth 12 }
}
finally {
    if ($OutFile) { Stop-Transcript | Out-Null }
}

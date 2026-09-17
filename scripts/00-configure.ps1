<#
.SYNOPSIS
    One-stop prerequisite check, cloud sign-in and configuration for the
    Azure <-> AWS Multicloud Interconnect lab.

.DESCRIPTION
    Run this first. Nothing else in the repo works until it succeeds.

    It refuses to continue unless every prerequisite is genuinely satisfied:

      1. Tooling        - terraform, az, aws present and new enough
      2. Azure identity - signed in, and a subscription actively selected
      3. AWS identity   - a working profile that resolves to a real account
      4. Interconnect   - an existing MultiCloud circuit on the Azure side and
                          its Direct Connect Gateway attach point on the AWS side
      5. Capacity       - the chosen VM region can actually run the VM size

    It then writes terraform/terraform.tfvars with YOUR identifiers. Nothing in
    this repo ships with anyone else's subscription or account baked in.

.EXAMPLE
    pwsh scripts/00-configure.ps1

.EXAMPLE
    pwsh scripts/00-configure.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -AwsProfile mcilab -Prefix mcilab -NonInteractive
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$AwsProfile,
    [string]$AwsRegion    = 'us-east-1',
    [string]$Prefix       = 'mcilab',
    [string]$CircuitName,
    [string]$CircuitRg,
    [string]$InterconnectName,
    [string]$VmLocation   = 'eastus2',
    [string]$VmSize       = 'Standard_B1s',

    # Where the interconnect itself comes from.
    #   existing - bring your own circuit + AWS interconnect (default, free)
    #   create   - Terraform builds the pair (provisions a BILLED AWS port)
    # Left empty to prompt based on what discovery actually finds.
    [ValidateSet('', 'existing', 'create')]
    [string]$InterconnectMode = '',

    # Interconnect peering location used only when creating a new pair.
    [string]$PeeringLocationChoice = 'useast',

    # Build the landing zones but leave the two clouds unjoined, so the link
    # itself can be created live in front of an audience.
    [switch]$DemoMode,

    # Fail instead of prompting. For CI.
    [switch]$NonInteractive,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:Failed = @()

##############################################################################
# Output helpers
##############################################################################

function Write-Step { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "         $Text" -ForegroundColor DarkGray }
function Write-Bad  {
    param([string]$Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
    $script:Failed += $Text
}

function Assert-Clean {
    param([string]$Stage)
    if ($script:Failed.Count -gt 0) {
        Write-Host "`n$Stage cannot continue:" -ForegroundColor Red
        $script:Failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        throw "$Stage failed. Fix the items above and re-run."
    }
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if ($NonInteractive) { return $Default }
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

# Numbered menu. Returns the selected object.
function Select-Item {
    param(
        [object[]]$Items,
        [scriptblock]$Label,
        [string]$What
    )
    if ($Items.Count -eq 0) { return $null }
    if ($Items.Count -eq 1) { return $Items[0] }
    if ($NonInteractive) {
        throw "Multiple $What found and -NonInteractive was supplied. Pass the value explicitly."
    }
    Write-Host "`n  Multiple $What found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), (& $Label $Items[$i]))
    }
    while ($true) {
        $sel = Read-Host "  Select 1-$($Items.Count)"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $Items.Count) {
            return $Items[[int]$sel - 1]
        }
    }
}

##############################################################################
# 1. Tooling
##############################################################################

Write-Step 'Tooling'

# The AWS MSI installs here but the current shell may predate the PATH update.
$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
    Write-Info "added $awsBin to PATH for this session"
}

function Test-Tool {
    param([string]$Name, [string]$Hint, [version]$Minimum, [scriptblock]$VersionOf)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Bad "$Name not found  ->  $Hint"
        return
    }
    if ($VersionOf) {
        try {
            $v = & $VersionOf
            if ($v -and $Minimum -and $v -lt $Minimum) {
                Write-Bad "$Name $v is older than the required $Minimum  ->  $Hint"
                return
            }
            Write-Ok "$Name $v"
            return
        }
        catch { Write-Ok "$Name (version undetermined)"; return }
    }
    Write-Ok $Name
}

Test-Tool -Name 'terraform' -Hint 'winget install --id Hashicorp.Terraform' -Minimum ([version]'1.5.0') -VersionOf {
    $j = terraform version -json 2>$null | ConvertFrom-Json
    [version]$j.terraform_version
}
Test-Tool -Name 'az' -Hint 'winget install --id Microsoft.AzureCLI' -Minimum ([version]'2.50.0') -VersionOf {
    $j = az version -o json 2>$null | ConvertFrom-Json
    [version]$j.'azure-cli'
}
Test-Tool -Name 'aws' -Hint 'winget install --id Amazon.AWSCLI' -Minimum ([version]'2.0.0') -VersionOf {
    $raw = (aws --version 2>&1).ToString()
    if ($raw -match 'aws-cli/(\d+\.\d+\.\d+)') { [version]$Matches[1] }
}

if (Get-Command ssh -ErrorAction SilentlyContinue) { Write-Ok 'ssh' }
else { Write-Warn 'ssh not found - you will not be able to log in to the VMs to test the path' }

Assert-Clean 'Tooling'

##############################################################################
# 2. Azure identity and subscription selection
##############################################################################

Write-Step 'Azure sign-in'

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    if ($NonInteractive) { throw 'Not signed in to Azure and -NonInteractive was supplied. Run: az login' }
    Write-Warn 'not signed in - launching az login'
    az login --only-show-errors | Out-Null
    $acct = az account show -o json 2>$null | ConvertFrom-Json
}
if (-not $acct) { throw 'az login did not produce a usable session.' }
Write-Ok "signed in as $($acct.user.name)"

# Actively select the subscription rather than trusting whatever was current.
if (-not $SubscriptionId) {
    $subs = @(az account list --all -o json | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' })
    if ($subs.Count -eq 0) { Write-Bad 'no enabled subscriptions on this account'; Assert-Clean 'Azure' }

    Write-Host "`n  Subscriptions available:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $marker = if ($subs[$i].id -eq $acct.id) { '*' } else { ' ' }
        Write-Host ("    [{0}]{1} {2}  ({3})" -f ($i + 1), $marker, $subs[$i].name, $subs[$i].id)
    }
    Write-Info '* = currently selected'

    if ($NonInteractive) {
        $SubscriptionId = $acct.id
    }
    else {
        $def = ($subs | ForEach-Object { $_.id }).IndexOf($acct.id) + 1
        if ($def -lt 1) { $def = 1 }
        $sel = Read-Default -Prompt "  Select subscription 1-$($subs.Count)" -Default "$def"
        if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $subs.Count) {
            throw "Invalid selection '$sel'."
        }
        $SubscriptionId = $subs[[int]$sel - 1].id
    }
}

az account set --subscription $SubscriptionId
$acct = az account show -o json | ConvertFrom-Json
if ($acct.id -ne $SubscriptionId) { Write-Bad "failed to select subscription $SubscriptionId" }
Assert-Clean 'Azure'

$TenantId = $acct.tenantId
Write-Ok "using $($acct.name) / $($acct.id)"
Write-Info "tenant $TenantId"

##############################################################################
# 3. AWS identity
##############################################################################

Write-Step 'AWS sign-in'

if (-not $AwsProfile) {
    $profiles = @(aws configure list-profiles 2>$null)
    if ($profiles.Count -gt 0) {
        Write-Host "`n  AWS profiles configured:" -ForegroundColor Cyan
        $profiles | ForEach-Object { Write-Host "    - $_" }
    }
    $AwsProfile = Read-Default -Prompt '  AWS profile to use' -Default $Prefix
}

$identity = aws sts get-caller-identity --profile $AwsProfile --output json 2>$null | ConvertFrom-Json

if (-not $identity) {
    if ($NonInteractive) { throw "AWS profile '$AwsProfile' is not usable and -NonInteractive was supplied." }

    $exists = (aws configure list-profiles 2>$null) -contains $AwsProfile
    if (-not $exists) {
        Write-Warn "profile '$AwsProfile' does not exist"
        Write-Host '    [1] AWS IAM Identity Center / SSO  (recommended)' -ForegroundColor Cyan
        Write-Host '    [2] Static access keys' -ForegroundColor Cyan
        $mode = Read-Default -Prompt '  How do you sign in to AWS' -Default '1'
        if ($mode -eq '2') {
            aws configure --profile $AwsProfile
        }
        else {
            aws configure sso --profile $AwsProfile
        }
    }
    else {
        Write-Warn "profile '$AwsProfile' exists but has no valid session"
    }

    # An SSO profile needs a login; a static-credential profile will no-op here.
    $isSso = (aws configure get sso_start_url --profile $AwsProfile 2>$null)
    if ($isSso) { aws sso login --profile $AwsProfile }

    $identity = aws sts get-caller-identity --profile $AwsProfile --output json 2>$null | ConvertFrom-Json
}

if (-not $identity) {
    Write-Bad "AWS profile '$AwsProfile' still cannot call sts:GetCallerIdentity"
    Assert-Clean 'AWS'
}

$AwsAccountId = $identity.Account
Write-Ok "account $AwsAccountId"
Write-Info $identity.Arn

if (-not $NonInteractive -and -not $Force) {
    $confirm = Read-Default -Prompt "  Deploy the AWS side into account $AwsAccountId? (y/n)" -Default 'y'
    if ($confirm -notmatch '^(y|yes)$') { throw 'Aborted at AWS account confirmation.' }
}

##############################################################################
# 4. The interconnect - Azure side
#
# Two supported shapes, and the script picks between them from what it actually
# finds rather than assuming:
#   existing - attach to a circuit you already own (default, nothing billed)
#   create   - build the Azure circuit here, then pair AWS to it in stage 7
##############################################################################

Write-Step 'Azure Multicloud Interconnect circuit'

if ($CircuitName -and $CircuitRg) {
    $circuits = @(az network express-route show --name $CircuitName --resource-group $CircuitRg -o json |
        ConvertFrom-Json)
}
else {
    $all = @(az network express-route list -o json | ConvertFrom-Json)
    $circuits = @($all | Where-Object { $_.sku.tier -eq 'MultiCloud' })
    if ($circuits.Count -eq 0 -and $all.Count -gt 0) {
        Write-Warn 'no MultiCloud-tier circuit found; falling back to all ExpressRoute circuits'
        $circuits = $all
    }
}

# Decide the mode before touching anything else.
if (-not $InterconnectMode) {
    if ($circuits.Count -gt 0) {
        Write-Ok "found $($circuits.Count) candidate circuit(s) in this subscription"
        Write-Info 'Choose "existing" to attach to one of them, or "create" to build a new pair.'
        if ($NonInteractive) {
            $InterconnectMode = 'existing'
        }
        else {
            $ans = Read-Default -Prompt '  Interconnect mode (existing/create)' -Default 'existing'
            $InterconnectMode = $ans.Trim().ToLower()
        }
    }
    else {
        Write-Warn 'no ExpressRoute / Multicloud Interconnect circuit found in this subscription'
        if ($NonInteractive) {
            Write-Bad 'nothing to attach to, and -InterconnectMode was not specified'
            Assert-Clean 'Interconnect discovery'
        }
        Write-Info 'Terraform can create the circuit and its AWS counterpart for you.'
        $ans = Read-Default -Prompt '  Create a new interconnect pair? (y/n)' -Default 'y'
        if ($ans -match '^(y|yes)$') { $InterconnectMode = 'create' } else { $InterconnectMode = 'existing' }
    }
}

if ($InterconnectMode -notin @('existing', 'create')) {
    throw "InterconnectMode must be 'existing' or 'create', got '$InterconnectMode'."
}

$CircuitId = $null
$circuit   = $null

if ($InterconnectMode -eq 'create') {
    ##########################################################################
    # create: nothing to discover on Azure yet, but the operator must opt in
    # to the AWS charge with their eyes open.
    ##########################################################################
    Write-Warn 'interconnect_mode = "create": Terraform will build a NEW interconnect pair.'
    Write-Info 'Azure Multicloud Interconnect carries no Azure service or egress charge in preview,'
    Write-Info 'but the AWS Interconnect connection is BILLED PER PORT-HOUR at 1 Gbps.'
    Write-Info 'Destroying the lab removes both sides again.'

    if (-not $NonInteractive) {
        $confirm = Read-Default -Prompt '  Understood - provision a billed AWS interconnect? (y/n)' -Default 'n'
        if ($confirm -notmatch '^(y|yes)$') {
            throw 'Aborted - re-run and choose "existing" to attach to a circuit you already own.'
        }
    }

    $PeeringLocation = Read-Default -Prompt '  Interconnect peering location' -Default $PeeringLocationChoice
    Write-Ok "will create a MultiCloud circuit at peering location '$PeeringLocation'"
}
else {
    ##########################################################################
    # existing: attach to what is already there
    ##########################################################################
    if ($circuits.Count -eq 0) {
        Write-Bad 'no ExpressRoute / Multicloud Interconnect circuit found in this subscription'
        Write-Info 'Re-run with -InterconnectMode create to have Terraform build one.'
        Assert-Clean 'Interconnect discovery'
    }

    $circuit = Select-Item -Items $circuits -What 'circuits' -Label {
        param($c) "{0}  (rg {1}, tier {2}, {3})" -f $c.name, $c.id.Split('/')[4], $c.sku.tier, $c.serviceProviderProperties.peeringLocation
    }

    $CircuitId       = $circuit.id
    $PeeringLocation = $circuit.serviceProviderProperties.peeringLocation
    Write-Ok "$($circuit.name)  tier=$($circuit.sku.tier)  peeringLocation=$PeeringLocation"
    Write-Info $CircuitId

    if ($circuit.serviceProviderProvisioningState -ne 'Provisioned') {
        Write-Bad "circuit is '$($circuit.serviceProviderProvisioningState)', expected 'Provisioned'"
    }

    # Multicloud Interconnect preview allows exactly ONE gateway connection.
    $existing = @()
    foreach ($p in $circuit.peerings) { if ($p.connections) { $existing += $p.connections } }
    if ($existing.Count -gt 0) {
        Write-Bad "circuit already has $($existing.Count) gateway connection(s); the limit is 1"
        $existing | ForEach-Object { Write-Info "existing: $($_.name)" }
    }
    else {
        Write-Ok 'the single allowed gateway-connection slot is free'
    }
}

##############################################################################
# 5. Hub region - forced by the circuit, not a free choice
##############################################################################

Write-Step 'Hub region'

# A MultiCloud-tier circuit behaves as a LOCAL circuit: it can only be connected
# to the one Azure region designated for its peering location.
$peeringToRegion = @{
    'useast'         = 'eastus'
    'useast2'        = 'eastus2'
    'uswest'         = 'westus'
    'uswest2'        = 'westus2'
    'uswest3'        = 'westus3'
    'ussouthcentral' = 'southcentralus'
    'usnorthcentral' = 'northcentralus'
    'europewest'     = 'westeurope'
    'europenorth'    = 'northeurope'
    'uksouth'        = 'uksouth'
    'asiasoutheast'  = 'southeastasia'
    'asiaeast'       = 'eastasia'
    'australiaeast'  = 'australiaeast'
    'japaneast'      = 'japaneast'
    'canadacentral'  = 'canadacentral'
    'indiacentral'   = 'centralindia'
}

$key = "$PeeringLocation".ToLower().Replace(' ', '')
if ($peeringToRegion.ContainsKey($key)) {
    $HubLocation = $peeringToRegion[$key]
    Write-Ok "peering location '$PeeringLocation' maps to Azure region '$HubLocation'"
}
else {
    Write-Warn "peering location '$PeeringLocation' is not in the known map"
    $HubLocation = Read-Default -Prompt '  Azure region for the ExpressRoute gateway' -Default 'eastus'
}
Write-Info 'The gateway MUST be in this region. A Local circuit refuses connections from anywhere else.'

##############################################################################
# 6. VM region capacity - the other thing that silently breaks applies
##############################################################################

Write-Step 'VM region capacity'

$VmLocation = Read-Default -Prompt '  Azure region for the spoke VNet and Linux VM' -Default $VmLocation

$skus = @(az vm list-skus --location $VmLocation --size $VmSize --output json 2>$null | ConvertFrom-Json)
$sku  = $skus | Where-Object { $_.name -eq $VmSize } | Select-Object -First 1

if (-not $sku) {
    Write-Warn "could not read SKU data for $VmSize in $VmLocation - continuing, but apply may fail"
}
else {
    $locationBlocked = $sku.restrictions | Where-Object { $_.type -eq 'Location' }
    $zoneBlocked     = $sku.restrictions | Where-Object { $_.type -eq 'Zone' }
    if ($locationBlocked) {
        Write-Bad "$VmSize is NotAvailableForSubscription in $VmLocation (Location-scope restriction)"
        Write-Info 'Pick another region. This is a subscription-level block, not a capacity blip.'
    }
    elseif ($zoneBlocked) {
        Write-Ok "$VmSize available in $VmLocation (zone-restricted only, which does not affect this non-zonal VM)"
    }
    else {
        Write-Ok "$VmSize available in $VmLocation with no restrictions"
    }
}

Assert-Clean 'Azure validation'

##############################################################################
# 7. The interconnect - AWS side
##############################################################################

Write-Step 'AWS Interconnect - multicloud'

$DxGatewayId = $null

if ($InterconnectMode -eq 'create') {
    # Nothing to discover: Terraform creates the Direct Connect Gateway and
    # then redeems the Azure activation key against it.
    Write-Ok 'skipped - Terraform will create the DXGW and the AWS interconnect connection'
    Write-Info 'Azure mints an activation key for the new circuit; awscc redeems it to pair the clouds.'
}
else {

$icJson = aws interconnect list-connections --profile $AwsProfile --output json 2>$null
if ($icJson) {
    $connections = @(($icJson | ConvertFrom-Json).connections)
    if ($InterconnectName) {
        $connections = @($connections | Where-Object { $_.id -eq $InterconnectName })
    }
    if ($connections.Count -gt 0) {
        $ic = Select-Item -Items $connections -What 'interconnects' -Label {
            param($c) "{0}  ({1}, {2}, {3})" -f $c.id, $c.description, $c.state, $c.bandwidth
        }
        Write-Ok "$($ic.id)  state=$($ic.state)  $($ic.bandwidth) @ $($ic.location)"
        if ($ic.state -ne 'available') { Write-Bad "interconnect state is '$($ic.state)', expected 'available'" }

        # On AWS the attach point is ALWAYS a Direct Connect Gateway, and the
        # API reports it directly - no guessing.
        $DxGatewayId = $ic.attachPoint.directConnectGateway
        if ($DxGatewayId) { Write-Ok "attach point: Direct Connect Gateway $DxGatewayId" }
    }
    else {
        Write-Warn 'no matching interconnect returned - falling back to Direct Connect Gateway discovery'
    }
}
else {
    Write-Warn "'aws interconnect list-connections' unavailable - falling back to Direct Connect Gateway discovery"
}

if (-not $DxGatewayId) {
    $dxgws = @((aws directconnect describe-direct-connect-gateways --profile $AwsProfile --output json |
        ConvertFrom-Json).directConnectGateways)
    if ($dxgws.Count -eq 0) {
        Write-Bad 'no Direct Connect Gateway found - the interconnect attach point is always a DXGW'
    }
    else {
        $g = Select-Item -Items $dxgws -What 'Direct Connect Gateways' -Label {
            param($x) "{0}  id={1}  asn={2}  state={3}" -f $x.directConnectGatewayName, $x.directConnectGatewayId, $x.amazonSideAsn, $x.directConnectGatewayState
        }
        $DxGatewayId = $g.directConnectGatewayId
        Write-Ok "using Direct Connect Gateway $DxGatewayId (ASN $($g.amazonSideAsn))"
    }
}

if ($DxGatewayId) {
    $assocs = @((aws directconnect describe-direct-connect-gateway-associations `
        --direct-connect-gateway-id $DxGatewayId --profile $AwsProfile --output json |
        ConvertFrom-Json).directConnectGatewayAssociations)
    $vgwAssocs = @($assocs | Where-Object { $_.associationState -in @('associated', 'associating') })
    if ($vgwAssocs.Count -gt 0) {
        Write-Warn "DXGW already has $($vgwAssocs.Count) association(s):"
        $vgwAssocs | ForEach-Object { Write-Info "$($_.associationState) -> $($_.associatedGateway.id) ($($_.associatedGateway.type))" }
        Write-Info 'A pre-existing association is fine unless it is a leftover from this lab.'
    }
    else {
        Write-Ok 'no conflicting DXGW association'
    }
}

} # end of interconnect_mode = "existing" branch

Assert-Clean 'AWS validation'

##############################################################################
# 8. Access
##############################################################################

Write-Step 'Access'

$MyIp = $null
try {
    $MyIp = (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 15).ToString().Trim()
    Write-Ok "your public IP is $MyIp - $MyIp/32 will be allow-listed for SSH"
}
catch {
    Write-Warn 'could not auto-detect your public IP; Terraform will retry at apply time'
}

##############################################################################
# 9. Write terraform.tfvars
##############################################################################

Write-Step 'Writing configuration'

$Prefix = Read-Default -Prompt '  Resource name prefix' -Default $Prefix
if ($Prefix -notmatch '^[a-z][a-z0-9]{2,11}$') {
    throw "Prefix '$Prefix' must be 3-12 chars, lowercase letters and digits, starting with a letter."
}

$createInterconnect = (-not $DemoMode).ToString().ToLower()

$repoRoot   = Split-Path $PSScriptRoot -Parent
$tfvarsPath = Join-Path $repoRoot 'terraform/terraform.tfvars'

if ((Test-Path $tfvarsPath) -and -not $Force -and -not $NonInteractive) {
    $overwrite = Read-Default -Prompt "  $tfvarsPath exists. Overwrite? (y/n)" -Default 'y'
    if ($overwrite -notmatch '^(y|yes)$') { throw 'Aborted - existing terraform.tfvars left untouched.' }
}

$lines = @(
    "# Generated by scripts/00-configure.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
    '# This file holds YOUR identifiers and is gitignored. Do not commit it.'
    ''
    '# --- Identity -------------------------------------------------------------'
    "azure_subscription_id = `"$SubscriptionId`""
    "azure_tenant_id       = `"$TenantId`""
    "aws_account_id        = `"$AwsAccountId`""
    "aws_profile           = `"$AwsProfile`""
    "aws_region            = `"$AwsRegion`""
    ''
    '# --- Interconnect ---------------------------------------------------------'
    "interconnect_mode = `"$InterconnectMode`""
)

if ($InterconnectMode -eq 'create') {
    $lines += @(
        '# Terraform creates BOTH sides of the pair and destroys them on teardown.'
        '# The AWS interconnect connection is billed per port-hour.'
        "interconnect_peering_location = `"$PeeringLocation`""
    )
}
else {
    $lines += @(
        '# Brought by you; never created or destroyed by this lab.'
        "express_route_circuit_id = `"$CircuitId`""
        "dx_gateway_id            = `"$DxGatewayId`""
    )
}

$lines += @(
    ''
    '# --- Placement ------------------------------------------------------------'
    "# Hub is forced by the circuit peering location '$PeeringLocation'."
    "azure_hub_location = `"$HubLocation`""
    "azure_location     = `"$VmLocation`""
    ''
    '# --- Naming ---------------------------------------------------------------'
    "prefix = `"$Prefix`""
    ''
    '# --- Lab mode -------------------------------------------------------------'
    "# false = build both landing zones but leave the clouds unjoined (demo mode)."
    "create_interconnect = $createInterconnect"
)
if ($MyIp) {
    $lines += @('', '# --- Access ---------------------------------------------------------------', "my_public_ip = `"$MyIp/32`"")
}

$lines -join "`n" | Set-Content -Path $tfvarsPath -Encoding utf8
Write-Ok "wrote $tfvarsPath"

##############################################################################
# Summary
##############################################################################

Write-Host "`n=== Ready ===" -ForegroundColor Cyan
Write-Host ("  Azure subscription : {0} ({1})" -f $acct.name, $SubscriptionId)
Write-Host ("  AWS account        : {0} via profile '{1}'" -f $AwsAccountId, $AwsProfile)
Write-Host ("  Interconnect       : {0}" -f $InterconnectMode)
if ($InterconnectMode -eq 'create') {
    Write-Host ("  Circuit            : will be CREATED at peering location {0}" -f $PeeringLocation) -ForegroundColor Yellow
    Write-Host  "  DXGW               : will be CREATED" -ForegroundColor Yellow
    Write-Host  "  Billing            : AWS interconnect port is chargeable" -ForegroundColor Yellow
}
else {
    Write-Host ("  Circuit            : {0}" -f $circuit.name)
    Write-Host ("  DXGW               : {0}" -f $DxGatewayId)
}
Write-Host ("  Gateway region     : {0}  (forced by peering location)" -f $HubLocation)
Write-Host ("  VM region          : {0}" -f $VmLocation)
Write-Host ("  Prefix             : {0}" -f $Prefix)
if ($DemoMode) {
    Write-Host "  Mode               : DEMO - clouds will NOT be joined" -ForegroundColor Yellow
}

Write-Host "`nNext:" -ForegroundColor Cyan
Write-Host '  cd terraform'
Write-Host '  terraform init'
Write-Host '  terraform apply'
Write-Host ''

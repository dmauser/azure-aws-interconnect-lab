<#
.SYNOPSIS
    Prerequisite check + AWS SSO setup for the azure-aws-interconnect-lab lab.

.DESCRIPTION
    Verifies Azure CLI / Terraform / AWS CLI are present and authenticated,
    configures an AWS SSO profile if one does not exist, and reports the
    public IP that will be allow-listed in the NSG and security group.
#>
[CmdletBinding()]
param(
    [string]$AwsProfile       = 'mcilab',
    [Parameter(Mandatory)][string]$AwsAccountId,
    [string]$AwsRegion        = 'us-east-1',
    [Parameter(Mandatory)][string]$AzureSubscription,

    # Supply these to configure the SSO profile non-interactively.
    [string]$SsoStartUrl,
    [string]$SsoRegion,
    [string]$SsoRoleName
)

$ErrorActionPreference = 'Stop'

# The MSI installs here but the current shell may predate the PATH update.
$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
}

function Test-Tool {
    param([string]$Name, [string]$InstallHint)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "  [MISSING] $Name  -> $InstallHint" -ForegroundColor Red
        return $false
    }
    Write-Host "  [ok] $Name  ($($cmd.Source))" -ForegroundColor Green
    return $true
}

Write-Host "`n=== Tooling ===" -ForegroundColor Cyan
$ok = $true
$ok = (Test-Tool -Name 'az'        -InstallHint 'winget install --id Microsoft.AzureCLI') -and $ok
$ok = (Test-Tool -Name 'terraform' -InstallHint 'winget install --id Hashicorp.Terraform') -and $ok
$ok = (Test-Tool -Name 'aws'       -InstallHint 'winget install --id Amazon.AWSCLI') -and $ok
if (-not $ok) { throw 'Install the missing tools and re-run.' }

Write-Host "`n=== Azure ===" -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Write-Host '  Not signed in. Launching az login...' -ForegroundColor Yellow
    az login --only-show-errors | Out-Null
    $acct = az account show -o json | ConvertFrom-Json
}
if ($acct.id -ne $AzureSubscription) {
    Write-Host "  Switching to subscription $AzureSubscription" -ForegroundColor Yellow
    az account set --subscription $AzureSubscription
    $acct = az account show -o json | ConvertFrom-Json
}
Write-Host "  [ok] $($acct.name) / $($acct.id) as $($acct.user.name)" -ForegroundColor Green

Write-Host "`n=== AWS ===" -ForegroundColor Cyan
$identity = aws sts get-caller-identity --profile $AwsProfile --output json 2>$null | ConvertFrom-Json

if (-not $identity) {
    $profileExists = (aws configure list-profiles 2>$null) -contains $AwsProfile

    if (-not $profileExists) {
        if ($SsoStartUrl -and $SsoRegion -and $SsoRoleName) {
            Write-Host "  Creating SSO profile '$AwsProfile' from supplied parameters..." -ForegroundColor Yellow
            aws configure set sso_start_url  $SsoStartUrl  --profile $AwsProfile
            aws configure set sso_region     $SsoRegion    --profile $AwsProfile
            aws configure set sso_account_id $AwsAccountId --profile $AwsProfile
            aws configure set sso_role_name  $SsoRoleName  --profile $AwsProfile
            aws configure set region         $AwsRegion    --profile $AwsProfile
            aws configure set output         json          --profile $AwsProfile
        }
        else {
            Write-Host "  Profile '$AwsProfile' does not exist and no SSO parameters were supplied." -ForegroundColor Yellow
            Write-Host "  Starting interactive setup (a browser window will open)..." -ForegroundColor Yellow
            aws configure sso --profile $AwsProfile
        }
    }

    Write-Host "  Signing in to AWS SSO..." -ForegroundColor Yellow
    aws sso login --profile $AwsProfile
    $identity = aws sts get-caller-identity --profile $AwsProfile --output json | ConvertFrom-Json
}

if ($identity.Account -ne $AwsAccountId) {
    throw "Profile '$AwsProfile' resolves to account $($identity.Account) but the lab expects $AwsAccountId."
}
Write-Host "  [ok] account $($identity.Account) as $($identity.Arn)" -ForegroundColor Green

Write-Host "`n=== Access ===" -ForegroundColor Cyan
try {
    $myIp = (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 15).ToString().Trim()
    Write-Host "  [ok] your public IP is $myIp -> $myIp/32 will be allow-listed for SSH" -ForegroundColor Green
}
catch {
    Write-Host '  [warn] could not auto-detect your public IP; set my_public_ip in terraform.tfvars' -ForegroundColor Yellow
}

Write-Host "`nPrerequisites satisfied. Next: pwsh scripts/01-discover.ps1`n" -ForegroundColor Cyan


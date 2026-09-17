<#
.SYNOPSIS
    Interactively configures the AWS CLI profile used by this lab.

.DESCRIPTION
    Run this in YOUR OWN terminal. It prompts for an AWS access key ID and
    secret access key, writes them to the named profile, and verifies that the
    profile resolves to the expected account.

    The secret is read with -AsSecureString so it is never echoed to the screen
    and never appears in your PowerShell history.

.EXAMPLE
    pwsh scripts/aws-login.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileName  = 'mcilab',
    [string]$Region       = 'us-east-1',
    # Optional. When supplied, the script asserts the profile resolves to this
    # account and fails loudly if it does not.
    [string]$ExpectedAccount
)

$ErrorActionPreference = 'Stop'

# The AWS CLI MSI installs here; a shell opened before the install won't have it on PATH.
$awsBin = 'C:\Program Files\Amazon\AWSCLIV2'
if ((Test-Path $awsBin) -and ($env:Path -notlike "*$awsBin*")) {
    $env:Path = "$awsBin;$env:Path"
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI not found. Install it with:  winget install --id Amazon.AWSCLI"
}

Write-Host ''
Write-Host '  AWS credential setup' -ForegroundColor Cyan
Write-Host '  --------------------' -ForegroundColor Cyan
Write-Host "  Profile : $ProfileName"
if ($ExpectedAccount) { Write-Host "  Account : $ExpectedAccount" }
Write-Host "  Region  : $Region"
Write-Host ''
Write-Host '  Get the values from: IAM -> Users -> <your-lab-iam-user> -> Security credentials -> Create access key' -ForegroundColor DarkGray
Write-Host ''

$keyId = Read-Host '  AWS Access Key ID     (starts with AKIA)'
if ([string]::IsNullOrWhiteSpace($keyId)) { throw 'Access key ID cannot be empty.' }

$secureSecret = Read-Host '  AWS Secret Access Key (input hidden)' -AsSecureString
$secret = [System.Net.NetworkCredential]::new('', $secureSecret).Password
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Secret access key cannot be empty.' }

aws configure set aws_access_key_id     $($keyId.Trim()) --profile $ProfileName
aws configure set aws_secret_access_key $secret       --profile $ProfileName
aws configure set region                $Region       --profile $ProfileName
aws configure set output                json          --profile $ProfileName

# Drop the plaintext secret from memory as soon as it has been written.
$secret = $null
[System.GC]::Collect()

Write-Host ''
Write-Host '  Verifying...' -ForegroundColor Yellow

$identity = aws sts get-caller-identity --profile $ProfileName --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [FAIL] AWS rejected those credentials:' -ForegroundColor Red
    Write-Host "  $identity" -ForegroundColor Red
    Write-Host ''
    Write-Host '  Common causes: the key was copied with trailing whitespace, or the' -ForegroundColor DarkGray
    Write-Host '  key was deactivated/deleted in the console. Create a new one and retry.' -ForegroundColor DarkGray
    exit 1
}

$id = $identity | ConvertFrom-Json
if ($ExpectedAccount -and $id.Account -ne $ExpectedAccount) {
    Write-Host "  [FAIL] Those credentials belong to account $($id.Account), not $ExpectedAccount." -ForegroundColor Red
    exit 1
}

Write-Host "  [ok] Authenticated to account $($id.Account)" -ForegroundColor Green
Write-Host "       as $($id.Arn)" -ForegroundColor Green
Write-Host ''
Write-Host '  Done. Tell the assistant "profile is ready".' -ForegroundColor Cyan
Write-Host ''


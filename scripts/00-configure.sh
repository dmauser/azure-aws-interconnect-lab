#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# One-stop prerequisite check, cloud sign-in and configuration for the
# Azure <-> AWS Multicloud Interconnect lab.
#
# Run this first. Nothing else in the repo works until it succeeds.
#
# It refuses to continue unless every prerequisite is genuinely satisfied:
#
#   1. Tooling        - terraform, az, aws present and new enough
#   2. Azure identity - signed in, and a subscription actively selected
#   3. AWS identity   - a working profile that resolves to a real account
#   4. Interconnect   - an existing MultiCloud circuit on the Azure side and
#                       its Direct Connect Gateway attach point on the AWS side,
#                       unless Terraform is explicitly creating the pair
#   5. Capacity       - the chosen VM region can actually run the VM size
#
# It then writes terraform/terraform.tfvars with YOUR identifiers. Nothing in
# this repo ships with anyone else's subscription or account baked in.
##############################################################################

SUBSCRIPTION_ID=''
AWS_PROFILE=''
AWS_REGION='us-east-1'
PREFIX='mcilab'
CIRCUIT_NAME=''
CIRCUIT_RG=''
INTERCONNECT_NAME=''
VM_LOCATION='eastus2'
VM_SIZE='Standard_B1s'

# Where the interconnect itself comes from.
#   existing - bring your own circuit + AWS interconnect (default, free)
#   create   - Terraform builds the pair (provisions a BILLED AWS port)
# Left empty to prompt based on what discovery actually finds.
INTERCONNECT_MODE=''

# Interconnect peering location used only when creating a new pair.
PEERING_LOCATION_CHOICE='useast'

# Build the landing zones but leave the two clouds unjoined, so the link
# itself can be created live in front of an audience.
DEMO_MODE=false

# Fail instead of prompting. For CI.
NON_INTERACTIVE=false

FORCE=false

FAILED=()

##############################################################################
# Output helpers
##############################################################################

if [[ -t 2 ]]; then
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_DARKGRAY=$'\033[90m'
    C_RED=$'\033[31m'
    C_RESET=$'\033[0m'
else
    C_CYAN=''
    C_GREEN=''
    C_YELLOW=''
    C_DARKGRAY=''
    C_RED=''
    C_RESET=''
fi

Write-Step() { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$1" "$C_RESET" >&2; }
Write-Ok()   { printf '%s  [ok]   %s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
Write-Warn() { printf '%s  [warn] %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
Write-Info() { printf '%s         %s%s\n' "$C_DARKGRAY" "$1" "$C_RESET" >&2; }
Write-Bad()  {
    printf '%s  [FAIL] %s%s\n' "$C_RED" "$1" "$C_RESET" >&2
    FAILED+=("$1")
}

Assert-Clean() {
    local stage=$1
    if ((${#FAILED[@]} > 0)); then
        printf '\n%s%s cannot continue:%s\n' "$C_RED" "$stage" "$C_RESET" >&2
        local item
        for item in "${FAILED[@]}"; do
            printf '%s  - %s%s\n' "$C_RED" "$item" "$C_RESET" >&2
        done
        printf '%s%s failed. Fix the items above and re-run.%s\n' "$C_RED" "$stage" "$C_RESET" >&2
        exit 1
    fi
}

Read-Default() {
    local prompt=$1
    local default=${2-}
    local answer=''

    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ -z "$default" ]]; then
            printf '%sPrompt required in --non-interactive mode: %s%s\n' "$C_RED" "$prompt" "$C_RESET" >&2
            exit 1
        fi
        printf '%s' "$default"
        return
    fi

    printf '%s [%s] ' "$prompt" "$default" >&2
    IFS= read -r answer
    if [[ -z "${answer//[[:space:]]/}" ]]; then
        printf '%s' "$default"
    else
        answer=${answer#"${answer%%[![:space:]]*}"}
        answer=${answer%"${answer##*[![:space:]]}"}
        printf '%s' "$answer"
    fi
}

# Numbered menu. Returns the selected object.
Select-Item() {
    local items_json=$1
    local label_filter=$2
    local what=$3
    local count
    count=$(jq 'length' <<<"$items_json")

    if ((count == 0)); then
        printf 'null'
        return
    fi
    if ((count == 1)); then
        jq -c '.[0]' <<<"$items_json"
        return
    fi
    if [[ "$NON_INTERACTIVE" == true ]]; then
        printf "%sMultiple %s found and --non-interactive was supplied. Pass the value explicitly.%s\n" "$C_RED" "$what" "$C_RESET" >&2
        exit 1
    fi

    printf '\n%s  Multiple %s found:%s\n' "$C_YELLOW" "$what" "$C_RESET" >&2
    local i label sel
    for ((i = 0; i < count; i++)); do
        label=$(jq -r ".[$i] | $label_filter" <<<"$items_json")
        printf '    [%d] %s\n' "$((i + 1))" "$label" >&2
    done
    while true; do
        printf '  Select 1-%d ' "$count" >&2
        IFS= read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= count)); then
            jq -c ".[$((sel - 1))]" <<<"$items_json"
            return
        fi
    done
}

usage() {
    cat <<'EOF'
Usage: scripts/00-configure.sh [options]

One-stop prerequisite check, cloud sign-in, interconnect discovery/selection,
capacity validation, and terraform/terraform.tfvars generation for the
Azure <-> AWS Multicloud Interconnect lab.

Options:
  --interconnect-mode existing|create
      Where the interconnect comes from. existing attaches to a circuit and
      AWS interconnect you already own. create lets Terraform build the pair.
  --subscription-id ID
      Azure subscription to use. If omitted interactively, you choose from
      enabled subscriptions; in --non-interactive mode the current subscription
      is used.
  --aws-profile NAME
      AWS CLI profile to use. Defaults to the resource prefix if prompted.
  --aws-region REGION
      AWS region for the lab resources. Default: us-east-1.
  --prefix PREFIX
      Resource name prefix. Must be 3-12 lowercase letters/digits, starting
      with a letter. Default: mcilab.
  --vm-location REGION
      Azure region for the spoke VNet and Linux VM. Default: eastus2.
  --vm-size SIZE
      Azure Linux VM size to validate. Default: Standard_B1s.
  --circuit-name NAME
      Existing Azure ExpressRoute / Multicloud Interconnect circuit name.
      Use with --circuit-rg.
  --circuit-rg RESOURCE_GROUP
      Resource group containing --circuit-name.
  --interconnect-name ID
      Existing AWS Interconnect connection ID to use in existing mode.
  --peering-location LOCATION
      Interconnect peering location used only with --interconnect-mode create.
      Default: useast.
  --demo-mode
      Build landing zones but leave the two clouds unjoined.
  --non-interactive
      Never prompt. Fail when an answer cannot be derived safely.
  --force
      Skip overwrite/account safety prompts. In --non-interactive create mode,
      also serves as the explicit billing confirmation.
  -h, --help
      Show this help.

Examples:
  scripts/00-configure.sh
  scripts/00-configure.sh --subscription-id 00000000-0000-0000-0000-000000000000 \
      --aws-profile mcilab --prefix mcilab --non-interactive
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --interconnect-mode)
                INTERCONNECT_MODE=${2-}; shift 2 ;;
            --interconnect-mode=*)
                INTERCONNECT_MODE=${1#*=}; shift ;;
            --subscription-id)
                SUBSCRIPTION_ID=${2-}; shift 2 ;;
            --subscription-id=*)
                SUBSCRIPTION_ID=${1#*=}; shift ;;
            --aws-profile)
                AWS_PROFILE=${2-}; shift 2 ;;
            --aws-profile=*)
                AWS_PROFILE=${1#*=}; shift ;;
            --aws-region)
                AWS_REGION=${2-}; shift 2 ;;
            --aws-region=*)
                AWS_REGION=${1#*=}; shift ;;
            --prefix)
                PREFIX=${2-}; shift 2 ;;
            --prefix=*)
                PREFIX=${1#*=}; shift ;;
            --vm-location)
                VM_LOCATION=${2-}; shift 2 ;;
            --vm-location=*)
                VM_LOCATION=${1#*=}; shift ;;
            --vm-size)
                VM_SIZE=${2-}; shift 2 ;;
            --vm-size=*)
                VM_SIZE=${1#*=}; shift ;;
            --circuit-name)
                CIRCUIT_NAME=${2-}; shift 2 ;;
            --circuit-name=*)
                CIRCUIT_NAME=${1#*=}; shift ;;
            --circuit-rg)
                CIRCUIT_RG=${2-}; shift 2 ;;
            --circuit-rg=*)
                CIRCUIT_RG=${1#*=}; shift ;;
            --interconnect-name)
                INTERCONNECT_NAME=${2-}; shift 2 ;;
            --interconnect-name=*)
                INTERCONNECT_NAME=${1#*=}; shift ;;
            --peering-location)
                PEERING_LOCATION_CHOICE=${2-}; shift 2 ;;
            --peering-location=*)
                PEERING_LOCATION_CHOICE=${1#*=}; shift ;;
            --demo-mode)
                DEMO_MODE=true; shift ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            --force)
                FORCE=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                printf 'Unknown option: %s\n\n' "$1" >&2
                usage >&2
                exit 2 ;;
        esac
    done
}

version_lt() {
    local left=$1
    local right=$2
    local IFS=.
    local -a l r
    read -r -a l <<<"${left%%[-+]*}"
    read -r -a r <<<"${right%%[-+]*}"
    local i lv rv
    for ((i = 0; i < 3; i++)); do
        lv=${l[i]:-0}
        rv=${r[i]:-0}
        lv=${lv//[^0-9]/}
        rv=${rv//[^0-9]/}
        lv=${lv:-0}
        rv=${rv:-0}
        if ((10#$lv < 10#$rv)); then return 0; fi
        if ((10#$lv > 10#$rv)); then return 1; fi
    done
    return 1
}

Test-Tool() {
    local name=$1
    local hint=$2
    local minimum=${3-}
    local version_cmd=${4-}
    local v=''

    if ! command -v "$name" >/dev/null 2>&1; then
        Write-Bad "$name not found  ->  $hint"
        return
    fi
    if [[ -n "$version_cmd" ]]; then
        if v=$(eval "$version_cmd" 2>/dev/null); then
            if [[ -n "$v" && -n "$minimum" ]] && version_lt "$v" "$minimum"; then
                Write-Bad "$name $v is older than the required $minimum  ->  $hint"
                return
            fi
            if [[ -n "$v" ]]; then
                Write-Ok "$name $v"
            else
                Write-Ok "$name (version undetermined)"
            fi
            return
        fi
        Write-Ok "$name (version undetermined)"
        return
    fi
    Write-Ok "$name"
}

json_truthy() {
    jq -e 'if type == "array" then length > 0 else . != null end' >/dev/null 2>&1 <<<"${1:-null}"
}

parse_args "$@"

##############################################################################
# 1. Tooling
##############################################################################

Write-Step 'Tooling'

if ((BASH_VERSINFO[0] < 4)); then
    Write-Bad "bash ${BASH_VERSION} is older than the required 4.0.0"
fi

# The AWS MSI installs here but the current shell may predate the PATH update.
if [[ -d '/c/Program Files/Amazon/AWSCLIV2' && ":$PATH:" != *":/c/Program Files/Amazon/AWSCLIV2:"* ]]; then
    export PATH="/c/Program Files/Amazon/AWSCLIV2:$PATH"
    Write-Info 'added C:\Program Files\Amazon\AWSCLIV2 to PATH for this session'
fi

Test-Tool 'terraform' 'winget install --id Hashicorp.Terraform' '1.5.0' \
    'terraform version -json | jq -r ".terraform_version // empty"'
Test-Tool 'az' 'winget install --id Microsoft.AzureCLI' '2.50.0' \
    'az version -o json | jq -r ".[\"azure-cli\"] // empty"'
Test-Tool 'aws' 'winget install --id Amazon.AWSCLI' '2.0.0' \
    'aws --version 2>&1 | sed -n "s/.*aws-cli\/\([0-9][0-9.]*\).*/\1/p"'
Test-Tool 'jq' 'winget install --id jqlang.jq' '1.6.0' \
    'jq --version | sed -n "s/^jq-\([0-9][0-9.]*\).*/\1/p"'

if command -v ssh >/dev/null 2>&1; then
    Write-Ok 'ssh'
else
    Write-Warn 'ssh not found - you will not be able to log in to the VMs to test the path'
fi

Assert-Clean 'Tooling'

##############################################################################
# 2. Azure identity and subscription selection
##############################################################################

Write-Step 'Azure sign-in'

acct_json=$(az account show -o json 2>/dev/null || true)
if ! json_truthy "$acct_json"; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        printf '%sNot signed in to Azure and --non-interactive was supplied. Run: az login%s\n' "$C_RED" "$C_RESET" >&2
        exit 1
    fi
    Write-Warn 'not signed in - launching az login'
    az login --only-show-errors >/dev/null
    acct_json=$(az account show -o json 2>/dev/null || true)
fi
if ! json_truthy "$acct_json"; then
    printf '%saz login did not produce a usable session.%s\n' "$C_RED" "$C_RESET" >&2
    exit 1
fi
acct_user=$(jq -r '.user.name // ""' <<<"$acct_json")
Write-Ok "signed in as $acct_user"

# Actively select the subscription rather than trusting whatever was current.
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    subs_json=$(az account list --all -o json | jq '[.[] | select(.state == "Enabled")]')
    subs_count=$(jq 'length' <<<"$subs_json")
    if ((subs_count == 0)); then
        Write-Bad 'no enabled subscriptions on this account'
        Assert-Clean 'Azure'
    fi

    printf '\n%s  Subscriptions available:%s\n' "$C_CYAN" "$C_RESET" >&2
    current_sub=$(jq -r '.id' <<<"$acct_json")
    default_selection=1
    for ((i = 0; i < subs_count; i++)); do
        sub_id=$(jq -r ".[$i].id" <<<"$subs_json")
        sub_name=$(jq -r ".[$i].name" <<<"$subs_json")
        marker=' '
        if [[ "$sub_id" == "$current_sub" ]]; then
            marker='*'
            default_selection=$((i + 1))
        fi
        printf '    [%d]%s %s  (%s)\n' "$((i + 1))" "$marker" "$sub_name" "$sub_id" >&2
    done
    Write-Info '* = currently selected'

    if [[ "$NON_INTERACTIVE" == true ]]; then
        SUBSCRIPTION_ID=$current_sub
    else
        sel=$(Read-Default "  Select subscription 1-$subs_count" "$default_selection")
        if [[ ! "$sel" =~ ^[0-9]+$ ]] || ((sel < 1 || sel > subs_count)); then
            printf "%sInvalid selection '%s'.%s\n" "$C_RED" "$sel" "$C_RESET" >&2
            exit 1
        fi
        SUBSCRIPTION_ID=$(jq -r ".[$((sel - 1))].id" <<<"$subs_json")
    fi
fi

az account set --subscription "$SUBSCRIPTION_ID"
acct_json=$(az account show -o json)
selected_sub=$(jq -r '.id' <<<"$acct_json")
if [[ "$selected_sub" != "$SUBSCRIPTION_ID" ]]; then
    Write-Bad "failed to select subscription $SUBSCRIPTION_ID"
fi
Assert-Clean 'Azure'

TENANT_ID=$(jq -r '.tenantId' <<<"$acct_json")
acct_name=$(jq -r '.name' <<<"$acct_json")
Write-Ok "using $acct_name / $selected_sub"
Write-Info "tenant $TENANT_ID"

##############################################################################
# 3. AWS identity
##############################################################################

Write-Step 'AWS sign-in'

if [[ -z "$AWS_PROFILE" ]]; then
    mapfile -t profiles < <(aws configure list-profiles 2>/dev/null || true)
    if ((${#profiles[@]} > 0)); then
        printf '\n%s  AWS profiles configured:%s\n' "$C_CYAN" "$C_RESET" >&2
        for profile in "${profiles[@]}"; do
            printf '    - %s\n' "$profile" >&2
        done
    fi
    AWS_PROFILE=$(Read-Default '  AWS profile to use' "$PREFIX")
fi

identity_json=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --output json 2>/dev/null || true)

if ! json_truthy "$identity_json"; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        printf "%sAWS profile '%s' is not usable and --non-interactive was supplied.%s\n" "$C_RED" "$AWS_PROFILE" "$C_RESET" >&2
        exit 1
    fi

    mapfile -t profiles < <(aws configure list-profiles 2>/dev/null || true)
    exists=false
    for profile in "${profiles[@]}"; do
        if [[ "$profile" == "$AWS_PROFILE" ]]; then
            exists=true
            break
        fi
    done

    if [[ "$exists" != true ]]; then
        Write-Warn "profile '$AWS_PROFILE' does not exist"
        printf '%s    [1] AWS IAM Identity Center / SSO  (recommended)%s\n' "$C_CYAN" "$C_RESET" >&2
        printf '%s    [2] Static access keys%s\n' "$C_CYAN" "$C_RESET" >&2
        mode=$(Read-Default '  How do you sign in to AWS' '1')
        if [[ "$mode" == '2' ]]; then
            aws configure --profile "$AWS_PROFILE"
        else
            aws configure sso --profile "$AWS_PROFILE"
        fi
    else
        Write-Warn "profile '$AWS_PROFILE' exists but has no valid session"
    fi

    # An SSO profile needs a login; a static-credential profile will no-op here.
    is_sso=$(aws configure get sso_start_url --profile "$AWS_PROFILE" 2>/dev/null || true)
    if [[ -n "$is_sso" ]]; then
        aws sso login --profile "$AWS_PROFILE"
    fi

    identity_json=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --output json 2>/dev/null || true)
fi

if ! json_truthy "$identity_json"; then
    Write-Bad "AWS profile '$AWS_PROFILE' still cannot call sts:GetCallerIdentity"
    Assert-Clean 'AWS'
fi

AWS_ACCOUNT_ID=$(jq -r '.Account' <<<"$identity_json")
identity_arn=$(jq -r '.Arn' <<<"$identity_json")
Write-Ok "account $AWS_ACCOUNT_ID"
Write-Info "$identity_arn"

if [[ "$NON_INTERACTIVE" != true && "$FORCE" != true ]]; then
    confirm=$(Read-Default "  Deploy the AWS side into account $AWS_ACCOUNT_ID? (y/n)" 'y')
    if [[ ! "$confirm" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        printf '%sAborted at AWS account confirmation.%s\n' "$C_RED" "$C_RESET" >&2
        exit 1
    fi
fi

##############################################################################
# 4. The interconnect - Azure side
#
# Two supported shapes, and the script picks between them from what it actually
# finds rather than assuming:
#   existing - attach to a circuit you already own (default, nothing billed)
#   create   - build the Azure circuit here, then pair AWS to it in stage 7
##############################################################################

Write-Step 'Azure Multicloud Interconnect circuit'

if [[ -n "$CIRCUIT_NAME" && -n "$CIRCUIT_RG" ]]; then
    circuit_one=$(az network express-route show --name "$CIRCUIT_NAME" --resource-group "$CIRCUIT_RG" -o json)
    circuits_json=$(jq -n --argjson circuit "$circuit_one" '[$circuit]')
else
    all_circuits_json=$(az network express-route list -o json)
    circuits_json=$(jq '[.[] | select(.sku.tier == "MultiCloud")]' <<<"$all_circuits_json")
    circuits_count=$(jq 'length' <<<"$circuits_json")
    all_count=$(jq 'length' <<<"$all_circuits_json")
    if ((circuits_count == 0 && all_count > 0)); then
        Write-Warn 'no MultiCloud-tier circuit found; falling back to all ExpressRoute circuits'
        circuits_json=$all_circuits_json
    fi
fi
circuits_count=$(jq 'length' <<<"$circuits_json")

# Decide the mode before touching anything else.
if [[ -z "$INTERCONNECT_MODE" ]]; then
    if ((circuits_count > 0)); then
        Write-Ok "found $circuits_count candidate circuit(s) in this subscription"
        Write-Info 'Choose "existing" to attach to one of them, or "create" to build a new pair.'
        if [[ "$NON_INTERACTIVE" == true ]]; then
            INTERCONNECT_MODE='existing'
        else
            ans=$(Read-Default '  Interconnect mode (existing/create)' 'existing')
            INTERCONNECT_MODE=$(tr '[:upper:]' '[:lower:]' <<<"$ans")
            INTERCONNECT_MODE=${INTERCONNECT_MODE//[[:space:]]/}
        fi
    else
        Write-Warn 'no ExpressRoute / Multicloud Interconnect circuit found in this subscription'
        if [[ "$NON_INTERACTIVE" == true ]]; then
            Write-Bad 'nothing to attach to, and --interconnect-mode was not specified'
            Assert-Clean 'Interconnect discovery'
        fi
        Write-Info 'Terraform can create the circuit and its AWS counterpart for you.'
        ans=$(Read-Default '  Create a new interconnect pair? (y/n)' 'y')
        if [[ "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]; then
            INTERCONNECT_MODE='create'
        else
            INTERCONNECT_MODE='existing'
        fi
    fi
else
    INTERCONNECT_MODE=$(tr '[:upper:]' '[:lower:]' <<<"$INTERCONNECT_MODE")
    INTERCONNECT_MODE=${INTERCONNECT_MODE//[[:space:]]/}
fi

if [[ "$INTERCONNECT_MODE" != 'existing' && "$INTERCONNECT_MODE" != 'create' ]]; then
    printf "%sInterconnectMode must be 'existing' or 'create', got '%s'.%s\n" "$C_RED" "$INTERCONNECT_MODE" "$C_RESET" >&2
    exit 1
fi

CIRCUIT_ID=''
circuit_json=''
PEERING_LOCATION=''

if [[ "$INTERCONNECT_MODE" == 'create' ]]; then
    ##########################################################################
    # create: nothing to discover on Azure yet, but the operator must opt in
    # to the AWS charge with their eyes open.
    ##########################################################################
    Write-Warn 'interconnect_mode = "create": Terraform will build a NEW interconnect pair.'
    Write-Info 'Azure Multicloud Interconnect carries no Azure service or egress charge in preview,'
    Write-Info 'but the AWS Interconnect connection is BILLED PER PORT-HOUR at 1 Gbps.'
    Write-Info 'Destroying the lab removes both sides again.'

    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ "$FORCE" != true ]]; then
            Write-Bad 'interconnect_mode = "create" provisions a billed AWS interconnect; re-run with --force to confirm in --non-interactive mode'
            Assert-Clean 'Interconnect discovery'
        fi
        Write-Info '--force supplied; proceeding with billed AWS interconnect creation'
    else
        confirm=$(Read-Default '  Understood - provision a billed AWS interconnect? (y/n)' 'n')
        if [[ ! "$confirm" =~ ^([yY]|[yY][eE][sS])$ ]]; then
            printf '%sAborted - re-run and choose "existing" to attach to a circuit you already own.%s\n' "$C_RED" "$C_RESET" >&2
            exit 1
        fi
    fi

    PEERING_LOCATION=$(Read-Default '  Interconnect peering location' "$PEERING_LOCATION_CHOICE")
    Write-Ok "will create a MultiCloud circuit at peering location '$PEERING_LOCATION'"
else
    ##########################################################################
    # existing: attach to what is already there
    ##########################################################################
    if ((circuits_count == 0)); then
        Write-Bad 'no ExpressRoute / Multicloud Interconnect circuit found in this subscription'
        Write-Info 'Re-run with --interconnect-mode create to have Terraform build one.'
        Assert-Clean 'Interconnect discovery'
    fi

    circuit_json=$(Select-Item "$circuits_json" \
        '"\(.name)  (rg \(.id | split("/")[4]), tier \(.sku.tier), \(.serviceProviderProperties.peeringLocation))"' \
        'circuits')

    CIRCUIT_ID=$(jq -r '.id' <<<"$circuit_json")
    PEERING_LOCATION=$(jq -r '.serviceProviderProperties.peeringLocation // ""' <<<"$circuit_json")
    circuit_name=$(jq -r '.name' <<<"$circuit_json")
    circuit_tier=$(jq -r '.sku.tier' <<<"$circuit_json")
    circuit_state=$(jq -r '.serviceProviderProvisioningState // ""' <<<"$circuit_json")
    Write-Ok "$circuit_name  tier=$circuit_tier  peeringLocation=$PEERING_LOCATION"
    Write-Info "$CIRCUIT_ID"

    if [[ "$circuit_state" != 'Provisioned' ]]; then
        Write-Bad "circuit is '$circuit_state', expected 'Provisioned'"
    fi

    # Multicloud Interconnect preview allows exactly ONE gateway connection.
    existing_json=$(jq '[.peerings[]? | .connections[]?]' <<<"$circuit_json")
    existing_count=$(jq 'length' <<<"$existing_json")
    if ((existing_count > 0)); then
        Write-Bad "circuit already has $existing_count gateway connection(s); the limit is 1"
        for ((i = 0; i < existing_count; i++)); do
            existing_name=$(jq -r ".[$i].name // empty" <<<"$existing_json")
            Write-Info "existing: $existing_name"
        done
    else
        Write-Ok 'the single allowed gateway-connection slot is free'
    fi
fi

##############################################################################
# 5. Hub region - forced by the circuit, not a free choice
##############################################################################

Write-Step 'Hub region'

# A MultiCloud-tier circuit behaves as a LOCAL circuit: it can only be connected
# to the one Azure region designated for its peering location.
declare -A PEERING_TO_REGION=(
    [useast]='eastus'
    [useast2]='eastus2'
    [uswest]='westus'
    [uswest2]='westus2'
    [uswest3]='westus3'
    [ussouthcentral]='southcentralus'
    [usnorthcentral]='northcentralus'
    [europewest]='westeurope'
    [europenorth]='northeurope'
    [uksouth]='uksouth'
    [asiasoutheast]='southeastasia'
    [asiaeast]='eastasia'
    [australiaeast]='australiaeast'
    [japaneast]='japaneast'
    [canadacentral]='canadacentral'
    [indiacentral]='centralindia'
)

key=$(tr '[:upper:]' '[:lower:]' <<<"$PEERING_LOCATION")
key=${key// /}
if [[ -n "${PEERING_TO_REGION[$key]+set}" ]]; then
    HUB_LOCATION=${PEERING_TO_REGION[$key]}
    Write-Ok "peering location '$PEERING_LOCATION' maps to Azure region '$HUB_LOCATION'"
else
    Write-Warn "peering location '$PEERING_LOCATION' is not in the known map"
    if [[ "$NON_INTERACTIVE" == true ]]; then
        Write-Bad "cannot derive the Azure region for peering location '$PEERING_LOCATION' in --non-interactive mode"
        Assert-Clean 'Hub region'
    fi
    HUB_LOCATION=$(Read-Default '  Azure region for the ExpressRoute gateway' 'eastus')
fi
Write-Info 'The gateway MUST be in this region. A Local circuit refuses connections from anywhere else.'

##############################################################################
# 6. VM region capacity - the other thing that silently breaks applies
##############################################################################

Write-Step 'VM region capacity'

VM_LOCATION=$(Read-Default '  Azure region for the spoke VNet and Linux VM' "$VM_LOCATION")

skus_json=$(az vm list-skus --location "$VM_LOCATION" --size "$VM_SIZE" --output json 2>/dev/null || true)
sku_json=$(jq -c --arg size "$VM_SIZE" '[.[] | select(.name == $size)][0] // null' <<<"${skus_json:-[]}")

if [[ "$sku_json" == 'null' ]]; then
    Write-Warn "could not read SKU data for $VM_SIZE in $VM_LOCATION - continuing, but apply may fail"
else
    location_blocked=$(jq -r 'any(.restrictions[]?; .type == "Location")' <<<"$sku_json")
    zone_blocked=$(jq -r 'any(.restrictions[]?; .type == "Zone")' <<<"$sku_json")
    if [[ "$location_blocked" == true ]]; then
        Write-Bad "$VM_SIZE is NotAvailableForSubscription in $VM_LOCATION (Location-scope restriction)"
        Write-Info 'Pick another region. This is a subscription-level block, not a capacity blip.'
    elif [[ "$zone_blocked" == true ]]; then
        Write-Ok "$VM_SIZE available in $VM_LOCATION (zone-restricted only, which does not affect this non-zonal VM)"
    else
        Write-Ok "$VM_SIZE available in $VM_LOCATION with no restrictions"
    fi
fi

Assert-Clean 'Azure validation'

##############################################################################
# 7. The interconnect - AWS side
##############################################################################

Write-Step 'AWS Interconnect - multicloud'

DX_GATEWAY_ID=''

if [[ "$INTERCONNECT_MODE" == 'create' ]]; then
    # Nothing to discover: Terraform creates the Direct Connect Gateway and
    # then redeems the Azure activation key against it.
    Write-Ok 'skipped - Terraform will create the DXGW and the AWS interconnect connection'
    Write-Info 'Azure mints an activation key for the new circuit; awscc redeems it to pair the clouds.'
else
    ic_json=$(aws interconnect list-connections --profile "$AWS_PROFILE" --output json 2>/dev/null || true)
    if [[ -n "$ic_json" ]] && jq -e . >/dev/null 2>&1 <<<"$ic_json"; then
        connections_json=$(jq '.connections // []' <<<"$ic_json")
        if [[ -n "$INTERCONNECT_NAME" ]]; then
            connections_json=$(jq --arg name "$INTERCONNECT_NAME" '[.[] | select(.id == $name)]' <<<"$connections_json")
        fi
        connections_count=$(jq 'length' <<<"$connections_json")
        if ((connections_count > 0)); then
            interconnect_json=$(Select-Item "$connections_json" \
                '"\(.id)  (\(.description), \(.state), \(.bandwidth))"' \
                'interconnects')
            ic_id=$(jq -r '.id' <<<"$interconnect_json")
            ic_state=$(jq -r '.state // ""' <<<"$interconnect_json")
            ic_bandwidth=$(jq -r '.bandwidth // ""' <<<"$interconnect_json")
            ic_location=$(jq -r '.location // ""' <<<"$interconnect_json")
            Write-Ok "$ic_id  state=$ic_state  $ic_bandwidth @ $ic_location"
            if [[ "$ic_state" != 'available' ]]; then
                Write-Bad "interconnect state is '$ic_state', expected 'available'"
            fi

            # On AWS the attach point is ALWAYS a Direct Connect Gateway, and the
            # API reports it directly - no guessing.
            DX_GATEWAY_ID=$(jq -r '.attachPoint.directConnectGateway // empty' <<<"$interconnect_json")
            if [[ -n "$DX_GATEWAY_ID" ]]; then
                Write-Ok "attach point: Direct Connect Gateway $DX_GATEWAY_ID"
            fi
        else
            Write-Warn 'no matching interconnect returned - falling back to Direct Connect Gateway discovery'
        fi
    else
        Write-Warn "'aws interconnect list-connections' unavailable - falling back to Direct Connect Gateway discovery"
    fi

    if [[ -z "$DX_GATEWAY_ID" ]]; then
        dxgws_json=$(aws directconnect describe-direct-connect-gateways --profile "$AWS_PROFILE" --output json |
            jq '.directConnectGateways // []')
        dxgws_count=$(jq 'length' <<<"$dxgws_json")
        if ((dxgws_count == 0)); then
            Write-Bad 'no Direct Connect Gateway found - the interconnect attach point is always a DXGW'
        else
            dxgw_json=$(Select-Item "$dxgws_json" \
                '"\(.directConnectGatewayName)  id=\(.directConnectGatewayId)  asn=\(.amazonSideAsn)  state=\(.directConnectGatewayState)"' \
                'Direct Connect Gateways')
            DX_GATEWAY_ID=$(jq -r '.directConnectGatewayId' <<<"$dxgw_json")
            dxgw_asn=$(jq -r '.amazonSideAsn' <<<"$dxgw_json")
            Write-Ok "using Direct Connect Gateway $DX_GATEWAY_ID (ASN $dxgw_asn)"
        fi
    fi

    if [[ -n "$DX_GATEWAY_ID" ]]; then
        assocs_json=$(aws directconnect describe-direct-connect-gateway-associations \
            --direct-connect-gateway-id "$DX_GATEWAY_ID" --profile "$AWS_PROFILE" --output json |
            jq '.directConnectGatewayAssociations // []')
        vgw_assocs_json=$(jq '[.[] | select(.associationState == "associated" or .associationState == "associating")]' <<<"$assocs_json")
        vgw_assocs_count=$(jq 'length' <<<"$vgw_assocs_json")
        if ((vgw_assocs_count > 0)); then
            Write-Warn "DXGW already has $vgw_assocs_count association(s):"
            for ((i = 0; i < vgw_assocs_count; i++)); do
                assoc_state=$(jq -r ".[$i].associationState" <<<"$vgw_assocs_json")
                assoc_id=$(jq -r ".[$i].associatedGateway.id" <<<"$vgw_assocs_json")
                assoc_type=$(jq -r ".[$i].associatedGateway.type" <<<"$vgw_assocs_json")
                Write-Info "$assoc_state -> $assoc_id ($assoc_type)"
            done
            Write-Info 'A pre-existing association is fine unless it is a leftover from this lab.'
        else
            Write-Ok 'no conflicting DXGW association'
        fi
    fi
fi

Assert-Clean 'AWS validation'

##############################################################################
# 8. Access
##############################################################################

Write-Step 'Access'

MY_IP=''
if MY_IP=$(curl -fsS --max-time 15 'https://ifconfig.me/ip' 2>/dev/null); then
    MY_IP=${MY_IP//$'\r'/}
    MY_IP=${MY_IP//$'\n'/}
    MY_IP=${MY_IP#"${MY_IP%%[![:space:]]*}"}
    MY_IP=${MY_IP%"${MY_IP##*[![:space:]]}"}
    if [[ -n "$MY_IP" ]]; then
        Write-Ok "your public IP is $MY_IP - $MY_IP/32 will be allow-listed for SSH"
    fi
fi
if [[ -z "$MY_IP" ]]; then
    Write-Warn 'could not auto-detect your public IP; Terraform will retry at apply time'
fi

##############################################################################
# 9. Write terraform.tfvars
##############################################################################

Write-Step 'Writing configuration'

PREFIX=$(Read-Default '  Resource name prefix' "$PREFIX")
if [[ ! "$PREFIX" =~ ^[a-z][a-z0-9]{2,11}$ ]]; then
    printf "%sPrefix '%s' must be 3-12 chars, lowercase letters and digits, starting with a letter.%s\n" "$C_RED" "$PREFIX" "$C_RESET" >&2
    exit 1
fi

if [[ "$DEMO_MODE" == true ]]; then
    CREATE_INTERCONNECT='false'
else
    CREATE_INTERCONNECT='true'
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TFVARS_PATH="$REPO_ROOT/terraform/terraform.tfvars"

if [[ -e "$TFVARS_PATH" && "$FORCE" != true && "$NON_INTERACTIVE" != true ]]; then
    overwrite=$(Read-Default "  $TFVARS_PATH exists. Overwrite? (y/n)" 'y')
    if [[ ! "$overwrite" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        printf '%sAborted - existing terraform.tfvars left untouched.%s\n' "$C_RED" "$C_RESET" >&2
        exit 1
    fi
fi

generated_at=$(date '+%Y-%m-%d %H:%M:%S')
{
    printf '# Generated by scripts/00-configure.sh on %s.\n' "$generated_at"
    printf '# This file holds YOUR identifiers and is gitignored. Do not commit it.\n'
    printf '\n'
    printf '# --- Identity -------------------------------------------------------------\n'
    printf 'azure_subscription_id = "%s"\n' "$SUBSCRIPTION_ID"
    printf 'azure_tenant_id       = "%s"\n' "$TENANT_ID"
    printf 'aws_account_id        = "%s"\n' "$AWS_ACCOUNT_ID"
    printf 'aws_profile           = "%s"\n' "$AWS_PROFILE"
    printf 'aws_region            = "%s"\n' "$AWS_REGION"
    printf '\n'
    printf '# --- Interconnect ---------------------------------------------------------\n'
    printf 'interconnect_mode = "%s"\n' "$INTERCONNECT_MODE"

    if [[ "$INTERCONNECT_MODE" == 'create' ]]; then
        printf '# Terraform creates BOTH sides of the pair and destroys them on teardown.\n'
        printf '# The AWS interconnect connection is billed per port-hour.\n'
        printf 'interconnect_peering_location = "%s"\n' "$PEERING_LOCATION"
    else
        printf '# Brought by you; never created or destroyed by this lab.\n'
        printf 'express_route_circuit_id = "%s"\n' "$CIRCUIT_ID"
        printf 'dx_gateway_id            = "%s"\n' "$DX_GATEWAY_ID"
    fi

    printf '\n'
    printf '# --- Placement ------------------------------------------------------------\n'
    printf "# Hub is forced by the circuit peering location '%s'.\n" "$PEERING_LOCATION"
    printf 'azure_hub_location = "%s"\n' "$HUB_LOCATION"
    printf 'azure_location     = "%s"\n' "$VM_LOCATION"
    printf '\n'
    printf '# --- Naming ---------------------------------------------------------------\n'
    printf 'prefix = "%s"\n' "$PREFIX"
    printf '\n'
    printf '# --- Lab mode -------------------------------------------------------------\n'
    printf '# false = build both landing zones but leave the clouds unjoined (demo mode).\n'
    printf 'create_interconnect = %s\n' "$CREATE_INTERCONNECT"
    if [[ -n "$MY_IP" ]]; then
        printf '\n'
        printf '# --- Access ---------------------------------------------------------------\n'
        printf 'my_public_ip = "%s/32"\n' "$MY_IP"
    fi
} >"$TFVARS_PATH"
Write-Ok "wrote $TFVARS_PATH"

##############################################################################
# Summary
##############################################################################

printf '\n%s=== Ready ===%s\n' "$C_CYAN" "$C_RESET"
printf '  Azure subscription : %s (%s)\n' "$acct_name" "$SUBSCRIPTION_ID"
printf "  AWS account        : %s via profile '%s'\n" "$AWS_ACCOUNT_ID" "$AWS_PROFILE"
printf '  Interconnect       : %s\n' "$INTERCONNECT_MODE"
if [[ "$INTERCONNECT_MODE" == 'create' ]]; then
    printf '%s  Circuit            : will be CREATED at peering location %s%s\n' "$C_YELLOW" "$PEERING_LOCATION" "$C_RESET"
    printf '%s  DXGW               : will be CREATED%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s  Billing            : AWS interconnect port is chargeable%s\n' "$C_YELLOW" "$C_RESET"
else
    printf '  Circuit            : %s\n' "$circuit_name"
    printf '  DXGW               : %s\n' "$DX_GATEWAY_ID"
fi
printf '  Gateway region     : %s  (forced by peering location)\n' "$HUB_LOCATION"
printf '  VM region          : %s\n' "$VM_LOCATION"
printf '  Prefix             : %s\n' "$PREFIX"
if [[ "$DEMO_MODE" == true ]]; then
    printf '%s  Mode               : DEMO - clouds will NOT be joined%s\n' "$C_YELLOW" "$C_RESET"
fi

printf '\n%sNext:%s\n' "$C_CYAN" "$C_RESET"
printf '  cd terraform\n'
printf '  terraform init\n'
printf '  terraform apply\n'
printf '\n'

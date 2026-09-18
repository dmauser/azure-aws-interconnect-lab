#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Tears down the lab and confirms the expensive resource is actually gone.
#
# The ExpressRoute virtual network gateway is most of this lab's running cost,
# so this script verifies its deletion rather than trusting a clean
# `terraform destroy` exit code.
#
# The Multicloud circuit and the AWS Interconnect connection are only managed by
# this repo when interconnect_mode = "create". In that mode Terraform destroys
# both, and this script verifies the billable AWS port is really gone. With the
# default "existing" mode both are left intact.
##############################################################################

AWS_PROFILE=''
AZURE_SUBSCRIPTION=''
FORCE=false

FAILED=()

##############################################################################
# Output helpers
##############################################################################

if [[ -t 2 ]]; then
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_RESET=$'\033[0m'
else
    C_CYAN=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_RESET=''
fi

Write-Step() { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$1" "$C_RESET" >&2; }
Write-Ok()   { printf '%s  [ok]   %s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
Write-Warn() { printf '%s  [warn] %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
Write-Bad()  {
    printf '%s  [FAIL] %s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}
Add-Failure() { FAILED+=("$1"); }

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

usage() {
    cat <<'EOF'
Usage: scripts/99-destroy.sh [options]

Tears down the lab and confirms the ExpressRoute gateway and AWS virtual
private gateway are actually gone.

Options:
  --aws-profile NAME
      AWS CLI profile to use. Defaults to the Terraform aws_profile output.
  --azure-subscription ID
      Azure subscription to query. Defaults to the Terraform
      azure_subscription_id output.
  --force
      Skip the DESTROY confirmation prompt.
  -h, --help
      Show this help.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --aws-profile|-AwsProfile)
                AWS_PROFILE=${2-}; shift 2 ;;
            --aws-profile=*)
                AWS_PROFILE=${1#*=}; shift ;;
            --azure-subscription|-AzureSubscription)
                AZURE_SUBSCRIPTION=${2-}; shift 2 ;;
            --azure-subscription=*)
                AZURE_SUBSCRIPTION=${1#*=}; shift ;;
            --force|-Force)
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

Require-Tool() {
    local name=$1
    local hint=$2

    if ! command -v "$name" >/dev/null 2>&1; then
        Write-Bad "$name not found  ->  $hint"
        Add-Failure "$name not found  ->  $hint"
    fi
}

Read-Required() {
    local prompt=$1
    local answer=''

    printf '%s: ' "$prompt" >&2
    IFS= read -r answer
    printf '%s' "$answer"
}

parse_args "$@"

# The AWS MSI installs here but the current shell may predate the PATH update.
if [[ -d '/c/Program Files/Amazon/AWSCLIV2' && ":$PATH:" != *":/c/Program Files/Amazon/AWSCLIV2:"* ]]; then
    export PATH="/c/Program Files/Amazon/AWSCLIV2:$PATH"
fi

Require-Tool 'jq' 'install jq 1.6 or newer'
Require-Tool 'az' 'install Azure CLI'
Require-Tool 'aws' 'install AWS CLI v2'
Require-Tool 'terraform' 'install Terraform 1.5 or newer'
Require-Tool 'ssh' 'install OpenSSH client'
Assert-Clean 'Tooling'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
TF_DIR="$REPO_ROOT/terraform"

# Read everything needed for the post-destroy checks BEFORE destroying, because
# `terraform output` returns nothing once the state has been emptied.
tf_json=$(cd "$TF_DIR" && terraform output -json 2>/dev/null || true)

if [[ -n "$tf_json" ]] && jq -e 'has("resource_names") and (.resource_names.value != null)' >/dev/null 2>&1 <<<"$tf_json"; then
    rg=$(jq -r '.resource_names.value.resource_group // empty' <<<"$tf_json")
    prefix=$(jq -r '.resource_names.value.prefix // empty' <<<"$tf_json")
    vgw_name="vgw-$prefix"
    interconnect_mode=$(jq -r '.interconnect_mode.value // "existing"' <<<"$tf_json")
    if [[ -z "$AWS_PROFILE" ]]; then
        AWS_PROFILE=$(jq -r '.aws_profile.value // empty' <<<"$tf_json")
    fi
    if [[ -z "$AZURE_SUBSCRIPTION" ]]; then
        AZURE_SUBSCRIPTION=$(jq -r '.azure_subscription_id.value // empty' <<<"$tf_json")
    fi
else
    Write-Warn 'No Terraform outputs found - falling back to prefix-based names.'
    prefix=$(Read-Required 'Resource name prefix (e.g. mcilab)')
    rg="rg-$prefix-azure"
    vgw_name="vgw-$prefix"
    interconnect_mode='existing'
    if [[ -z "$AWS_PROFILE" ]]; then
        AWS_PROFILE=$(Read-Required 'AWS profile')
    fi
    if [[ -z "$AZURE_SUBSCRIPTION" ]]; then
        AZURE_SUBSCRIPTION=$(Read-Required 'Azure subscription id')
    fi
fi

if [[ "$FORCE" != true ]]; then
    printf '\n%sThis destroys the lab VNet, VPC, both gateways and both VMs.%s\n' "$C_YELLOW" "$C_RESET"
    if [[ "$interconnect_mode" == 'create' ]]; then
        printf "%sinterconnect_mode = 'create': the Multicloud circuit AND the AWS%s\n" "$C_YELLOW" "$C_RESET"
        printf '%sinterconnect connection were built by Terraform and WILL ALSO BE DESTROYED.%s\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%sYour existing interconnect circuit and AWS connection are NOT touched.%s\n' "$C_YELLOW" "$C_RESET"
    fi
    answer=$(Read-Required 'Type DESTROY to continue')
    if [[ "$answer" != 'DESTROY' ]]; then
        printf 'Aborted.\n'
        exit 1
    fi
fi

Write-Step 'terraform destroy'
set +e
(cd "$TF_DIR" && terraform destroy -auto-approve)
tf_exit=$?
set -e

Write-Step 'Verifying the ExpressRoute gateway is gone'
rg_exists=$(az group exists --name "$rg" --subscription "$AZURE_SUBSCRIPTION" -o tsv 2>/dev/null || true)

if [[ "$rg_exists" == 'true' ]]; then
    gws_json=$(az network vnet-gateway list --resource-group "$rg" --subscription "$AZURE_SUBSCRIPTION" -o json 2>/dev/null || true)
    gws_count=$(jq 'length' <<<"${gws_json:-[]}")
    if ((gws_count > 0)); then
        printf '%s  [FAIL] %d virtual network gateway(s) still exist in %s - YOU ARE STILL BEING BILLED.%s\n' "$C_RED" "$gws_count" "$rg" "$C_RESET"
        jq -r '.[] | "         - \(.name) (\(.sku.name))"' <<<"$gws_json" |
        while IFS= read -r gateway; do
            printf '%s%s%s\n' "$C_RED" "$gateway" "$C_RESET"
        done
        exit 1
    fi
    Write-Ok "no virtual network gateways remain in $rg."

    # The container group is a fraction of the gateway's cost, but it bills per
    # second for as long as it exists, so a leftover one bills forever quietly.
    cgs_json=$(az container list --resource-group "$rg" --subscription "$AZURE_SUBSCRIPTION" -o json 2>/dev/null || true)
    cgs_count=$(jq 'length' <<<"${cgs_json:-[]}")
    if ((cgs_count > 0)); then
        printf '%s  [FAIL] %d container group(s) still exist in %s - STILL BILLING.%s\n' "$C_RED" "$cgs_count" "$rg" "$C_RESET"
        jq -r '.[] | "         - \(.name)"' <<<"$cgs_json" |
        while IFS= read -r group; do
            printf '%s%s%s\n' "$C_RED" "$group" "$C_RESET"
        done
        exit 1
    fi
    Write-Ok "no container groups remain in $rg."

    Write-Warn "resource group $rg still exists."
else
    Write-Ok "resource group $rg no longer exists."
fi

Write-Step 'Verifying the DXGW association is released'
vgws_json=$(aws ec2 describe-vpn-gateways \
    --filters "Name=tag:Name,Values=$vgw_name" "Name=state,Values=available,pending" \
    --profile "$AWS_PROFILE" --output json 2>/dev/null || true)
vgws_count=$(jq '(.VpnGateways // []) | length' <<<"${vgws_json:-{}}")

if ((vgws_count > 0)); then
    vgw_id=$(jq -r '.VpnGateways[0].VpnGatewayId // empty' <<<"$vgws_json")
    printf '%s  [FAIL] virtual private gateway still present: %s%s\n' "$C_RED" "$vgw_id" "$C_RESET"
    exit 1
fi
Write-Ok 'no lab virtual private gateway remains.'

# In create mode Terraform owns the transport itself. The AWS interconnect is a
# billable port, so an orphan here quietly costs real money - which is exactly
# the class of failure this script exists to catch.
if [[ "$interconnect_mode" == 'create' ]]; then
    Write-Step 'Verifying the Terraform-built interconnect pair is gone'

    if [[ "$rg_exists" == 'true' ]]; then
        circuits_json=$(az network express-route list --resource-group "$rg" --subscription "$AZURE_SUBSCRIPTION" -o json 2>/dev/null || true)
        circuits_count=$(jq 'length' <<<"${circuits_json:-[]}")
        if ((circuits_count > 0)); then
            printf '%s  [FAIL] %d ExpressRoute circuit(s) still exist in %s.%s\n' "$C_RED" "$circuits_count" "$rg" "$C_RESET"
            jq -r '.[] | "         - \(.name)"' <<<"$circuits_json" |
            while IFS= read -r circuit; do
                printf '%s%s%s\n' "$C_RED" "$circuit" "$C_RESET"
            done
            exit 1
        fi
    fi
    Write-Ok 'no Multicloud circuit remains.'

    # Matched on description because Terraform sets it from the prefix, and the
    # DXGW it attached to has been destroyed by this point.
    desc="Azure to AWS multicloud interconnect $prefix"
    conns_json=$(aws interconnect list-connections --profile "$AWS_PROFILE" --output json 2>/dev/null || true)
    conns_left=$(jq --arg d "$desc" \
        '[(.connections // [])[] | select(.description == $d and (.state != "deleted") and (.state != "deleting"))]' \
        <<<"${conns_json:-{}}")
    conns_count=$(jq 'length' <<<"$conns_left")

    if ((conns_count > 0)); then
        printf '%s  [FAIL] AWS interconnect connection still present - YOU ARE STILL BEING BILLED.%s\n' "$C_RED" "$C_RESET"
        jq -r '.[] | "         - \(.id) (state: \(.state))"' <<<"$conns_left" |
        while IFS= read -r conn; do
            printf '%s%s%s\n' "$C_RED" "$conn" "$C_RESET"
        done
        exit 1
    fi
    Write-Ok 'no lab AWS interconnect connection remains.'
fi

if [[ "$interconnect_mode" == 'create' ]]; then
    printf '\n%sTeardown complete. Terraform-managed Multicloud circuit and AWS interconnect were included in destroy.%s\n\n' "$C_CYAN" "$C_RESET"
else
    printf '\n%sTeardown complete. Existing interconnect circuit and AWS connection are untouched.%s\n\n' "$C_CYAN" "$C_RESET"
fi
exit "$tf_exit"

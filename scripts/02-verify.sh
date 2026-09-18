#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Validates the private Azure <-> AWS path over the multicloud interconnect.
#
# Run after `terraform apply`.
##############################################################################

AWS_PROFILE=''
AZURE_SUBSCRIPTION=''
SKIP_DATA_PLANE=false

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
Usage: scripts/02-verify.sh [options]

Validates the private Azure <-> AWS path over the multicloud interconnect.
Run after `terraform apply`.

Options:
  --aws-profile NAME
      AWS CLI profile to use. Defaults to the Terraform aws_profile output.
  --azure-subscription ID
      Azure subscription to query. Defaults to the Terraform
      azure_subscription_id output.
  --skip-data-plane
      Skip SSH-driven VM-to-VM ping, MTU, and traceroute checks.
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
            --skip-data-plane|-SkipDataPlane)
                SKIP_DATA_PLANE=true; shift ;;
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

Join-By() {
    local delimiter=$1
    shift
    local first=true
    local item

    for item in "$@"; do
        if [[ "$first" == true ]]; then
            printf '%s' "$item"
            first=false
        else
            printf '%s%s' "$delimiter" "$item"
        fi
    done
}

ip_to_uint() {
    local ip=$1
    local a b c d
    local IFS=.

    read -r a b c d <<<"$ip"
    printf '%u' "$((((10#$a) << 24) + ((10#$b) << 16) + ((10#$c) << 8) + (10#$d)))"
}

Test-CidrContains() {
    local outer=$1
    local inner=$2
    local outer_ip=${outer%/*}
    local outer_len=${outer#*/}
    local inner_ip=${inner%/*}
    local inner_len=${inner#*/}
    local shift_bits
    local outer_uint
    local inner_uint

    if ((inner_len < outer_len)); then
        return 1
    fi
    if ((outer_len == 0)); then
        return 0
    fi

    shift_bits=$((32 - outer_len))
    outer_uint=$(ip_to_uint "$outer_ip")
    inner_uint=$(ip_to_uint "$inner_ip")
    (( (outer_uint >> shift_bits) == (inner_uint >> shift_bits) ))
}

Print-Learned-Routes() {
    jq -r '
        .value[]?
        | [
            (.network // ""),
            (.nextHop // ""),
            (.origin // ""),
            (.asPath // "" | tostring),
            (.sourcePeer // "")
          ]
        | @tsv
    ' |
    awk -F '\t' 'BEGIN {
        printf "network              nextHop              origin              asPath              sourcePeer\n"
        printf "-------              -------              ------              ------              ----------\n"
    }
    {
        printf "%-20s %-20s %-19s %-19s %s\n", $1, $2, $3, $4, $5
    }'
}

Print-Routes() {
    jq -r '
        .RouteTables[0].Routes[]?
        | [
            (.DestinationCidrBlock // ""),
            (.GatewayId // ""),
            (.Origin // ""),
            (.State // "")
          ]
        | @tsv
    ' |
    awk -F '\t' 'BEGIN {
        printf "DestinationCidrBlock GatewayId            Origin                         State\n"
        printf "-------------------- ---------            ------                         -----\n"
    }
    {
        printf "%-20s %-20s %-30s %s\n", $1, $2, $3, $4
    }'
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

tf_json=$(cd "$TF_DIR" && terraform output -json)

if ! jq -e 'has("resource_names") and (.resource_names.value != null)' >/dev/null <<<"$tf_json"; then
    printf "%sTerraform output 'resource_names' is missing. Run 'terraform apply' with the current configuration first.%s\n" "$C_RED" "$C_RESET" >&2
    exit 1
fi

if [[ -z "$AWS_PROFILE" ]]; then
    AWS_PROFILE=$(jq -r '.aws_profile.value // empty' <<<"$tf_json")
fi
if [[ -z "$AZURE_SUBSCRIPTION" ]]; then
    AZURE_SUBSCRIPTION=$(jq -r '.azure_subscription_id.value // empty' <<<"$tf_json")
fi

rg_name=$(jq -r '.resource_names.value.resource_group // empty' <<<"$tf_json")
gw_name=$(jq -r '.resource_names.value.er_gateway // empty' <<<"$tf_json")
aws_route_table=$(jq -r '.resource_names.value.aws_route_table // empty' <<<"$tf_json")

az_private=$(jq -r '.azure_vm_private_ip.value // empty' <<<"$tf_json")
az_public=$(jq -r '.azure_vm_public_ip.value // empty' <<<"$tf_json")
aws_private=$(jq -r '.aws_vm_private_ip.value // empty' <<<"$tf_json")
aws_public=$(jq -r '.aws_vm_public_ip.value // empty' <<<"$tf_json")
key_path=$(jq -r '.ssh_private_key_path.value // empty' <<<"$tf_json")

interconnect_built=$(jq -r '.interconnect_built.value // false' <<<"$tf_json")
azure_cidr=$(jq -r '.cidrs.value.azure_supernet // empty' <<<"$tf_json")
azure_spoke_cidr=$(jq -r '.cidrs.value.azure_spoke // empty' <<<"$tf_json")
aws_cidr=$(jq -r '.cidrs.value.aws_vpc // empty' <<<"$tf_json")

if [[ "$interconnect_built" != 'true' ]]; then
    printf '\n%s*** DEMO MODE ***%s\n' "$C_YELLOW" "$C_RESET"
    printf '%screate_interconnect = false, so the clouds are NOT joined.%s\n' "$C_YELLOW" "$C_RESET"
    printf '%sEvery cross-cloud check below is EXPECTED to fail until you run:%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s  pwsh scripts/03-interconnect.ps1 -Action Connect%s\n\n' "$C_YELLOW" "$C_RESET"
fi

##############################################################################
Write-Step 'Control plane: Azure gateway learned routes'
##############################################################################

learned_json=$(az network vnet-gateway list-learned-routes \
    --name "$gw_name" --resource-group "$rg_name" \
    --subscription "$AZURE_SUBSCRIPTION" -o json 2>/dev/null || true)

if [[ -n "$learned_json" ]] && jq -e '(.value // []) | length > 0' >/dev/null 2>&1 <<<"$learned_json"; then
    Print-Learned-Routes <<<"$learned_json"

    if jq -e --arg cidr "$aws_cidr" '.value[]? | select(.network == $cidr)' >/dev/null <<<"$learned_json"; then
        Write-Ok "Azure is learning $aws_cidr from AWS."
    else
        Write-Bad "Azure is NOT learning $aws_cidr."
        Add-Failure 'Azure gateway is not learning the AWS prefix'
    fi
else
    Write-Bad 'no learned routes returned; the ExpressRoute connection may still be provisioning.'
    Add-Failure 'No learned routes on the Azure gateway'
fi

##############################################################################
Write-Step 'Control plane: AWS VPC route table propagation'
##############################################################################

rts_json=$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$aws_route_table" \
    --profile "$AWS_PROFILE" --output json 2>/dev/null || true)

if [[ -n "$rts_json" ]] && jq -e '(.RouteTables // []) | length > 0' >/dev/null 2>&1 <<<"$rts_json"; then
    Print-Routes <<<"$rts_json"

    propagated_cidrs=()
    spoke_found=false
    spoke_origin=''

    while IFS=$'\t' read -r destination origin; do
        if [[ -n "$destination" ]] && Test-CidrContains "$azure_cidr" "$destination"; then
            propagated_cidrs+=("$destination")
            if [[ "$destination" == "$azure_spoke_cidr" ]]; then
                spoke_found=true
                spoke_origin=$origin
            fi
        fi
    done < <(jq -r '
        .RouteTables[0].Routes[]?
        | select(.DestinationCidrBlock != null)
        | [(.DestinationCidrBlock // ""), (.Origin // "")]
        | @tsv
    ' <<<"$rts_json")

    if [[ "$spoke_found" == true ]]; then
        Write-Ok "AWS route table has $azure_spoke_cidr (origin: $spoke_origin)."
    elif ((${#propagated_cidrs[@]} > 0)); then
        propagated_joined=$(Join-By ', ' "${propagated_cidrs[@]}")
        Write-Bad "AWS learned $propagated_joined but not the spoke prefix $azure_spoke_cidr."
        Add-Failure 'AWS route table has not learned the Azure spoke prefix'
    else
        Write-Bad "AWS route table is missing every prefix inside $azure_cidr."
        Add-Failure 'AWS route table has not learned the Azure prefixes'
    fi
else
    Write-Bad "route table $aws_route_table not found."
    Add-Failure 'AWS route table not found'
fi

##############################################################################
Write-Step 'Control plane: Direct Connect Gateway association'
##############################################################################

dx_gw_id=$(jq -r '.dx_gateway_id.value // empty' <<<"$tf_json")
assocs_json=$(aws directconnect describe-direct-connect-gateway-associations \
    --direct-connect-gateway-id "$dx_gw_id" \
    --profile "$AWS_PROFILE" --output json 2>/dev/null || true)

if [[ -n "$assocs_json" ]] && jq -e . >/dev/null 2>&1 <<<"$assocs_json"; then
    jq -r '
        .directConnectGatewayAssociations[]?
        | "  \(.associationState // "") -> \(.associatedGateway.id // "") (\(.associatedGateway.type // ""))  prefixes: \([(.associatedGateway.region // ""), ([.allowedPrefixesToDirectConnectGateway[]?.cidr] | join(","))] | join(" "))"
    ' <<<"$assocs_json"
fi

if [[ -n "$assocs_json" ]] && jq -e '.directConnectGatewayAssociations[]? | select(.associationState == "associated")' >/dev/null 2>&1 <<<"$assocs_json"; then
    Write-Ok 'at least one association is in state "associated".'
else
    Write-Bad 'no association in state "associated".'
    Add-Failure 'DXGW association is not associated'
fi

##############################################################################
if [[ "$SKIP_DATA_PLANE" != true ]]; then
    Write-Step 'Data plane: VM to VM over private addresses'

    ssh_opts=(
        -i "$key_path"
        -o StrictHostKeyChecking=accept-new
        -o BatchMode=yes
        -o ConnectTimeout=15
    )

    printf '\n%s  Azure (%s) -> AWS (%s)%s\n' "$C_YELLOW" "$az_private" "$aws_private" "$C_RESET"
    set +e
    ssh_out=$(ssh "${ssh_opts[@]}" "azureuser@$az_public" "ping -c 4 -W 3 $aws_private; echo '--- MTU probe ---'; ping -M do -s 1372 -c 2 -W 3 $aws_private" 2>&1)
    ssh_exit=$?
    set -e
    printf '%s\n' "$ssh_out"
    if ((ssh_exit != 0)); then
        FAILED+=('Azure -> AWS ping failed')
    fi

    printf '\n%s  AWS (%s) -> Azure (%s)%s\n' "$C_YELLOW" "$aws_private" "$az_private" "$C_RESET"
    set +e
    ssh_out=$(ssh "${ssh_opts[@]}" "ec2-user@$aws_public" "ping -c 4 -W 3 $az_private; echo '--- traceroute ---'; traceroute -n -w 2 -m 8 $az_private" 2>&1)
    ssh_exit=$?
    set -e
    printf '%s\n' "$ssh_out"
    if ((ssh_exit != 0)); then
        FAILED+=('AWS -> Azure ping failed')
    fi
fi

##############################################################################
probe_enabled=$(jq -r '.resource_names.value.probe_enabled // false' <<<"$tf_json")
if [[ "$probe_enabled" == 'true' ]]; then
    Write-Step 'Latency probe'

    # Control-plane only, so this still runs under --skip-data-plane. It answers
    # "are both vantage points reporting?" - 05-latency.sh is where the actual
    # numbers live.
    probe_group=$(jq -r '.resource_names.value.probe_container_group // empty' <<<"$tf_json")
    probe_url=$(jq -r '.probe_dashboard_url.value // empty' <<<"$tf_json" | sed 's:/*$::')

    cg_state=$(az container show --name "$probe_group" --resource-group "$rg_name" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --query "containers[0].instanceView.currentState.state" -o tsv 2>/dev/null || true)

    if [[ "$cg_state" == 'Running' ]]; then
        Write-Ok "hub prober $probe_group is running."
    else
        Write-Bad "hub prober $probe_group is '${cg_state:-unknown}', not Running."
        FAILED+=('latency probe container group is not running')
    fi

    if probe_summary=$(curl -fsS --max-time 20 "$probe_url/api/summary?window=15m" 2>/dev/null); then
        reporting=$(jq -r 'keys | length' <<<"$probe_summary")
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            Write-Ok "$line"
        done < <(jq -r 'to_entries[] | "\(.key) reporting (\(.value.samples) samples in 15m)."' <<<"$probe_summary")

        if ((reporting < 2)); then
            # One vantage point cannot produce the hub-versus-spoke delta, which
            # is the only reason the probe exists.
            Write-Warn "only $reporting vantage point(s) reporting; expected 2."
            Write-Info 'A freshly applied probe needs a minute or two before both appear.'
        fi
    else
        Write-Warn "collector unreachable at $probe_url"
        Write-Info 'Check that the NSG permits your current public IP on the dashboard port.'
    fi
fi

##############################################################################
Write-Step 'Summary'
if ((${#FAILED[@]} == 0)); then
    printf '%s  All checks passed - the private cross-cloud path is up.%s\n' "$C_GREEN" "$C_RESET"
    exit 0
fi

printf '%s  %d check(s) failed:%s\n' "$C_RED" "${#FAILED[@]}" "$C_RESET"
for failure in "${FAILED[@]}"; do
    printf '%s    - %s%s\n' "$C_RED" "$failure" "$C_RESET"
done
exit 1

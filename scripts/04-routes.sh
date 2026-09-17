#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Dumps every routing table on both ends of the interconnect.
#
# A read-only diagnostic. Where 02-verify answers "is the path up?" with a
# pass/fail, this answers "what does each device actually believe?" and prints
# it, including the two views 02-verify never shows: what Azure ADVERTISES to
# AWS, and the BGP session state behind it.
##############################################################################

AWS_PROFILE=''
AZURE_SUBSCRIPTION=''
INCLUDE_GUEST=false
OUT_FILE=''
JSON_OUTPUT=false

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

Write-Step() {
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi
    printf '\n%s=== %s ===%s\n' "$C_CYAN" "$1" "$C_RESET" >&2
}
Write-Ok()   { printf '%s  [ok]   %s%s\n' "$C_GREEN" "$1" "$C_RESET" >&2; }
Write-Warn() { printf '%s  [warn] %s%s\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }
Write-Bad()  {
    printf '%s  [FAIL] %s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}
Add-Failure() { FAILED+=("$1"); }

Write-Note() {
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    local text=$1
    local color=${2-DarkGray}
    local prefix=$C_DARKGRAY

    if [[ "$color" == 'Yellow' ]]; then
        prefix=$C_YELLOW
    fi

    printf '%s  %s%s\n' "$prefix" "$text" "$C_RESET" >&2
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

usage() {
    cat <<'EOF'
Usage: scripts/04-routes.sh [options]

Dumps every routing table on both ends of the interconnect.
Run after `terraform apply`.

Options:
  --aws-profile NAME
      AWS CLI profile to use. Defaults to the Terraform aws_profile output.
  --azure-subscription ID
      Azure subscription to query. Defaults to the Terraform
      azure_subscription_id output.
  --include-guest
      Also SSH to both VMs and print their kernel routing tables.
  --out-file PATH
      Also write the full transcript to a file.
  --json
      Emit one JSON object with every section instead of formatted tables.
  -h, --help
      Show this help.

Examples:
  scripts/04-routes.sh
  scripts/04-routes.sh --include-guest --out-file routes.txt
  scripts/04-routes.sh --json | jq .
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
            --include-guest|-IncludeGuest)
                INCLUDE_GUEST=true; shift ;;
            --out-file|-OutFile)
                OUT_FILE=${2-}; shift 2 ;;
            --out-file=*)
                OUT_FILE=${1#*=}; shift ;;
            --json|-Json)
                JSON_OUTPUT=true; shift ;;
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

Run-Command() {
    local __outvar=$1
    local __errvar=$2
    shift 2

    local err_file output error exit_code
    err_file=$(mktemp)

    set +e
    output=$("$@" 2>"$err_file")
    exit_code=$?
    set -e

    error=$(<"$err_file")
    rm -f "$err_file"

    # The Azure CLI emits CRLF on Windows. Normalise every captured stream so
    # no caller has to think about it.
    output=${output//$'\r'/}
    error=${error//$'\r'/}

    printf -v "$__outvar" '%s' "$output"
    printf -v "$__errvar" '%s' "$error"
    return "$exit_code"
}

First-Line() {
    local text=$1
    local first=''

    first=$(sed -n '1p' <<<"$text")
    if [[ -n "${first//[[:space:]]/}" ]]; then
        printf '%s' "$first"
    else
        printf 'command failed'
    fi
}

Json-Array-Has-Rows() {
    jq -e '(. // []) | length > 0' >/dev/null 2>&1 <<<"$1"
}

Column-Table() {
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t'
    else
        cat
    fi
}

Lines-To-Json() {
    local text=$1

    jq -Rn --arg text "$text" '$text | if . == "" then [] else split("\n") end'
}

Print-Learned-Routes() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(" ")
            else tostring end;
        (
            ["network", "origin", "asPath", "sourcePeer", "nextHop", "weight"],
            (.[]? | [(.network | cell), (.origin | cell), (.asPath | cell), (.sourcePeer | cell), (.nextHop | cell), (.weight | cell)])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Bgp-Peers() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(" ")
            else tostring end;
        (
            ["neighbor", "asn", "state", "connectedDuration", "routesReceived", "messagesSent", "messagesReceived"],
            (.[]? | [(.neighbor | cell), (.asn | cell), (.state | cell), (.connectedDuration | cell), (.routesReceived | cell), (.messagesSent | cell), (.messagesReceived | cell)])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Advertised-Routes() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(" ")
            else tostring end;
        (
            ["network", "origin", "asPath", "nextHop"],
            (.[]? | [(.network | cell), (.origin | cell), (.asPath | cell), (.nextHop | cell)])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Nic-Effective() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(",")
            else tostring end;
        (
            ["source", "state", "addressPrefix", "nextHopType", "nextHopIp"],
            (.[]? | [(.source | cell), (.state | cell), (.addressPrefix | cell), (.nextHopType | cell), (.nextHopIpAddress | cell)])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Aws-Routes() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(" ")
            else tostring end;
        (
            ["DestinationCidrBlock", "GatewayId", "Origin", "State"],
            (.[]? | [(.DestinationCidrBlock | cell), (.GatewayId | cell), (.Origin | cell), (.State | cell)])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Vgw-Propagation() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        (
            ["GatewayId"],
            (.[]? | [(.GatewayId // "")])
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

Print-Dxgw-Association() {
    local rows=$1
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi

    if ! Json-Array-Has-Rows "$rows"; then
        Write-Note '(empty)' 'Yellow'
        return
    fi

    jq -r '
        def cell:
            if . == null then ""
            elif type == "array" then map(tostring) | join(" ")
            else tostring end;
        (
            ["state", "associatedGw", "type", "region", "allowedPrefixes"],
            (
                .[]?
                | [
                    (.associationState | cell),
                    (.associatedGateway.id | cell),
                    (.associatedGateway.type | cell),
                    (.associatedGateway.region | cell),
                    ([.allowedPrefixesToDirectConnectGateway[]?.cidr] | join(", "))
                  ]
            )
        )
        | @tsv
    ' <<<"$rows" | Column-Table
}

parse_args "$@"

if [[ -n "$OUT_FILE" ]]; then
    if [[ "$JSON_OUTPUT" == true ]]; then
        exec > >(tee "$OUT_FILE") 2> >(tee -a "$OUT_FILE" >&2)
    else
        exec > >(tee "$OUT_FILE") 2>&1
    fi
fi

# The AWS MSI installs here but the current shell may predate the PATH update.
if [[ -d '/c/Program Files/Amazon/AWSCLIV2' && ":$PATH:" != *":/c/Program Files/Amazon/AWSCLIV2:"* ]]; then
    export PATH="/c/Program Files/Amazon/AWSCLIV2:$PATH"
fi

Require-Tool 'jq' 'install jq 1.6 or newer'
Require-Tool 'terraform' 'install Terraform 1.5 or newer'
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
prefix=$(jq -r '.resource_names.value.prefix // empty' <<<"$tf_json")
nic_name="nic-$prefix-vm"
aws_route_table_name=$(jq -r '.resource_names.value.aws_route_table // empty' <<<"$tf_json")
dx_gw_id=$(jq -r '.dx_gateway_id.value // empty' <<<"$tf_json")

learned_routes_json='null'
bgp_peers_json='null'
advertised_routes_json='{}'
nic_effective_json='null'
aws_route_table_json='null'
vgw_propagation_json='null'
dxgw_association_json='null'
guest_routes_json='null'

learned_raw=''
learned_err=''
peers_raw=''
peers_err=''
adv_raw=''
adv_err=''
eff_raw=''
eff_err=''
rts_raw=''
rts_err=''
prop_raw=''
prop_err=''
assocs_raw=''
assocs_err=''

if [[ "$JSON_OUTPUT" != true ]]; then
    printf '\nRouting dump  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >&2
    printf '  gateway : %s (%s)\n' "$gw_name" "$rg_name" >&2
    printf '  aws     : profile %s\n' "$AWS_PROFILE" >&2
fi

##############################################################################
Write-Step 'Azure 1/4  ExpressRoute gateway - LEARNED routes (inbound)'
##############################################################################
if Run-Command learned_raw learned_err az network vnet-gateway list-learned-routes \
    --name "$gw_name" --resource-group "$rg_name" \
    --subscription "$AZURE_SUBSCRIPTION" -o json; then
    if jq -e . >/dev/null 2>&1 <<<"$learned_raw"; then
        learned_routes_json=$(jq -c '.value // []' <<<"$learned_raw")
        Print-Learned-Routes "$learned_routes_json"
        Write-Note 'origin Network = local VNet prefix; origin EBgp = learned across the interconnect.'
    else
        Write-Warn 'could not parse learned routes as JSON.'
    fi
else
    Write-Warn "could not read learned routes: $(First-Line "$learned_err")"
fi

##############################################################################
Write-Step 'Azure 2/4  BGP peer status'
##############################################################################
if Run-Command peers_raw peers_err az network vnet-gateway list-bgp-peer-status \
    --name "$gw_name" --resource-group "$rg_name" \
    --subscription "$AZURE_SUBSCRIPTION" -o json; then
    if jq -e . >/dev/null 2>&1 <<<"$peers_raw"; then
        bgp_peers_json=$(jq -c '.value // []' <<<"$peers_raw")
        Print-Bgp-Peers "$bgp_peers_json"
        Write-Note 'A short connectedDuration means the session recently re-established.'
    else
        Write-Warn 'could not parse BGP peer status as JSON.'
    fi
else
    Write-Warn "could not read BGP peer status: $(First-Line "$peers_err")"
fi

##############################################################################
Write-Step 'Azure 3/4  ExpressRoute gateway - ADVERTISED routes (outbound)'
##############################################################################
# The direction 02-verify never checks. If AWS cannot reach the Azure spoke, the
# cause is almost always that the spoke prefix is missing here, which means
# gateway transit on the hub/spoke peering is not set up.
remote_peers=()
# tr -d '\r' is load-bearing on Windows: az emits CRLF, mapfile -t strips only
# the LF, and feeding the surviving CR back as --peer fails with
# "The IP address was not valid or not specified."
mapfile -t remote_peers < <(jq -r '.[]? | select(.state == "Connected" and (.neighbor // "") != "") | .neighbor' <<<"$bgp_peers_json" | tr -d '\r')

if ((${#remote_peers[@]} == 0)); then
    Write-Note 'no connected BGP peers, skipping.' 'Yellow'
fi

for peer in "${remote_peers[@]}"; do
    if [[ "$JSON_OUTPUT" != true ]]; then
        printf '%s  peer %s%s\n' "$C_YELLOW" "$peer" "$C_RESET" >&2
    fi

    if Run-Command adv_raw adv_err az network vnet-gateway list-advertised-routes \
        --name "$gw_name" --resource-group "$rg_name" \
        --subscription "$AZURE_SUBSCRIPTION" --peer "$peer" -o json; then
        if jq -e . >/dev/null 2>&1 <<<"$adv_raw"; then
            adv_value=$(jq -c '.value // []' <<<"$adv_raw")
            advertised_routes_json=$(jq -c --arg peer "$peer" --argjson adv "$adv_value" '. + {($peer): $adv}' <<<"$advertised_routes_json")
            Print-Advertised-Routes "$adv_value"
        else
            Write-Warn "could not parse advertised routes for ${peer} as JSON."
        fi
    else
        Write-Warn "could not read advertised routes for ${peer}: $(First-Line "$adv_err")"
    fi
done

##############################################################################
Write-Step 'Azure 4/4  Effective routes on the VM NIC (data plane)'
##############################################################################
# Learned routes are the gateway's view. This is what the VM's traffic actually
# follows, after peering, NSGs and system routes are applied.
if Run-Command eff_raw eff_err az network nic show-effective-route-table \
    --name "$nic_name" --resource-group "$rg_name" \
    --subscription "$AZURE_SUBSCRIPTION" -o json; then
    if jq -e . >/dev/null 2>&1 <<<"$eff_raw"; then
        nic_effective_json=$(jq -c '.value // []' <<<"$eff_raw")
        Print-Nic-Effective "$nic_effective_json"
        Write-Note 'nextHopType VirtualNetworkGateway on the AWS prefix is the one that matters.'
    else
        Write-Warn "could not parse effective routes for ${nic_name} as JSON."
    fi
else
    Write-Warn "could not read effective routes for ${nic_name}: $(First-Line "$eff_err")"
fi

##############################################################################
Write-Step 'AWS 1/3  VPC route table'
##############################################################################
if Run-Command rts_raw rts_err aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$aws_route_table_name" \
    --profile "$AWS_PROFILE" --output json; then
    if jq -e . >/dev/null 2>&1 <<<"$rts_raw"; then
        aws_route_table_json=$(jq -c '.RouteTables // []' <<<"$rts_raw")
        route_table_count=$(jq 'length' <<<"$aws_route_table_json")
        if ((route_table_count == 0)); then
            Write-Note '(empty)' 'Yellow'
        fi
        for ((i = 0; i < route_table_count; i++)); do
            route_table_id=$(jq -r ".[$i].RouteTableId // empty" <<<"$aws_route_table_json")
            if [[ "$JSON_OUTPUT" != true ]]; then
                printf '%s  %s%s\n' "$C_YELLOW" "$route_table_id" "$C_RESET" >&2
            fi
            rt_routes=$(jq -c ".[$i].Routes // []" <<<"$aws_route_table_json")
            Print-Aws-Routes "$rt_routes"
        done
        Write-Note 'Origin EnableVgwRoutePropagation = learned from Azure across the interconnect.'
    else
        Write-Warn 'could not parse the VPC route table as JSON.'
    fi
else
    Write-Warn "could not read the VPC route table: $(First-Line "$rts_err")"
fi

##############################################################################
Write-Step 'AWS 2/3  Virtual private gateway propagation'
##############################################################################
if Run-Command prop_raw prop_err aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$aws_route_table_name" \
    --profile "$AWS_PROFILE" --output json; then
    if jq -e . >/dev/null 2>&1 <<<"$prop_raw"; then
        vgw_propagation_json=$(jq -c '[.RouteTables[]?.PropagatingVgws[]?]' <<<"$prop_raw")
        Print-Vgw-Propagation "$vgw_propagation_json"
        if ! Json-Array-Has-Rows "$vgw_propagation_json"; then
            Write-Note 'no propagating VGW: AWS will never install the Azure prefixes.' 'Yellow'
        fi
    else
        Write-Warn 'could not parse VGW propagation as JSON.'
    fi
else
    Write-Warn "could not read VGW propagation: $(First-Line "$prop_err")"
fi

##############################################################################
Write-Step 'AWS 3/3  Direct Connect gateway association'
##############################################################################
if Run-Command assocs_raw assocs_err aws directconnect describe-direct-connect-gateway-associations \
    --direct-connect-gateway-id "$dx_gw_id" \
    --profile "$AWS_PROFILE" --output json; then
    if jq -e . >/dev/null 2>&1 <<<"$assocs_raw"; then
        dxgw_association_json=$(jq -c '.directConnectGatewayAssociations // []' <<<"$assocs_raw")
        Print-Dxgw-Association "$dxgw_association_json"
        Write-Note 'allowedPrefixes filters what AWS accepts toward the DXGW; empty means no filter.'
    else
        Write-Warn 'could not parse the DXGW association as JSON.'
    fi
else
    Write-Warn "could not read the DXGW association: $(First-Line "$assocs_err")"
fi

##############################################################################
if [[ "$INCLUDE_GUEST" == true ]]; then
    Write-Step 'Guest  kernel routing tables'
    ##############################################################################

    guest_routes_json='{}'
    key_path=$(jq -r '.ssh_private_key_path.value // empty' <<<"$tf_json")
    azure_public=$(jq -r '.azure_vm_public_ip.value // empty' <<<"$tf_json")
    aws_public=$(jq -r '.aws_vm_public_ip.value // empty' <<<"$tf_json")

    if [[ -n "$key_path" && -f "$key_path" ]]; then
        chmod 600 "$key_path" 2>/dev/null || true
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        Write-Warn 'ssh not found: install OpenSSH client to read guest kernel routes.'
    else
        ssh_opts=(
            -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null
            -o BatchMode=yes
            -o ConnectTimeout=15
        )
        if [[ -n "$key_path" ]]; then
            ssh_opts=(-i "$key_path" "${ssh_opts[@]}")
        fi

        for target in "azure azureuser $azure_public" "aws ec2-user $aws_public"; do
            read -r guest_name guest_user guest_host <<<"$target"
            if [[ -z "$guest_host" ]]; then
                continue
            fi

            if [[ "$JSON_OUTPUT" != true ]]; then
                printf '%s  %s VM (%s)%s\n' "$C_YELLOW" "$guest_name" "$guest_host" "$C_RESET" >&2
            fi

            set +e
            guest_out=$(ssh "${ssh_opts[@]}" "$guest_user@$guest_host" 'ip route show; echo "--- mtu ---"; ip link show | grep -E "^[0-9]+: (eth|ens)"' 2>&1)
            guest_exit=$?
            set -e

            guest_lines_json=$(Lines-To-Json "$guest_out")
            guest_routes_json=$(jq -c --arg name "$guest_name" --argjson lines "$guest_lines_json" '. + {($name): $lines}' <<<"$guest_routes_json")

            if [[ "$JSON_OUTPUT" != true ]]; then
                while IFS= read -r line; do
                    printf '    %s\n' "$line"
                done <<<"$guest_out"
            fi

            if ((guest_exit != 0)); then
                Write-Warn "could not read guest routes for ${guest_name}: ssh exited $guest_exit"
            fi
        done
    fi
fi

if [[ "$JSON_OUTPUT" == true ]]; then
    jq -n \
        --argjson learnedRoutes "$learned_routes_json" \
        --argjson bgpPeers "$bgp_peers_json" \
        --argjson advertisedRoutes "$advertised_routes_json" \
        --argjson nicEffective "$nic_effective_json" \
        --argjson awsRouteTable "$aws_route_table_json" \
        --argjson vgwPropagation "$vgw_propagation_json" \
        --argjson dxgwAssociation "$dxgw_association_json" \
        --argjson guestRoutes "$guest_routes_json" \
        '{
            learnedRoutes: $learnedRoutes,
            bgpPeers: $bgpPeers,
            advertisedRoutes: $advertisedRoutes,
            nicEffective: $nicEffective,
            awsRouteTable: $awsRouteTable,
            vgwPropagation: $vgwPropagation,
            dxgwAssociation: $dxgwAssociation,
            guestRoutes: $guestRoutes
        }'
fi

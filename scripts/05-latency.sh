#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Reads the latency collector and compares the two vantage points.
#
# The lab's headline latency number was always measured from the VM, which
# lives in the spoke region because this subscription cannot build a VM in the
# gateway's region. That measurement includes an inter-region hop that has
# nothing to do with the interconnect.
#
# This script reads both vantage points from the collector and prints the
# difference, which is the part of the spoke figure that the forced region
# split is responsible for.
#
# Read-only. It changes nothing on either cloud.
#
# Twin of scripts/05-latency.ps1 - keep the two in sync.
##############################################################################

WINDOW='1h'
AZURE_SUBSCRIPTION=''
JSON_OUTPUT=false

##############################################################################
# Output helpers
##############################################################################

if [[ -t 2 ]]; then
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_DARKGRAY=$'\033[90m'
    C_WHITE=$'\033[97m'
    C_RESET=$'\033[0m'
else
    C_CYAN=''
    C_GREEN=''
    C_YELLOW=''
    C_DARKGRAY=''
    C_WHITE=''
    C_RESET=''
fi

Write-Step() {
    if [[ "$JSON_OUTPUT" == true ]]; then return; fi
    printf '\n%s=== %s ===%s\n' "$C_CYAN" "$1" "$C_RESET" >&2
}

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

usage() {
    cat <<'EOF'
Usage: scripts/05-latency.sh [options]

Reads the latency collector and compares the hub and spoke vantage points.
Run after `terraform apply`.

Options:
  --window VALUE
      Look-back window. Accepts 15m, 1h, 6h, 24h, 7d or a bare number of
      seconds. Defaults to 1h.
  --azure-subscription ID
      Azure subscription to query. Defaults to the Terraform
      azure_subscription_id output.
  --json
      Emit the raw collector summary instead of formatted tables.
  -h, --help
      Show this help.

Examples:
  scripts/05-latency.sh
  scripts/05-latency.sh --window 24h
  scripts/05-latency.sh --json | jq .
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --window|-Window)
                WINDOW=${2-}; shift 2 ;;
            --window=*)
                WINDOW=${1#*=}; shift ;;
            --azure-subscription|-AzureSubscription)
                AZURE_SUBSCRIPTION=${2-}; shift 2 ;;
            --azure-subscription=*)
                AZURE_SUBSCRIPTION=${1#*=}; shift ;;
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
        printf '%s  [FAIL] %s not found. %s%s\n' "$C_YELLOW" "$name" "$hint" "$C_RESET" >&2
        exit 1
    fi
}

##############################################################################

parse_args "$@"

Require-Tool jq 'Install it: https://jqlang.github.io/jq/download/'
Require-Tool curl 'Install curl.'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TF_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)/terraform

TF_JSON=$(terraform -chdir="$TF_DIR" output -json)

if [[ $(jq -r 'has("resource_names")' <<<"$TF_JSON") != 'true' ]]; then
    printf 'Terraform output "resource_names" is missing. Run "terraform apply" first.\n' >&2
    exit 1
fi

PROBE_ENABLED=$(jq -r '.resource_names.value.probe_enabled // false' <<<"$TF_JSON")
if [[ "$PROBE_ENABLED" != 'true' ]]; then
    printf '\nThe latency probe is not deployed (enable_latency_probe = false).\n' >&2
    printf 'Set it to true and re-apply to collect measurements.\n' >&2
    exit 0
fi

RG=$(jq -r '.resource_names.value.resource_group' <<<"$TF_JSON")
CG=$(jq -r '.resource_names.value.probe_container_group' <<<"$TF_JSON")
BASE_URL=$(jq -r '.probe_dashboard_url.value' <<<"$TF_JSON" | sed 's:/*$::')

if [[ -z "$AZURE_SUBSCRIPTION" ]]; then
    AZURE_SUBSCRIPTION=$(jq -r '.azure_subscription_id.value' <<<"$TF_JSON")
fi

if [[ "$JSON_OUTPUT" != true ]]; then
    printf '\n%sLatency probe  %s%s\n' "$C_WHITE" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET" >&2
    printf '  collector : %s\n' "$BASE_URL" >&2
    printf '  window    : %s\n' "$WINDOW" >&2
fi

##############################################################################
Write-Step '1/4  Hub prober (container group)'
##############################################################################
if CG_JSON=$(az container show --name "$CG" --resource-group "$RG" \
        --subscription "$AZURE_SUBSCRIPTION" -o json 2>/dev/null); then
    STATE=$(jq -r '.containers[0].instanceView.currentState.state // "unknown"' <<<"$CG_JSON")
    RESTARTS=$(jq -r '.containers[0].instanceView.restartCount // 0' <<<"$CG_JSON")
    Write-Note "state        : $STATE"
    Write-Note "private IP   : $(jq -r '.ipAddress.ip // "-"' <<<"$CG_JSON")"
    Write-Note "restarts     : $RESTARTS"

    if [[ "$STATE" != 'Running' ]]; then
        Write-Note 'the hub prober is not running; only the spoke vantage point will have data.' Yellow
    fi
    if ((RESTARTS > 3)); then
        Write-Note "restart count is high - check 'az container logs'." Yellow
    fi
else
    Write-Note 'could not read the container group.' Yellow
fi

##############################################################################
Write-Step '2/4  Collector health'
##############################################################################
if HEALTH=$(curl -fsS --max-time 20 "$BASE_URL/healthz" 2>/dev/null); then
    Write-Note "status       : $(jq -r '.status' <<<"$HEALTH")"
    Write-Note "samples held : $(jq -r '.samples' <<<"$HEALTH")"
else
    Write-Note "collector unreachable at $BASE_URL" Yellow
    Write-Note 'If this times out, the NSG may not permit your current public IP.' Yellow
    Write-Note 'Re-run 00-configure (or set probe_dashboard_allowed_cidrs) and re-apply.' Yellow
    if [[ "$JSON_OUTPUT" != true ]]; then exit 1; fi
fi

##############################################################################
Write-Step '3/4  Percentiles by vantage point'
##############################################################################
SUMMARY=$(curl -fsS --max-time 30 "$BASE_URL/api/summary?window=$WINDOW" 2>/dev/null || echo '{}')

if [[ "$JSON_OUTPUT" == true ]]; then
    jq . <<<"$SUMMARY"
    exit 0
fi

COUNT=$(jq -r 'keys | length' <<<"$SUMMARY")
if ((COUNT == 0)); then
    Write-Note 'no samples in this window yet.' Yellow
    Write-Note 'A freshly applied probe needs a minute or two before it reports.' Yellow
else
    {
        printf 'vantage\tmetric\tsamples\tmin\tp50\tp95\tp99\tmax\tloss%%\n'
        jq -r '
          to_entries | sort_by(.key)[] as $v
          | ["tcp_ms","icmp_ms"][] as $m
          | select($v.value[$m].p50 != null)
          | [ $v.key,
              (if $m == "tcp_ms" then "tcp/" + ($v.value.tcp_port|tostring) else "icmp" end),
              ($v.value[$m].count|tostring),
              ($v.value[$m].min  | (.*100|round)/100 | tostring),
              ($v.value[$m].p50  | (.*100|round)/100 | tostring),
              ($v.value[$m].p95  | (.*100|round)/100 | tostring),
              ($v.value[$m].p99  | (.*100|round)/100 | tostring),
              ($v.value[$m].max  | (.*100|round)/100 | tostring),
              (if $v.value[$m].loss_pct == null then "-" else ($v.value[$m].loss_pct | (.*10|round)/10 | tostring) end)
            ] | @tsv' <<<"$SUMMARY"
    } | column -t -s $'\t' >&2

    Write-Note 'All figures are milliseconds round-trip to the AWS instance PRIVATE IP.'

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        Write-Note "$name reports ICMP unsupported - it lacks the raw socket capability, so only TCP is measured." Yellow
    done < <(jq -r 'to_entries[] | select(.value.icmp_supported != true) | .key' <<<"$SUMMARY")
fi

##############################################################################
Write-Step '4/4  Cost of the region split'
##############################################################################
# This is the number the whole probe exists to produce.
HUB=$(jq -r '[to_entries[] | select(.key | contains("hub")) | .key][0] // empty' <<<"$SUMMARY")
SPOKE=$(jq -r '[to_entries[] | select(.key | contains("spoke")) | .key][0] // empty' <<<"$SUMMARY")

if [[ -n "$HUB" && -n "$SPOKE" ]]; then
    H=$(jq -r --arg k "$HUB"   '.[$k].tcp_ms.p50 // empty' <<<"$SUMMARY")
    S=$(jq -r --arg k "$SPOKE" '.[$k].tcp_ms.p50 // empty' <<<"$SUMMARY")

    if [[ -n "$H" && -n "$S" ]]; then
        read -r DELTA PCT < <(jq -rn --argjson h "$H" --argjson s "$S" \
            '[(($s-$h)*100|round)/100, (if $s > 0 then (($s-$h)*100/$s*1|round) else 0 end)] | @tsv')

        printf '%s  %-26s p50 %8.2f ms%s\n' "$C_GREEN"  "$HUB"   "$H" "$C_RESET" >&2
        printf '%s  %-26s p50 %8.2f ms%s\n' "$C_YELLOW" "$SPOKE" "$S" "$C_RESET" >&2
        printf '\n%s  region-split cost : %s ms  (%s%% of the spoke figure)%s\n' \
            "$C_WHITE" "$DELTA" "$PCT" "$C_RESET" >&2
        Write-Note 'That much of the spoke measurement is the inter-region hop, not the interconnect.'
    else
        Write-Note 'not enough data in both vantage points yet.' Yellow
    fi
else
    Write-Note 'need both a hub and a spoke vantage point to compute the delta.' Yellow
fi

printf '\n%s  Live chart: %s%s\n\n' "$C_CYAN" "$BASE_URL" "$C_RESET" >&2

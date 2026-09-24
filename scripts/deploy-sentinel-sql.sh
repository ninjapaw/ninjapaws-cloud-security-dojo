#!/usr/bin/env bash

set -Eeuo pipefail

# Native Windows az/node must receive resource IDs verbatim, including key=/subscriptions/... arguments.
# Template filenames already use AZURE_REPO_ROOT's platform-native path from common.sh.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="${DEPLOY_CONFIG_FILE:-$REPO_ROOT/config/deploy.config.json}"
COMMAND=plan
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-dev}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
WORKSPACE_GROUP=""
WORKSPACE_NAME=""
VM_GROUP=""
VM_NAME=""
ENABLE_ANALYTICS=true
ASSUME_YES=false

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
usage() {
    printf '%s\n' \
        'Usage: scripts/deploy-sentinel-sql.sh <plan|doctor|what-if|deploy|verify> [options]' \
        '  --environment <dev|prod>       Resolve the SQL VM and workspace from deploy.config.json' \
        '  --subscription <id>            Explicit target; defaults to the current Azure CLI account' \
        '  --workspace-group <name>       Existing central workspace resource group' \
        '  --workspace-name <name>        Existing central workspace name' \
        '  --vm-group <name> --vm-name <name>  Override the monitored SQL VM' \
        '  --disable-rules                Deploy the analytics rules disabled' \
        '  --yes                          Confirm content deployment without a prompt' \
        'Plan is offline. Doctor, what-if and verify do not change Azure resources.' \
        'Requires existing Sentinel onboarding. Never changes AMA, DCRs, secrets or billing.'
}

while (($# > 0)); do
    case "$1" in
        plan|doctor|what-if|deploy|verify) COMMAND="$1"; shift ;;
        --environment|--subscription|--workspace-group|--workspace-name|--vm-group|--vm-name)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
            case "$1" in
                --environment) ENVIRONMENT="$2" ;;
                --subscription) SUBSCRIPTION_ID="$2" ;;
                --workspace-group) WORKSPACE_GROUP="$2" ;;
                --workspace-name) WORKSPACE_NAME="$2" ;;
                --vm-group) VM_GROUP="$2" ;;
                --vm-name) VM_NAME="$2" ;;
            esac
            shift 2 ;;
        --disable-rules) ENABLE_ANALYTICS=false; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ "$ENVIRONMENT" == dev || "$ENVIRONMENT" == prod ]] || fail 'Environment must be dev or prod.'
[[ -f "$CONFIG_FILE" ]] || fail "Configuration not found: $CONFIG_FILE"
setting() {
    local value
    value="$(config_lookup "environments.$ENVIRONMENT.$1")"
    [[ -n "$value" ]] || value="$(config_lookup "sqlScenario.$1")"
    printf '%s' "${value:-$2}"
}

VM_GROUP="${VM_GROUP:-$(setting sqlResourceGroup "NP-ninjapaws-dojo-sql-${ENVIRONMENT}")}"
VM_NAME="${VM_NAME:-$(setting sqlVmName "ninjapaws-sql-vm-${ENVIRONMENT}")}"
SENTINEL_MODE="${SENTINEL_MODE:-$(setting sentinelMode "new")}"
case "$SENTINEL_MODE" in
    new)
        WORKSPACE_GROUP="${WORKSPACE_GROUP:-$(setting sentinelResourceGroup "$VM_GROUP")}"
        WORKSPACE_NAME="${WORKSPACE_NAME:-$(setting sentinelWorkspaceName "log-${VM_NAME}")}"
        ;;
    existing)
        WORKSPACE_GROUP="${WORKSPACE_GROUP:-$(setting centralWorkspaceResourceGroup NP-Sentinel-CentralUS)}"
        WORKSPACE_NAME="${WORKSPACE_NAME:-$(setting centralWorkspaceName log-np-sentinel-centralus)}"
        ;;
    *)
        fail "sentinelMode must be 'new' or 'existing'."
        ;;
esac
DEPLOYMENT_NAME="dojo-sql-sentinel-${ENVIRONMENT}"

printf 'Sentinel mode: %s\nWorkspace: %s / %s\nSQL VM: %s / %s\nAnalytics enabled: %s\n' \
    "$SENTINEL_MODE" "$WORKSPACE_GROUP" "$WORKSPACE_NAME" "$VM_GROUP" "$VM_NAME" "$ENABLE_ANALYTICS"
printf '%s\n' 'Content: DojoSqlAudit parser, ten analytics rules, login-change hunt, ingestion-health query.'
printf '%s\n' 'Unchanged: workspace ingestion/retention, Sentinel onboarding, AMA/DCR, SQL state, Key Vault.'
[[ "$COMMAND" != plan ]] || exit 0

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
[[ -n "$SUBSCRIPTION_ID" ]] || fail 'Sign in to Azure CLI and select the intended subscription.'
SQL_VM_ID="$(az vm show --subscription "$SUBSCRIPTION_ID" -g "$VM_GROUP" -n "$VM_NAME" --query id -o tsv)"
WORKSPACE_ID="$(az monitor log-analytics workspace show --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$WORKSPACE_NAME" --query id -o tsv)"
CUSTOMER_ID="$(az monitor log-analytics workspace show --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$WORKSPACE_NAME" --query customerId -o tsv)"
[[ -n "$SQL_VM_ID" && -n "$WORKSPACE_ID" && -n "$CUSTOMER_ID" ]] || fail 'Unable to resolve existing VM and workspace.'
ARM_ENDPOINT="$(az cloud show --query endpoints.resourceManager -o tsv)"
SENTINEL_URL="${ARM_ENDPOINT%/}${WORKSPACE_ID}/providers/Microsoft.SecurityInsights"
az rest --method get --url "$SENTINEL_URL/onboardingStates/default?api-version=2025-09-01" --query name -o tsv >/dev/null \
    || fail 'Sentinel onboarding could not be read. Check Sentinel is enabled and you have workspace access; this script will not enable billing.'

if [[ "$COMMAND" == doctor ]]; then
    printf '%s\n' 'Sentinel onboarding is readable. SQL Event ingestion over the last 24 hours:'
    encoded_vm="$("$NODE_COMMAND" -e 'process.stdout.write(Buffer.from(process.argv[1]).toString("base64"))' "$SQL_VM_ID")"
    parser_query="$(<infra/sentinel-sql-solution/queries/DojoSqlAudit.kql)"
    query="let VmResourceId = base64_decode_tostring('$encoded_vm'); $parser_query
| where TimeGenerated > ago(24h)
| summarize Events=count(), LastEvent=max(TimeGenerated), LastIngested=max(IngestedAt) by EventID, ActionId, Operation"
    az monitor log-analytics query --subscription "$SUBSCRIPTION_ID" --workspace "$CUSTOMER_ID" --analytics-query "$query" --timespan P1D -o table
    printf '%s\n' 'No rows means no matching telemetry, not a healthy audit configuration.'
    exit 0
fi

if [[ "$COMMAND" == verify ]]; then
    deployed_vm="$(az deployment group show --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.outputs.monitoredSqlVm.value -o tsv)"
    [[ "$deployed_vm" == "$SQL_VM_ID" ]] || fail 'Recorded deployment targets a different SQL VM.'
    rule_ids="$(az deployment group show --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$DEPLOYMENT_NAME" --query 'properties.outputs.ruleIds.value[]' -o tsv)"
    [[ "$(printf '%s\n' "$rule_ids" | wc -l | tr -d ' ')" == 10 ]] || fail 'Expected ten deployed rule IDs.'
    while IFS= read -r rule_id; do
        az rest --method get --url "${ARM_ENDPOINT%/}${rule_id}?api-version=2025-09-01" --query 'properties.{Rule:displayName,Enabled:enabled,Frequency:queryFrequency}' -o table
    done <<< "$rule_ids"
    az rest --method get --url "${ARM_ENDPOINT%/}${WORKSPACE_ID}/savedSearches/DojoSqlAudit?api-version=2025-07-01" --query properties.functionAlias -o tsv
    for output_name in huntingQueryId healthQueryId; do
        search_id="$(az deployment group show --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.$output_name.value" -o tsv)"
        [[ -n "$search_id" ]] || fail "Missing $output_name deployment output."
        query="$(az rest --method get --url "${ARM_ENDPOINT%/}${search_id}?api-version=2025-07-01" --query properties.query -o tsv)"
        az monitor log-analytics query --subscription "$SUBSCRIPTION_ID" --workspace "$CUSTOMER_ID" --analytics-query "$query" --timespan P1D -o table
    done
    printf '%s\n' 'Content verified. Query results are evidence only; absence of rows does not prove an action was audited.'
    exit 0
fi

parameters=("workspaceName=$WORKSPACE_NAME" "sqlVmResourceId=$SQL_VM_ID" "enableAnalytics=$ENABLE_ANALYTICS")
template="$AZURE_REPO_ROOT/infra/sentinel-sql-solution/main.bicep"
az deployment group what-if --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" \
    --template-file "$template" --parameters "${parameters[@]}" --mode Incremental
[[ "$COMMAND" != what-if ]] || exit 0

if [[ "$ASSUME_YES" != true ]]; then
    [[ -t 0 ]] || fail 'Deployment requires --yes in a non-interactive shell.'
    read -r -p "Deploy Sentinel content to $WORKSPACE_NAME in subscription $SUBSCRIPTION_ID? [y/N] " answer
    [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
az deployment group create --subscription "$SUBSCRIPTION_ID" -g "$WORKSPACE_GROUP" -n "$DEPLOYMENT_NAME" \
    --template-file "$template" --parameters "${parameters[@]}" --mode Incremental \
    --query properties.provisioningState -o tsv
printf '%s\n' 'Deployment finished. Run verify with the same environment/subscription/overrides to inspect content and telemetry.'
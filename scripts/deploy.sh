#!/usr/bin/env bash

# Staged Azure lifecycle for the Ninja Paws Cloud Security Dojo.

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INVOCATION_DIR="$PWD"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
AZURE_REPO_ROOT="$REPO_ROOT"
AZURE_CLI_BIN="${AZURE_CLI_BIN:-az}"
if command -v wslpath >/dev/null 2>&1; then
    AZURE_REPO_ROOT="$(wslpath -w "$REPO_ROOT")"
elif command -v cygpath >/dev/null 2>&1; then
    AZURE_REPO_ROOT="$(cygpath -w "$REPO_ROOT")"
fi
# The Azure CLI installer does not always add itself to the PATH seen by Git Bash or WSL.
if ! command -v az >/dev/null 2>&1; then
    for azure_cli_dir in \
        "/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" \
        "/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" \
        "/c/Program Files (x86)/Microsoft SDKs/Azure/CLI2/wbin" \
        "/mnt/c/Program Files (x86)/Microsoft SDKs/Azure/CLI2/wbin"; do
        if [[ -f "$azure_cli_dir/az" || -f "$azure_cli_dir/az.cmd" ]]; then
            export PATH="$azure_cli_dir:$PATH"
            break
        fi
    done
fi
if command -v cmd.exe >/dev/null 2>&1; then
    windows_az_path="$(MSYS2_ARG_CONV_EXCL='/c' cmd.exe /c where az 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ -n "$windows_az_path" ]]; then
        if command -v wslpath >/dev/null 2>&1; then
            AZURE_CLI_BIN="$(wslpath -u "$windows_az_path")"
        elif command -v cygpath >/dev/null 2>&1; then
            AZURE_CLI_BIN="$(cygpath -u "$windows_az_path")"
        else
            AZURE_CLI_BIN="$windows_az_path"
        fi
        azure_cli_dir="$(dirname "$AZURE_CLI_BIN")"
        export PATH="$azure_cli_dir:$PATH"
    fi
fi

# Windows az.cmd emits CRLF output when called from WSL/Git Bash. MSYS also rewrites arguments that
# look like Unix paths, which would corrupt resource IDs and role-assignment scopes, so exclude those.
az() {
    MSYS2_ARG_CONV_EXCL='/subscriptions/;/providers/;/resourceGroups/' command "$AZURE_CLI_BIN" "$@" | tr -d '\r'
}

COMMAND="deploy"
# Precedence for every setting: CLI flag > environment variable > config file > built-in fallback.
# The workflow exports the unprefixed names, so both spellings are accepted.
CONFIG_FILE="${DEPLOY_CONFIG_FILE:-$REPO_ROOT/config/deploy.config.json}"
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-auto}"
SCENARIO_ID="${DEPLOY_SCENARIO:-}"
ALL_SCENARIOS=false
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
LOCATION="${AZURE_LOCATION:-${LOCATION:-}}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"
REGISTRY_NAME="${AZURE_CONTAINER_REGISTRY_NAME:-${CONTAINER_REGISTRY_NAME:-${REGISTRY_NAME:-}}}"
APP_SERVICE_NAME="${AZURE_APP_SERVICE_NAME:-${APP_SERVICE_NAME:-}}"
APP_SERVICE_PLAN_SKU="${AZURE_APP_SERVICE_PLAN_SKU:-${APP_SERVICE_PLAN_SKU:-}}"
IMAGE_NAME="${IMAGE_NAME:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
BASE_OS_IMAGE="${BASE_OS_IMAGE:-}"
BASE_OS_VERSION="${BASE_OS_VERSION:-}"
NGINX_VERSION="${NGINX_VERSION:-}"
VULNERABILITY_STATUS="${VULNERABILITY_STATUS:-}"
NODE_MAJOR_VERSION="${NODE_MAJOR_VERSION:-}"
PORT="${PORT:-}"
NPM_REGISTRY_URL="${NPM_REGISTRY_URL:-}"
NPM_USE_MIRROR="${NPM_USE_MIRROR:-}"
NPM_NETWORK_MODE="${NPM_NETWORK_MODE:-}"
DEFENDER_ENABLED="${DEFENDER_ENABLED:-}"
DEFENDER_SCAN_ENABLED="${DEFENDER_SCAN_ENABLED:-}"
DEFENDER_MANAGE_PLANS="${DEFENDER_MANAGE_PLANS:-}"
DEFENDER_TARGET_CVE="${DEFENDER_TARGET_CVE:-}"
DEFENDER_APPSERVICES_TIER="${DEFENDER_APPSERVICES_TIER:-}"
DEFENDER_CONTAINERS_TIER="${DEFENDER_CONTAINERS_TIER:-}"
DEFENDER_CSPM_TIER="${DEFENDER_CSPM_TIER:-}"
DEFENDER_ARM_TIER="${DEFENDER_ARM_TIER:-}"
DEFENDER_MANAGE_EXTENSIONS="${DEFENDER_MANAGE_EXTENSIONS:-}"
DEFENDER_CSPM_SERVERLESS_PROTECTION="${DEFENDER_CSPM_SERVERLESS_PROTECTION:-}"
DEFENDER_CSPM_SERVERLESS_CONTAINERS="${DEFENDER_CSPM_SERVERLESS_CONTAINERS:-}"
DEFENDER_CSPM_REGISTRY_ASSESSMENT="${DEFENDER_CSPM_REGISTRY_ASSESSMENT:-}"
DEFENDER_CSPM_KUBERNETES_DISCOVERY="${DEFENDER_CSPM_KUBERNETES_DISCOVERY:-}"
DEFENDER_CSPM_VM_SCANNING="${DEFENDER_CSPM_VM_SCANNING:-}"
DEFENDER_CSPM_SENSITIVE_DATA="${DEFENDER_CSPM_SENSITIVE_DATA:-}"
DEFENDER_CSPM_PERMISSIONS_MANAGEMENT="${DEFENDER_CSPM_PERMISSIONS_MANAGEMENT:-}"
DEFENDER_CSPM_API_POSTURE="${DEFENDER_CSPM_API_POSTURE:-}"
DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT="${DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT:-}"
DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY="${DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY:-}"
DEFENDER_CONTAINERS_VM_SCANNING="${DEFENDER_CONTAINERS_VM_SCANNING:-}"
DEFENDER_CONTAINERS_SENSOR="${DEFENDER_CONTAINERS_SENSOR:-}"
DEFENDER_DEVOPS_CONNECTOR_ENABLED="${DEFENDER_DEVOPS_CONNECTOR_ENABLED:-}"
DEFENDER_DEVOPS_CONNECTOR_NAME="${DEFENDER_DEVOPS_CONNECTOR_NAME:-}"
DEFENDER_DEVOPS_GITHUB_OWNER="${DEFENDER_DEVOPS_GITHUB_OWNER:-}"
GITHUB_ADVANCED_SECURITY_EXPECTED="${GITHUB_ADVANCED_SECURITY_EXPECTED:-}"
DEFENDER_DEVOPS_CONNECTOR_STATE=not_evaluated
GITHUB_ADVANCED_SECURITY_STATE=not_evaluated
DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE=not_evaluated
DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE=not_evaluated
DEFENDER_CSPM_API_POSTURE_AUDIT_STATE=not_evaluated
DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE=not_evaluated
SCENARIO_NAME=""
SCENARIO_SHORT_NAME=""
SCENARIO_CVE=""
SCENARIO_ADVISORY_URL=""
SCENARIO_AFFECTED_VERSION=""
SCENARIO_FIXED_VERSION=""
SCENARIO_WORKLOADS=""
ASSUME_YES=false
FORCE=false
FORCE_REBUILD=false
WAIT_FOR_DELETE=true
WAIT_FOR_DELETE_EXPLICIT=false
STATE_FILE=""
STATE_JS=""
STATUS_HTML=""
STATUS_CONSOLE=""
STATUS_RAW_CONSOLE=""
OUTPUT_DIR=""
STATUS_OPEN_MARKER=""
ARCHIVE_OUTPUTS=true
OUTPUT_ROOT="${OUTPUT_ROOT:-}"
CONSOLE_CAPTURE_STARTED=false
CONSOLE_AUTORELOAD=true
IMAGE_TAG_EXPLICIT=false
USE_DEFAULTS=false
OPEN_STATUS_HTML=true
REPORT_LINK_PRINTED=false
STATUS_BROWSER_OPENED=false
RUN_STARTED_AT="$(date +%s)"
RUN_STARTED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ENDED_ISO=""
RUN_ID=""
RUN_INVOCATION="${*:-$COMMAND}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
AZURE_ACCOUNT_NAME=""
SUBSCRIPTION_NAME=""
AUTHENTICATION_SKIPPED=false

# Read a dotted path of string values out of the config file without requiring jq.
config_lookup() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk -v want="$1" '
        BEGIN { depth = 0 }
        {
            line = $0
            gsub(/\r/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line ~ /^"[^"]+"[ \t]*:[ \t]*\{/) {
                key = line; sub(/^"/, "", key); sub(/".*/, "", key)
                depth++; stack[depth] = key; next
            }
            if (line ~ /^\}/) { if (depth > 0) depth--; next }
            if (line ~ /^"[^"]+"[ \t]*:[ \t]*".*"/) {
                key = line; sub(/^"/, "", key); sub(/".*/, "", key)
                val = line
                sub(/^"[^"]+"[ \t]*:[ \t]*"/, "", val); sub(/",?$/, "", val)
                path = ""
                for (i = 1; i <= depth; i++) path = path stack[i] "."
                if (path key == want) { print val; exit }
            }
        }
    ' "$CONFIG_FILE"
}

# Environment override first, then the shared default, then the built-in fallback.
config_setting() {
    local key="$1" fallback="$2" value
    value="$(config_lookup "environments.$ENVIRONMENT.$key")"
    [[ -n "$value" ]] || value="$(config_lookup "defaults.$key")"
    printf '%s' "${value:-$fallback}"
}

project_meta() {
    local value
    value="$(config_lookup "project.$1")"
    printf '%s' "${value:-$2}"
}

resolve_scenario() {
    local configured_ids
    configured_ids="$(config_lookup defaults.scenarioIds)"
    if [[ "$ALL_SCENARIOS" == true ]]; then
        SCENARIO_ID="$configured_ids"
    fi
    SCENARIO_ID="${SCENARIO_ID:-$(config_setting scenario defender-cloud-scenario-1)}"
    [[ "$SCENARIO_ID" != *,* ]] || fail "Multiple scenarios are not yet supported in a single deployment invocation. Use --scenario with one ID; the registry is ready for future --all-scenarios orchestration."
    SCENARIO_NAME="$(config_lookup "scenarios.$SCENARIO_ID.name")"
    SCENARIO_SHORT_NAME="$(config_lookup "scenarios.$SCENARIO_ID.shortName")"
    SCENARIO_CVE="$(config_lookup "scenarios.$SCENARIO_ID.cve")"
    SCENARIO_ADVISORY_URL="$(config_lookup "scenarios.$SCENARIO_ID.advisoryUrl")"
    SCENARIO_AFFECTED_VERSION="$(config_lookup "scenarios.$SCENARIO_ID.affectedVersion")"
    SCENARIO_FIXED_VERSION="$(config_lookup "scenarios.$SCENARIO_ID.fixedVersion")"
    SCENARIO_WORKLOADS="$(config_lookup "scenarios.$SCENARIO_ID.workloads")"
    [[ -n "$SCENARIO_NAME" && -n "$SCENARIO_CVE" ]] || fail "Unknown scenario '$SCENARIO_ID'. Use --help or inspect the scenarios registry in $CONFIG_FILE."
}

resolve_audit_context() {
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    APP_VERSION="$(sed -n 's/.*"version"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/package.json" 2>/dev/null | head -1)"
    APP_VERSION="${APP_VERSION:-unknown}"
    CONFIG_VERSION="$(config_lookup configVersion)"
    CONFIG_VERSION="${CONFIG_VERSION:-unknown}"
    GIT_BRANCH="${GITHUB_REF_NAME:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')}"
    GIT_COMMIT="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')}"
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
        GIT_DIRTY="modified (uncommitted changes present)"
    else
        GIT_DIRTY="clean"
    fi
    RUN_OPERATOR="${GITHUB_ACTOR:-${USER:-${USERNAME:-unknown}}}"
    RUN_HOST="$(hostname 2>/dev/null || printf 'unknown')"
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        RUN_ORIGIN="GitHub Actions"
        RUN_ORIGIN_DETAIL="workflow ${GITHUB_WORKFLOW:-unknown}, run ${GITHUB_RUN_ID}, attempt ${GITHUB_RUN_ATTEMPT:-1}, triggered by ${GITHUB_EVENT_NAME:-unknown}"
    else
        RUN_ORIGIN="Local workstation"
        RUN_ORIGIN_DETAIL="interactive shell on $RUN_HOST"
    fi
}

TASK_KEYS=()
TASK_LABELS=()
TASK_STATUSES=()
TASK_DETAILS=()
TASK_STARTED=()
TASK_ENDED=()
CHECK_LABELS=()
CHECK_RESULTS=()
CHECK_DETAILS=()
CURRENT_TASK=""
RUN_FINAL=false
RUN_RESULT=""
FAILURE_MESSAGE=""
APP_URL=""
APP_HTTP_CODE=""
HEALTH_HTTP_CODE=""
APP_RESPONSE_TIME=""
APP_READY_ATTEMPTS=0
APP_CONTAINER_ID=""
APP_STATUS_BODY=""
BUILD_FINGERPRINT=""
FINGERPRINT_TAG=""
IMAGE_DIGEST=""
BUILD_SKIPPED=false
ROLLOUT_SKIPPED=false

register_task() {
    TASK_KEYS+=("$1")
    TASK_LABELS+=("$2")
    TASK_STATUSES+=("not_started")
    TASK_DETAILS+=("Queued.")
    TASK_STARTED+=("0")
    TASK_ENDED+=("0")
}

task_index() {
    local i
    if ((${#TASK_KEYS[@]} > 0)); then
        for i in "${!TASK_KEYS[@]}"; do
            if [[ "${TASK_KEYS[$i]}" == "$1" ]]; then
                printf '%s' "$i"
                return 0
            fi
        done
    fi
    printf -- '-1'
}

# status: not_started | in_progress | success | failure | skipped | not_applicable
set_task() {
    local key="$1" status="$2" detail="${3:-}" index
    index="$(task_index "$key")"
    if [[ "$index" == -1 ]]; then
        return 0
    fi
    TASK_STATUSES[index]="$status"
    if [[ -n "$detail" ]]; then
        TASK_DETAILS[index]="$detail"
    fi
    case "$status" in
        in_progress)
            TASK_STARTED[index]="$(date +%s)"
            CURRENT_TASK="$key"
            ;;
        success|failure|skipped)
            TASK_ENDED[index]="$(date +%s)"
            if [[ "$CURRENT_TASK" == "$key" ]]; then
                CURRENT_TASK=""
            fi
            ;;
    esac
    return 0
}

# result: pass | fail | unknown | not_applicable
record_check() {
    CHECK_LABELS+=("$1")
    CHECK_RESULTS+=("$2")
    CHECK_DETAILS+=("${3:-No evidence captured.}")
}

register_lifecycle_tasks() {
    register_task preflight "Preflight: required tooling, Azure sign-in, subscription selection"
    register_task plan "Resolve settings, naming, and the run output workspace"
    case "$COMMAND" in
        setup|deploy|update|repair)
            register_task resourcegroup "Create and tag the resource group"
            register_task infra "Deploy the Bicep infrastructure"
            register_task fingerprint "Fingerprint the build context and compare it with the registry"
            register_task image "Build and push the container image, or reuse the matching digest"
            register_task appconfig "Point App Service at the immutable image with managed-identity pull"
            register_task restart "Restart App Service and wait for the container to answer"
            register_task verify "Verify Azure configuration, identity, and live endpoints"
            register_task defender "Activate recommended Defender plans and scan for workload CVEs"
            ;;
        provision)
            register_task resourcegroup "Create and tag the resource group"
            register_task infra "Deploy the Bicep infrastructure"
            ;;
        build)
            register_task fingerprint "Fingerprint the build context and compare it with the registry"
            register_task image "Build and push the container image, or reuse the matching digest"
            ;;
        rollout)
            register_task appconfig "Point App Service at the immutable image with managed-identity pull"
            register_task restart "Restart App Service and wait for the container to answer"
            register_task verify "Verify Azure configuration, identity, and live endpoints"
            register_task defender "Activate recommended Defender plans and scan for workload CVEs"
            ;;
        verify)
            register_task verify "Verify Azure configuration, identity, and live endpoints"
            register_task defender "Activate recommended Defender plans and scan for workload CVEs"
            ;;
        doctor)
            register_task bicep "Compile the Bicep template"
            register_task whatif "Run a what-if against the target resource group"
            ;;
        wizard)
            register_task permissions "Verify Azure subscription read access and inspect assigned roles"
            register_task discover "Discover the configured resource group and supported resources"
            register_task options "Present lifecycle actions available for the discovered state"
            ;;
        uninstall)
            register_task discover "Locate the target resource group"
            register_task ownership "Confirm Ninja Paws ownership tags before deleting"
            register_task delete "Request resource group deletion"
            register_task teardown "Confirm every resource has been removed"
            ;;
    esac
}

# Overall progress is derived from the registered task list so it stays honest per command.
# Optional argument: percent complete (0-100) within the task that is currently in progress.
auto_percent() {
    local fraction="${1:-0}" i status units=0 total=0
    if ((${#TASK_KEYS[@]} == 0)); then
        printf '0'
        return 0
    fi
    for i in "${!TASK_KEYS[@]}"; do
        status="${TASK_STATUSES[$i]}"
        total=$((total + 100))
        case "$status" in
            success|skipped|not_applicable) units=$((units + 100)) ;;
            in_progress)                    units=$((units + fraction)) ;;
        esac
    done
    if ((total == 0)); then
        printf '0'
        return 0
    fi
    printf '%s' $((units * 100 / total))
}

format_duration() {
    local seconds="${1:-0}"
    if ((seconds < 0)); then
        printf -- '&mdash;'
        return 0
    fi
    printf '%dm %02ds' $((seconds / 60)) $((seconds % 60))
}

usage() {
    cat <<'EOF'
Manage the Ninja Paws Cloud Security Dojo Azure lifecycle.

Usage: scripts/deploy.sh <command> [options]

Run scripts/manage.sh with no arguments to start the interactive wizard.

Commands:
  setup                    Provision, build, deploy, and verify
  provision                Create or update the resource group and Bicep resources
  build                    Build and push the selected image to ACR
    deploy|update            Provision, build, deploy the image, and verify
    rollout                  Configure App Service for an already-built image
  verify                   Validate Azure resources, image, identity, and endpoints
  repair                   Re-provision, rebuild, redeploy, and verify
  doctor                   Run local and Azure preflight checks and Bicep what-if
  plan                     Print the resolved deployment plan without changing Azure
    wizard                   Inspect Azure access and environment state, then offer valid lifecycle actions
  uninstall                Delete the owned resource group (requires --yes or confirmation)

Options:
    --environment <dev|prod|auto> Deployment environment (default: detected from Git branch)
  --subscription <id>      Azure subscription ID (default: current subscription)
  --location <region>      Azure region (default: centralus)
  --resource-group <name>  Azure resource group
  --registry-name <name>   Azure Container Registry name
  --app-service-name <name> App Service name
  --app-service-plan-sku <sku> App Service plan SKU (default: B2)
  --image-name <name>      Container image repository (default: ninjapaws-dojo)
  --image-tag <tag>        Image tag (default: current Git SHA)
    --scenario <id>          Scenario ID (default: defender-cloud-scenario-1)
    --all-scenarios          Deploy all configured scenarios (currently one scenario)
    --yes                    Skip confirmation; required for non-interactive uninstall
    --defaults               Accept built-in defaults without interactive prompts
  --force                  Allow uninstall of an untagged resource group
  --force-rebuild          Rebuild and redeploy even when the image content is unchanged
    --wait                   Wait for resource-group deletion to finish (default)
    --no-wait                Return after Azure accepts the deletion request
    --no-status-html         Disable the auto-refreshing HTML status report
    --no-open-status         Keep the report on disk without opening a browser
    --no-archive             Delete the previous environment output instead of archiving it
    --help                   Show this help

OIDC bootstrap is separate and should be run once per GitHub Environment:
  scripts/setup-azure-github-oidc.sh --environment <dev|prod> --provision
EOF
}

fail() {
    FAILURE_MESSAGE="$1"
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

prompt_default() {

    prompt_region() {
        local default_region="$1" answer index region
        local regions=(centralus eastus eastus2 westus2 westus3 southcentralus westcentralus northeurope westeurope uksouth southeastasia australiaeast)
        if [[ ! -t 0 ]]; then
            printf '%s' "$default_region"
            return 0
        fi
        printf '\nAzure region (default: %s)\n' "$default_region"
        for index in "${!regions[@]}"; do
            printf '  %2d) %s\n' "$((index + 1))" "${regions[$index]}"
        done
        while true; do
            read -r -p "Select a region by number or name [$default_region]: " answer
            answer="${answer:-$default_region}"
            if [[ "$answer" =~ ^[0-9]+$ ]]; then
                index=$((answer - 1))
                if ((index >= 0 && index < ${#regions[@]})); then
                    printf '%s' "${regions[$index]}"
                    return 0
                fi
            else
                for region in "${regions[@]}"; do
                    if [[ "$answer" == "$region" ]]; then
                        printf '%s' "$region"
                        return 0
                    fi
                done
            fi
            printf 'Please choose one of the listed region numbers or names.\n' >&2
        done
    }
    local prompt="$1"
    local default_value="$2"
    local answer
    if [[ -t 0 ]]; then
        read -r -p "$prompt [$default_value]: " answer
        printf '%s' "${answer:-$default_value}"
    else
        printf '%s' "$default_value"
    fi
}

prompt_boolean() {
    local prompt="$1" default_value="$2" answer
    if [[ ! -t 0 ]]; then
        printf '%s' "$default_value"
        return 0
    fi
    while true; do
        if [[ "$default_value" == true ]]; then
            read -r -p "$prompt [Y/n] " answer
            answer="${answer:-yes}"
        else
            read -r -p "$prompt [y/N] " answer
            answer="${answer:-no}"
        fi
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) printf 'true'; return 0 ;;
            [Nn]|[Nn][Oo]) printf 'false'; return 0 ;;
            *) printf 'Please answer yes or no.\n' >&2 ;;
        esac
    done
}

confirm() {
    local message="$1"
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    [[ -t 0 ]] || fail "Confirmation is required in non-interactive mode. Re-run with --yes."
    local answer
    read -r -p "$message [y/N] " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Operation cancelled."
}

html_escape() {
        printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

mask_identifier() {
    local value="${1:-}"
    if [[ "$value" == "current Azure subscription" ]]; then
        printf '%s' "$value"
        return 0
    fi
    if [[ ${#value} -le 8 ]]; then
        printf '%s' "${value:-not recorded}"
    else
        printf '%s...%s' "${value:0:4}" "${value: -4}"
    fi
}

# The browser reloads these files every 3s, so never leave a half-written page on disk.
# Windows rename fails while a reader holds the target open, so retry before the non-atomic fallback.
publish_atomically() {
    local source="$1" target="$2" attempt=0
    while ((attempt < 20)); do
        if mv -f "$source" "$target" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.05 2>/dev/null || true
    done
    cp -f "$source" "$target" 2>/dev/null || true
    rm -f "$source" 2>/dev/null || true
    return 0
}

line_seen() {
    local needle="$1"
    local line
    [[ -f "$2" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$needle" ]] && return 0
    done < "$2"
    return 1
}

write_console_html() {
        local line line_number=0 reload_script="" console_tmp
        [[ -n "$STATUS_CONSOLE" ]] || return 0
        if [[ "${CONSOLE_AUTORELOAD:-true}" == true ]]; then
            reload_script='        window.setTimeout(function () { window.location.reload(); }, 3000);'
        fi
        console_tmp="$STATUS_CONSOLE.tmp"
        cat > "$console_tmp" <<EOF
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ninja Paws Deployment Console - $(html_escape "$ENVIRONMENT")</title>
    <style>
        :root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; background: #091322; color: #d9e7f5; }
        html, body { height: 100%; }
        body { margin: 0; padding: 12px 16px 16px; display: flex; flex-direction: column; overflow: hidden; }
        header { display: flex; align-items: center; gap: 12px; padding: 4px 0 12px; color: #f2a24a; font-family: Inter, ui-sans-serif, system-ui, sans-serif; flex: 0 0 auto; }
        .mark { display: grid; place-items: center; width: 32px; height: 32px; border-radius: 10px 10px 10px 3px; background: #f2a24a; color: #102f4d; font-weight: 900; font-family: Inter, ui-sans-serif, system-ui, sans-serif; font-size: 13px; }
        header strong { font-size: 12px; letter-spacing: .1em; }
        header small { display: block; color: #8fa6bc; font-size: 10px; letter-spacing: .12em; margin-top: 3px; }
        .terminal { flex: 1 1 auto; min-height: 0; border: 1px solid #28415c; border-radius: 12px; overflow: auto; overscroll-behavior: contain; background: #0d1a2b; box-shadow: 0 12px 30px #0006; }
        .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 6px 18px; padding: 10px 14px; margin-bottom: 10px; border: 1px solid #28415c; border-radius: 10px; background: #0d1a2b; flex: 0 0 auto; font-size: 11px; }
        .meta span { color: #8fa6bc; }
        .meta b { color: #d9e7f5; font-weight: 600; }
        .warn-strip { flex: 0 0 auto; margin-bottom: 10px; padding: 8px 14px; border-radius: 8px; background: #3a1c1c; border: 1px solid #6d2b2b; color: #f0b4b4; font-size: 11px; }
        .foot { flex: 0 0 auto; padding: 10px 2px 0; color: #58718b; font-size: 10px; }
        .line { display: grid; grid-template-columns: 52px 1fr; min-width: max-content; border-bottom: 1px solid #ffffff0b; }
        .number { padding: 5px 10px; color: #58718b; text-align: right; user-select: none; background: #0a1524; }
        .text { padding: 5px 14px; white-space: pre-wrap; overflow-wrap: anywhere; }
        .empty { color: #58718b; padding: 24px; text-align: center; }
    </style>
</head>
<body>
    <header><span class="mark">NP</span><span><strong>NINJA PAWS DEPLOYMENT CONSOLE</strong><small>LIVE RAW TERMINAL STREAM &middot; $(html_escape "$ENVIRONMENT") &middot; RUN $(html_escape "$RUN_ID")</small></span></header>
    <div class="meta">
        <span>Command <b>$(html_escape "$COMMAND")</b></span>
        <span>Environment <b>$(html_escape "$ENVIRONMENT")</b></span>
        <span>Started <b>$(html_escape "$RUN_STARTED_ISO")</b></span>
        <span>Operator <b>$(html_escape "$RUN_OPERATOR")</b></span>
        <span>Origin <b>$(html_escape "$RUN_ORIGIN")</b></span>
        <span>Branch <b>$(html_escape "$GIT_BRANCH")</b></span>
        <span>Commit <b>$(html_escape "${GIT_COMMIT:0:12}")</b></span>
        <span>Subscription <b>$(html_escape "${SUBSCRIPTION_ID:-unknown}")</b></span>
        <span>Version <b>v$(html_escape "$APP_VERSION")</b></span>
    </div>
    <div class="warn-strip"><strong>USE AT YOUR OWN RISK.</strong> Intentionally vulnerable training environment &mdash; keep it isolated and delete it when the exercise ends.</div>
    <div class="terminal" id="terminal">
EOF
        if [[ -s "$STATUS_RAW_CONSOLE" ]]; then
                while IFS= read -r line; do
                        line_number=$((line_number + 1))
                        printf '    <div class="line"><span class="number">%s</span><span class="text">%s</span></div>\n' "$line_number" "$(html_escape "$line")" >> "$console_tmp"
                    done < "$STATUS_RAW_CONSOLE"
        else
                    printf '    <div class="empty">Waiting for deployment output...</div>\n' >> "$console_tmp"
        fi
                cat >> "$console_tmp" <<EOF
    </div>
    <script>
    (function () {
        var terminal = document.getElementById('terminal');
        var TOP_KEY = 'np-console-top';
        var PINNED_KEY = 'np-console-pinned';
        var store = null;
        try { store = window.sessionStorage; store.getItem(TOP_KEY); } catch (error) { store = null; }

        // Follow the tail unless the reader has deliberately scrolled up.
        var pinned = store ? store.getItem(PINNED_KEY) !== '0' : true;
        if (pinned) {
            terminal.scrollTop = terminal.scrollHeight;
        } else {
            terminal.scrollTop = parseInt(store.getItem(TOP_KEY) || '0', 10);
        }

        terminal.addEventListener('scroll', function () {
            var atBottom = terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 24;
            if (store) {
                store.setItem(PINNED_KEY, atBottom ? '1' : '0');
                store.setItem(TOP_KEY, String(terminal.scrollTop));
            }
        }, { passive: true });

$reload_script
    })();
    </script>
    <div class="foot">$(html_escape "$(project_meta copyright 'Copyright (c) Ninja Paws')") &middot; v$(html_escape "$APP_VERSION") &middot; Licensed under $(html_escape "$(project_meta license MIT)") &middot; Provided as-is, without warranty. Generated $(date -u +%Y-%m-%dT%H:%M:%SZ).</div>
</body>
</html>
EOF
        publish_atomically "$console_tmp" "$STATUS_CONSOLE"
}

open_status_html() {
    [[ "$OPEN_STATUS_HTML" == true && -n "$STATUS_HTML" ]] || return 0
    local native browser browser_name url
    native="$(native_path "$STATUS_HTML")"
    url="$(report_url "$STATUS_HTML")"
    print_report_link_once
    [[ "$STATUS_BROWSER_OPENED" == false ]] || return 0
    if [[ -n "$STATUS_OPEN_MARKER" && -f "$STATUS_OPEN_MARKER" ]] && grep -Fxq "$url" "$STATUS_OPEN_MARKER" 2>/dev/null; then
        STATUS_BROWSER_OPENED=true
        echo "Report is already marked as open for this workspace; not opening another browser tab."
        return 0
    fi
    browser="${DEPLOY_BROWSER:-${BROWSER:-}}"
    browser_name="${browser##*/}"
    case "$browser_name" in
        edge|msedge|msedge.exe|microsoft-edge|microsoft-edge-dev)
            browser="${browser:-$browser_name}"
            if command -v "$browser" >/dev/null 2>&1; then
                STATUS_BROWSER_OPENED=true
                "$browser" "$native" >/dev/null 2>&1 &
                mark_status_html_opened "$url"
                return 0
            fi
            ;;
    esac
    if [[ "${CODESPACES:-false}" == true || -n "${CODESPACE_NAME:-}" || -n "${VSCODE_IPC_HOOK_CLI:-}" ]] && command -v code >/dev/null 2>&1; then
        STATUS_BROWSER_OPENED=true
        code --open-url "$url" >/dev/null 2>&1 &
        mark_status_html_opened "$url"
        return 0
    fi
    for browser in msedge.exe microsoft-edge microsoft-edge-dev edge; do
        if command -v "$browser" >/dev/null 2>&1; then
            STATUS_BROWSER_OPENED=true
            "$browser" "$native" >/dev/null 2>&1 &
            mark_status_html_opened "$url"
            return 0
        fi
    done
    if [[ "$native" == *:\\* ]]; then
        # MSYS rewrites a bare "/c" into "C:\", which turns cmd.exe /c into an interactive shell.
        if command -v powershell.exe >/dev/null 2>&1; then
            STATUS_BROWSER_OPENED=true
            powershell.exe -NoProfile -NonInteractive -Command "Start-Process -FilePath '$native'" >/dev/null 2>&1 &
            mark_status_html_opened "$url"
        elif command -v cmd.exe >/dev/null 2>&1; then
            STATUS_BROWSER_OPENED=true
            MSYS_NO_PATHCONV=1 cmd.exe /c start "" "$native" >/dev/null 2>&1 &
            mark_status_html_opened "$url"
        fi
    elif command -v xdg-open >/dev/null 2>&1; then
        STATUS_BROWSER_OPENED=true
        xdg-open "$STATUS_HTML" >/dev/null 2>&1 &
        mark_status_html_opened "$url"
    elif command -v open >/dev/null 2>&1; then
        STATUS_BROWSER_OPENED=true
        open "$STATUS_HTML" >/dev/null 2>&1 &
        mark_status_html_opened "$url"
    fi
    return 0
}

mark_status_html_opened() {
    [[ -n "$STATUS_OPEN_MARKER" ]] || return 0
    printf '%s\n' "$1" > "$STATUS_OPEN_MARKER" 2>/dev/null || true
}

# The browser needs a host-native path: MSYS and WSL paths are not valid file:// URLs on Windows.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    elif command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

report_url() {
    local native
    native="$(native_path "$1")"
    if [[ "$native" == *:\\* ]]; then
        printf 'file:///%s' "${native//\\//}"
    else
        printf 'file://%s' "$native"
    fi
}

print_report_link() {
    [[ -n "$STATUS_HTML" ]] || return 0
    local url copy_note=""
    url="$(report_url "$STATUS_HTML")"
    if command -v clip.exe >/dev/null 2>&1; then
        printf '%s' "$url" | clip.exe 2>/dev/null && copy_note="(copied to clipboard)"
    elif command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$url" | pbcopy 2>/dev/null && copy_note="(copied to clipboard)"
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$url" | wl-copy 2>/dev/null && copy_note="(copied to clipboard)"
    fi
    echo -e "${BLUE}--- LIVE DEPLOYMENT REPORT (${ENVIRONMENT}) ---${NC}"
    echo -e "  ${CYAN:-\033[0;36m}${url}${NC} ${copy_note}"
    return 0
}

print_report_link_once() {
    [[ "$REPORT_LINK_PRINTED" == false ]] || return 0
    print_report_link
    REPORT_LINK_PRINTED=true
}

print_terminal_status() {
    local phase="$1"
    local status="$2"
    local percent="$3"
    local detail="${4:-}"
    local width=28 filled empty elapsed icon
    filled=$((percent * width / 100))
    empty=$((width - filled))
    elapsed=$(( $(date +%s) - RUN_STARTED_AT ))
    case "$status" in
        success) icon="✓"; color="$GREEN" ;;
        failed) icon="✗"; color="$RED" ;;
        waiting|starting) icon="…"; color="$YELLOW" ;;
        *) icon="•"; color="$BLUE" ;;
    esac
    printf "\n${color}%s %s %-12s [%s%s] %3s%%  +%ss${NC}\n" "$icon" "$phase" "$status" "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' "$empty" '')" "$percent" "$elapsed"
    printf "  ${BLUE}↳${NC} %s\n" "$detail"
    print_report_link_once
}

start_console_capture() {
    [[ "$CONSOLE_CAPTURE_STARTED" == true || "${NO_STATUS_HTML:-false}" == true || "${NO_CONSOLE_CAPTURE:-false}" == true ]] && return 0
    [[ -n "$STATUS_CONSOLE" ]] || return 0
    [[ -t 1 ]] || return 0
    CONSOLE_CAPTURE_STARTED=true
    exec > >(tee -a "$STATUS_RAW_CONSOLE") 2>&1
}

render_task_rows() {
    local i status label detail started ended elapsed icon cls text since_attr
    if ((${#TASK_KEYS[@]} == 0)); then
        printf '        <p>No lifecycle tasks were registered for this command.</p>\n'
        return 0
    fi
    for i in "${!TASK_KEYS[@]}"; do
        status="${TASK_STATUSES[$i]}"
        label="${TASK_LABELS[$i]}"
        detail="${TASK_DETAILS[$i]}"
        started="${TASK_STARTED[$i]}"
        ended="${TASK_ENDED[$i]}"
        elapsed=-1
        since_attr=""
        if ((started > 0)); then
            if ((ended > 0)); then
                elapsed=$((ended - started))
            else
                elapsed=$(( $(date +%s) - started ))
                since_attr=" data-since=\"$started\""
            fi
        fi
        case "$status" in
            success)        cls=ok;   icon='&#10003;'; text='Success' ;;
            failure)        cls=bad;  icon='&#10007;'; text='Failure' ;;
            in_progress)    cls=run;  icon='';         text='In progress' ;;
            skipped)        cls=na;   icon='&#8631;';  text='Skipped' ;;
            not_applicable) cls=na;   icon='&#8709;';  text='Not applicable' ;;
            *)              cls=idle; icon='&#9675;';  text='Not started' ;;
        esac
        printf '        <div class="task %s">' "$cls"
        if [[ "$status" == in_progress ]]; then
            printf '<span class="ico %s spinner"></span>' "$cls"
        else
            printf '<span class="ico %s">%s</span>' "$cls" "$icon"
        fi
        printf '<div class="task-body"><div class="task-name">%s. %s</div><div class="task-detail">%s</div></div>' \
            "$((i + 1))" "$(html_escape "$label")" "$(html_escape "$detail")"
        printf '<div class="task-meta"><span class="pill %s">%s</span><span class="elapsed"%s>%s</span></div></div>\n' \
            "$cls" "$text" "$since_attr" "$(format_duration "$elapsed")"
    done
}

render_check_rows() {
    local i result label detail cls text
    if ((${#CHECK_LABELS[@]} == 0)); then
        printf '            <tr><td colspan="3">No verification checks have run yet. They execute during the verify stage.</td></tr>\n'
        return 0
    fi
    for i in "${!CHECK_LABELS[@]}"; do
        result="${CHECK_RESULTS[$i]}"
        label="${CHECK_LABELS[$i]}"
        detail="${CHECK_DETAILS[$i]}"
        case "$result" in
            pass)           cls=ok;   text='Pass' ;;
            fail)           cls=bad;  text='Failure' ;;
            unknown)        cls=warn; text='Not sure' ;;
            not_applicable) cls=na;   text='Not applicable' ;;
            *)              cls=na;   text='Unrecorded' ;;
        esac
        printf '            <tr><td>%s</td><td><span class="pill %s">%s</span></td><td>%s</td></tr>\n' \
            "$(html_escape "$label")" "$cls" "$text" "$(html_escape "$detail")"
    done
}

count_tasks() {
    local i status
    TASK_TOTAL=0; TASK_DONE=0; TASK_FAILED=0; TASK_RUNNING=0; TASK_PENDING=0; TASK_SKIPPED=0
    if ((${#TASK_KEYS[@]} == 0)); then
        return 0
    fi
    for i in "${!TASK_KEYS[@]}"; do
        status="${TASK_STATUSES[$i]}"
        TASK_TOTAL=$((TASK_TOTAL + 1))
        case "$status" in
            success)                 TASK_DONE=$((TASK_DONE + 1)) ;;
            failure)                 TASK_FAILED=$((TASK_FAILED + 1)) ;;
            in_progress)             TASK_RUNNING=$((TASK_RUNNING + 1)) ;;
            skipped|not_applicable)  TASK_SKIPPED=$((TASK_SKIPPED + 1)) ;;
            *)                       TASK_PENDING=$((TASK_PENDING + 1)) ;;
        esac
    done
}

count_checks() {
    local i
    CHECK_PASS=0; CHECK_FAIL=0; CHECK_UNKNOWN=0; CHECK_NA=0; CHECK_TOTAL=0
    if ((${#CHECK_RESULTS[@]} == 0)); then
        return 0
    fi
    for i in "${!CHECK_RESULTS[@]}"; do
        CHECK_TOTAL=$((CHECK_TOTAL + 1))
        case "${CHECK_RESULTS[$i]}" in
            pass)           CHECK_PASS=$((CHECK_PASS + 1)) ;;
            fail)           CHECK_FAIL=$((CHECK_FAIL + 1)) ;;
            unknown)        CHECK_UNKNOWN=$((CHECK_UNKNOWN + 1)) ;;
            not_applicable) CHECK_NA=$((CHECK_NA + 1)) ;;
        esac
    done
}

portal_link() {
    local resource_path="$1"
    printf 'https://portal.azure.com/#@/resource/subscriptions/%s/resourceGroups/%s%s/overview' \
        "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$resource_path"
}

render_environment_links() {
    local rg_url app_url_portal acr_url app_metrics_url app_diagnostics_url defender_url reachable
    rg_url="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview"
    app_url_portal="$(portal_link "/providers/Microsoft.Web/sites/$APP_SERVICE_NAME")"
    acr_url="$(portal_link "/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME")"
    app_metrics_url="$(portal_link "/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/metrics")"
    app_diagnostics_url="$(portal_link "/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/diagnostics")"
    defender_url='https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade'

    if [[ "$COMMAND" == uninstall ]]; then
        printf '        <div class="item"><div class="label">Environment state</div><div class="value"><span class="pill na">Teardown requested</span><br>The dojo is being removed; its public URL will stop resolving.</div></div>\n'
        printf '        <div class="item"><div class="label">Resource group (portal)</div><div class="value"><a href="%s" target="_blank" rel="noopener">%s</a><br>Use this to confirm the deletion finished.</div></div>\n' \
            "$(html_escape "$rg_url")" "$(html_escape "$RESOURCE_GROUP")"
        printf '        <div class="item"><div class="label">Subscription resource groups</div><div class="value"><a href="https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups" target="_blank" rel="noopener">Browse all resource groups</a></div></div>\n'
        return 0
    fi

    if [[ -n "$APP_URL" ]]; then
        if [[ "$APP_HTTP_CODE" == 200 ]]; then
            reachable='<span class="pill ok">Active &amp; reachable</span>'
        elif [[ -z "$APP_HTTP_CODE" ]]; then
            reachable='<span class="pill warn">Not tested yet</span>'
        else
            reachable="<span class=\"pill bad\">Unreachable (HTTP $(html_escape "$APP_HTTP_CODE"))</span>"
        fi
        printf '        <div class="item"><div class="label">Live application</div><div class="value"><a href="%s" target="_blank" rel="noopener">%s</a><br>%s</div></div>\n' \
            "$(html_escape "$APP_URL")" "$(html_escape "$APP_URL")" "$reachable"
        printf '        <div class="item"><div class="label">Runtime status API</div><div class="value"><a href="%s/api/status" target="_blank" rel="noopener">/api/status</a> &middot; <a href="%s/health" target="_blank" rel="noopener">/health</a><br><span class="pill %s">health HTTP %s</span></div></div>\n' \
            "$(html_escape "$APP_URL")" "$(html_escape "$APP_URL")" \
            "$([[ "$HEALTH_HTTP_CODE" == 200 ]] && printf ok || printf warn)" \
            "$(html_escape "${HEALTH_HTTP_CODE:-not tested}")"
    elif [[ "$COMMAND" == plan || "$COMMAND" == doctor ]]; then
        printf '        <div class="item"><div class="label">Live application</div><div class="value"><span class="pill na">Not evaluated</span><br>This command never contacts the running site.</div></div>\n'
    else
        printf '        <div class="item"><div class="label">Live application</div><div class="value"><span class="pill na">Not published yet</span><br>The public URL appears once the App Service rollout completes.</div></div>\n'
    fi
    printf '        <div class="item"><div class="label">Resource group</div><div class="value"><a href="%s" target="_blank" rel="noopener">%s</a></div></div>\n' \
        "$(html_escape "$rg_url")" "$(html_escape "$RESOURCE_GROUP")"
    printf '        <div class="item"><div class="label">App Service (portal)</div><div class="value"><a href="%s" target="_blank" rel="noopener">%s</a></div></div>\n' \
        "$(html_escape "$app_url_portal")" "$(html_escape "$APP_SERVICE_NAME")"
    printf '        <div class="item"><div class="label">Container registry (portal)</div><div class="value"><a href="%s" target="_blank" rel="noopener">%s</a></div></div>\n' \
        "$(html_escape "$acr_url")" "$(html_escape "$ACR_NAME")"
    printf '        <div class="item"><div class="label">Monitoring (App Service)</div><div class="value"><a href="%s" target="_blank" rel="noopener">Metrics</a> &middot; <a href="%s" target="_blank" rel="noopener">Diagnose and solve problems</a><br><span class="hint">Runtime health, response time, failures, and platform diagnostics.</span></div></div>\n' \
        "$(html_escape "$app_metrics_url")" "$(html_escape "$app_diagnostics_url")"
    printf '        <div class="item"><div class="label">Defender for Cloud</div><div class="value"><a href="%s" target="_blank" rel="noopener">Security recommendations</a><br><span class="hint">Posture, vulnerabilities, and security findings for the subscription.</span></div></div>\n' \
        "$(html_escape "$defender_url")"
}

render_summary_counts() {
    printf '<div class="item"><div class="label">Tasks succeeded</div><div class="value">%s / %s</div></div>' "$TASK_DONE" "$TASK_TOTAL"
    printf '<div class="item"><div class="label">Tasks failed</div><div class="value">%s</div></div>' "$TASK_FAILED"
    printf '<div class="item"><div class="label">Checks passed</div><div class="value">%s / %s</div></div>' "$CHECK_PASS" "$CHECK_TOTAL"
    printf '<div class="item"><div class="label">Checks failed / not sure</div><div class="value">%s / %s</div></div>' "$CHECK_FAIL" "$CHECK_UNKNOWN"
}

render_run_facts() {
    printf '<div class="item"><div class="label">Scenario</div><div class="value">%s<br><code>%s</code></div></div>' "$(html_escape "$SCENARIO_NAME")" "$(html_escape "$SCENARIO_ID")"
    printf '<div class="item"><div class="label">Environment</div><div class="value">%s</div></div>' "$(html_escape "$ENVIRONMENT")"
    printf '<div class="item"><div class="label">Subscription</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$(mask_identifier "$SUBSCRIPTION_ID")")"
    printf '<div class="item"><div class="label">Resource group</div><div class="value">%s</div></div>' "$(html_escape "$RESOURCE_GROUP")"
    printf '<div class="item"><div class="label">Region</div><div class="value">%s</div></div>' "$(html_escape "$LOCATION")"
    printf '<div class="item"><div class="label">Registry</div><div class="value">%s</div></div>' "$(html_escape "$ACR_NAME")"
    printf '<div class="item"><div class="label">App Service</div><div class="value">%s</div></div>' "$(html_escape "$APP_SERVICE_NAME")"
    printf '<div class="item"><div class="label">Image</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$IMAGE_NAME:$IMAGE_TAG")"
    printf '<div class="item"><div class="label">Image digest</div><div class="value"><code>%s</code></div></div>' "$(html_escape "${IMAGE_DIGEST:-not resolved}")"
    printf '<div class="item"><div class="label">Build fingerprint</div><div class="value"><code>%s</code><br>%s</div></div>' "$(html_escape "${BUILD_FINGERPRINT:-not computed}")" "$1"
    printf '<div class="item"><div class="label">Training status</div><div class="value">%s on NGINX %s</div></div>' "$(html_escape "$VULNERABILITY_STATUS")" "$(html_escape "$NGINX_VERSION")"
    printf '<div class="item"><div class="label">Updated</div><div class="value">%s</div></div>' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

render_console_lines() {
    local line line_number total
    if [[ ! -s "$STATUS_RAW_CONSOLE" ]]; then
        printf '<div class="empty">Waiting for deployment output...</div>'
        return 0
    fi
    total="$(wc -l < "$STATUS_RAW_CONSOLE" 2>/dev/null || printf '0')"
    line_number=$(( total > 400 ? total - 400 : 0 ))
    while IFS= read -r line; do
        line_number=$((line_number + 1))
        printf '<div class="line"><span class="number">%s</span><span class="text">%s</span></div>' \
            "$line_number" "$(html_escape "$line")"
    done < <(tail -n 400 "$STATUS_RAW_CONSOLE")
    return 0
}

# Escape an HTML fragment for embedding in a JavaScript string literal.
# sed escapes per line (its N-join quits early on single-line input); awk then joins with literal \n.
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' -e 's|</|<\\/|g' \
        | awk 'BEGIN { ORS = "" } NR > 1 { printf "\\n" } { print }'
}

# Live feed for the report. fetch() is blocked on file:// origins, so the page polls this by
# injecting it as a <script>, which file:// does allow.
write_state_js() {
    local phase="$1" percent="$2" detail="$3" final="$4"
    local verdict="$5" verdict_class="$6" headline="$7" verdict_note="$8" build_badge="$9" steps_outcome="${10}"
    local current_task="${11}" current_task_state="${12}"
    local state_tmp
    [[ -n "$STATE_JS" ]] || return 0
    state_tmp="$STATE_JS.tmp"
    {
        printf 'window.npReport && window.npReport({'
        printf '"final":%s,' "$final"
        printf '"percent":%s,' "$percent"
        printf '"runStartedAt":%s,' "$RUN_STARTED_AT"
        printf '"phase":"%s",' "$(json_escape "$phase")"
        printf '"detail":"%s",' "$(json_escape "$detail")"
        printf '"currentTask":"%s",' "$(json_escape "$current_task")"
        printf '"currentTaskState":"%s",' "$(json_escape "$current_task_state")"
        printf '"headline":"%s",' "$(json_escape "$headline")"
        printf '"verdict":"%s",' "$(json_escape "$verdict")"
        printf '"verdictClass":"%s",' "$(json_escape "$verdict_class")"
        printf '"verdictNote":"%s",' "$(json_escape "$verdict_note")"
        printf '"elapsed":%s,' "$(( $(date +%s) - RUN_STARTED_AT ))"
        printf '"summaryHtml":"%s",' "$(json_escape "$(render_summary_counts)")"
        printf '"tasksHtml":"%s",' "$(json_escape "$(render_task_rows)")"
        printf '"checksHtml":"%s",' "$(json_escape "$(render_check_rows)")"
        printf '"linksHtml":"%s",' "$(json_escape "$(render_environment_links)")"
        printf '"factsHtml":"%s",' "$(json_escape "$(render_run_facts "$build_badge")")"
        printf '"auditHtml":"%s",' "$(json_escape "$(render_audit_facts)")"
        printf '"stepsHtml":"%s",' "$(json_escape "$(render_next_steps "$steps_outcome")")"
        printf '"consoleHtml":"%s"' "$(json_escape "$(render_console_lines)")"
        printf '});\n'
    } > "$state_tmp"
    publish_atomically "$state_tmp" "$STATE_JS"
}

render_audit_facts() {
    local ended="${RUN_ENDED_ISO:-in progress}"
    local registry_findings_label="Not audited yet"
    local cspm_machine_scan_label="Not audited yet"
    local cspm_api_posture_label="Not audited yet"
    local machine_scan_label="Not audited yet"
    local defender_connector_label="Not audited yet"
    local github_advanced_security_label="Not audited yet"
    case "$DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE" in
        true) registry_findings_label="On — audited" ;;
        false) registry_findings_label="Off — audited" ;;
        unknown) registry_findings_label="Not sure — audited" ;;
    esac
    case "$DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE" in
        true) cspm_machine_scan_label="On — audited" ;;
        false) cspm_machine_scan_label="Off — audited" ;;
        unknown) cspm_machine_scan_label="Not sure — audited" ;;
    esac
    case "$DEFENDER_CSPM_API_POSTURE_AUDIT_STATE" in
        true) cspm_api_posture_label="On — audited" ;;
        false) cspm_api_posture_label="Off — audited" ;;
        unknown) cspm_api_posture_label="Not sure — audited" ;;
    esac
    case "$DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE" in
        true) machine_scan_label="On — audited" ;;
        false) machine_scan_label="Off — audited" ;;
        unknown) machine_scan_label="Not sure — audited" ;;
    esac
    case "$DEFENDER_DEVOPS_CONNECTOR_STATE" in
        connected) defender_connector_label="On — audited" ;;
        authorization_required) defender_connector_label="Authorization required — audited" ;;
        unavailable) defender_connector_label="Not sure — audited" ;;
        not_expected) defender_connector_label="Not applicable — audited" ;;
    esac
    case "$GITHUB_ADVANCED_SECURITY_STATE" in
        enabled) github_advanced_security_label="On — audited" ;;
        disabled) github_advanced_security_label="Off — audited" ;;
        unknown) github_advanced_security_label="Not sure — audited" ;;
        not_expected) github_advanced_security_label="Not applicable — audited" ;;
    esac
    printf '<div class="item"><div class="label">Run ID</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$RUN_ID")"
    printf '<div class="item"><div class="label">Command</div><div class="value"><code>deploy.sh %s</code></div></div>' "$(html_escape "$RUN_INVOCATION")"
    printf '<div class="item"><div class="label">Started (UTC)</div><div class="value">%s</div></div>' "$(html_escape "$RUN_STARTED_ISO")"
    printf '<div class="item"><div class="label">Ended (UTC)</div><div class="value">%s</div></div>' "$(html_escape "$ended")"
    printf '<div class="item"><div class="label">Duration</div><div class="value">%s</div></div>' "$(format_duration "$(( $(date +%s) - RUN_STARTED_AT ))")"
    printf '<div class="item"><div class="label">Operator</div><div class="value">%s</div></div>' "$(html_escape "$RUN_OPERATOR")"
    printf '<div class="item"><div class="label">Origin</div><div class="value">%s<br><span class="hint">%s</span></div></div>' "$(html_escape "$RUN_ORIGIN")" "$(html_escape "$RUN_ORIGIN_DETAIL")"
    printf '<div class="item"><div class="label">Git branch</div><div class="value">%s</div></div>' "$(html_escape "$GIT_BRANCH")"
    printf '<div class="item"><div class="label">Git commit</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$GIT_COMMIT")"
    printf '<div class="item"><div class="label">Working tree</div><div class="value">%s</div></div>' "$(html_escape "$GIT_DIRTY")"
    printf '<div class="item"><div class="label">Tool version</div><div class="value">v%s (config v%s)</div></div>' "$(html_escape "$APP_VERSION")" "$(html_escape "$CONFIG_VERSION")"
    printf '<div class="item"><div class="label">Config source</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$(basename "$CONFIG_FILE")")"
    printf '<div class="item"><div class="label">Tenant</div><div class="value"><code>%s</code></div></div>' "$(html_escape "$(mask_identifier "$AZURE_TENANT_ID")")"
    printf '<div class="item"><div class="label">Subscription</div><div class="value">%s<br><code>%s</code></div></div>' "$(html_escape "${SUBSCRIPTION_NAME:-unknown}")" "$(html_escape "$(mask_identifier "$SUBSCRIPTION_ID")")"
    printf '<div class="item"><div class="label">Azure identity</div><div class="value">%s</div></div>' "$(html_escape "${AZURE_ACCOUNT_NAME:-not recorded}")"
    printf '<div class="item"><div class="label">Registry image security findings</div><div class="value">%s<br><span class="hint">Defender for Containers: ContainerRegistriesVulnerabilityAssessments</span></div></div>' "$(html_escape "$registry_findings_label")"
    printf '<div class="item"><div class="label">CSPM agentless scanning for machines</div><div class="value">%s<br><span class="hint">Defender CSPM: AgentlessVmScanning</span></div></div>' "$(html_escape "$cspm_machine_scan_label")"
    printf '<div class="item"><div class="label">CSPM API Security Posture</div><div class="value">%s<br><span class="hint">Defender CSPM: ApiPosture</span></div></div>' "$(html_escape "$cspm_api_posture_label")"
    printf '<div class="item"><div class="label">Agentless scanning for machines</div><div class="value">%s<br><span class="hint">Defender for Containers: AgentlessVmScanning</span></div></div>' "$(html_escape "$machine_scan_label")"
    printf '<div class="item"><div class="label">Defender GitHub connector</div><div class="value">%s<br><span class="hint">Defender for Cloud DevOps connector</span></div></div>' "$(html_escape "$defender_connector_label")"
    printf '<div class="item"><div class="label">GitHub Advanced Security</div><div class="value">%s<br><span class="hint">GitHub repository security_and_analysis</span></div></div>' "$(html_escape "$github_advanced_security_label")"
}

command_noun() {
    case "$COMMAND" in
        uninstall)              printf 'teardown' ;;
        wizard)                 printf 'management wizard' ;;
        doctor)                 printf 'preflight' ;;
        plan)                   printf 'dry run' ;;
        verify)                 printf 'verification' ;;
        provision)              printf 'provisioning' ;;
        build)                  printf 'image build' ;;
        rollout)                printf 'rollout' ;;
        repair)                 printf 'repair' ;;
        *)                      printf 'deployment' ;;
    esac
}

render_next_steps() {
    local outcome="$1" app_metrics_url
    app_metrics_url="$(portal_link "/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/metrics")"
    if [[ "$outcome" == failure ]]; then
        cat <<EOF
        <li><strong>Read the failure detail above</strong>, then open the <a href="deployment-$ENVIRONMENT.console.html">full console stream</a> and <a href="deployment-$ENVIRONMENT.log"><code>deployment-$ENVIRONMENT.log</code></a> for the raw Azure CLI error.</li>
        <li>Re-run preflight only: <code>scripts/deploy.sh doctor --environment $ENVIRONMENT --defaults</code></li>
        <li>Re-run the failed command once the cause is fixed: <code>scripts/deploy.sh $COMMAND --environment $ENVIRONMENT --defaults</code></li>
        <li>If Azure resources are in a half-built state, repair them: <code>scripts/deploy.sh repair --environment $ENVIRONMENT --defaults</code></li>
        <li>If the container will not start, tail its logs: <code>az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_SERVICE_NAME</code></li>
        <li>As a last resort, tear down and start clean: <code>scripts/deploy.sh uninstall --environment $ENVIRONMENT --yes</code></li>
EOF
        return 0
    fi
    if [[ "$outcome" != success ]]; then
        cat <<EOF
        <li>Keep this tab open &mdash; it refreshes every 3 seconds and keeps your scroll position.</li>
        <li>Watch the <a href="deployment-$ENVIRONMENT.console.html">live console stream</a> for raw Azure CLI output.</li>
        <li>The verification matrix and any public URLs fill in as the run reaches those stages.</li>
        <li>Do not interrupt the run; a partial provision leaves Azure resources behind that must be cleaned up with <code>scripts/deploy.sh uninstall</code>.</li>
EOF
        return 0
    fi

    case "$COMMAND" in
        plan)
            cat <<EOF
        <li>Nothing was changed. This was a dry run of the resolved settings only.</li>
        <li><strong>Validate the template against Azure</strong>: <code>scripts/deploy.sh doctor --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Deploy for real</strong>: <code>scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
        <li>Override any resolved value with <code>--location</code>, <code>--resource-group</code>, <code>--registry-name</code>, or <code>--app-service-name</code>.</li>
EOF
            ;;
        doctor)
            cat <<EOF
        <li>No Azure resources were changed. The template compiles and the predicted change set is in <code>doctor-whatif-$ENVIRONMENT.txt</code>.</li>
        <li><strong>Review the what-if output</strong> above before applying anything to a live environment.</li>
        <li><strong>Apply the infrastructure only</strong>: <code>scripts/deploy.sh provision --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Run the full lifecycle</strong>: <code>scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
EOF
            ;;
        uninstall)
            cat <<EOF
        <li><strong>Confirm the teardown</strong> in the <a href="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview" target="_blank" rel="noopener">resource group blade</a>; deletion is asynchronous and can take several minutes.</li>
        <li><strong>Verify from the CLI</strong>: <code>az group exists --name $RESOURCE_GROUP</code> should return <code>false</code>.</li>
        <li>Use <code>--no-wait</code> only when a caller intentionally needs asynchronous cleanup without deletion verification.</li>
        <li><strong>Rebuild the dojo later</strong>: <code>scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
        <li>The GitHub OIDC federated credentials are not deleted by uninstall; remove them separately if this environment is retiring for good.</li>
EOF
            ;;
        provision)
            cat <<EOF
        <li>Infrastructure exists but no application image has been published yet.</li>
        <li><strong>Build and publish</strong>: <code>scripts/deploy.sh build --environment $ENVIRONMENT --defaults</code> then <code>scripts/deploy.sh rollout --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Or do both at once</strong>: <code>scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Inspect what was created</strong> in the <a href="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview" target="_blank" rel="noopener">resource group</a>.</li>
EOF
            ;;
        build)
            cat <<EOF
        <li>The image is in the registry but App Service has not been repointed at it.</li>
        <li><strong>Publish it</strong>: <code>scripts/deploy.sh rollout --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Inspect the tags</strong>: <code>az acr repository show-tags --name $ACR_NAME --repository $IMAGE_NAME --orderby time_desc</code></li>
        <li>Rebuilding with the same source is a no-op; use <code>--force-rebuild</code> if you need to force fresh layers.</li>
EOF
            ;;
        verify)
            cat <<EOF
        <li>Nothing was changed &mdash; this was a read-only verification pass.</li>
        <li><strong>Open the dojo</strong> at <a href="${APP_URL:-#}" target="_blank" rel="noopener">${APP_URL:-the App Service URL}</a>.</li>
        <li><strong>Run the automated smoke tests</strong>: <code>scripts/test.sh</code></li>
        <li>If a check came back <em>Not sure</em>, the evidence column above explains what could not be determined and why.</li>
EOF
            ;;
        *)
            cat <<EOF
        <li><strong>Open the dojo</strong> at <a href="${APP_URL:-#}" target="_blank" rel="noopener">${APP_URL:-the App Service URL}</a> and confirm the landing page renders.</li>
        <li><strong>Monitor the environment</strong> from <a href="$(html_escape "$app_metrics_url")" target="_blank" rel="noopener">App Service Metrics</a> and review security findings in <a href="https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade" target="_blank" rel="noopener">Defender for Cloud</a>.</li>
        <li><strong>Exercise the CVE scenario</strong>: query <code>/api/status</code> and use <code>vulnerability.detected</code>, <code>detection_reason</code>, and <code>runtime_verification</code> as the authoritative evidence for CVE-2026-42533.</li>
        <li><strong>Run the automated smoke tests</strong>: <code>scripts/test.sh</code></li>
        <li><strong>Re-verify at any time without redeploying</strong>: <code>scripts/deploy.sh verify --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Re-running deploy is cheap</strong>: the build context is fingerprinted, so an unchanged image is neither rebuilt nor re-uploaded and a healthy App Service is not restarted. Force a full rebuild with <code>--force-rebuild</code>.</li>
        <li><strong>Rotate the scenario</strong>: <code>VULNERABILITY_STATUS=patched scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Review cost and exposure</strong> in the <a href="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview" target="_blank" rel="noopener">resource group</a>. This environment is intentionally vulnerable &mdash; keep it isolated and delete it when the exercise ends: <code>scripts/deploy.sh uninstall --environment $ENVIRONMENT --yes</code></li>
EOF
            ;;
    esac
}

print_final_banner() {
    local result="$1" color label
    if [[ "$result" == failure ]]; then
        color="$RED"
        label="FAILED"
    else
        color="$GREEN"
        label="COMPLETE"
    fi
    echo
    echo -e "${color}==================================================================${NC}"
    echo -e "${color}  $COMMAND ($ENVIRONMENT): $label${NC}"
    echo -e "${color}==================================================================${NC}"
    if [[ -n "$STATUS_HTML" ]]; then
        echo -e "  Executive report : ${CYAN:-\033[0;36m}$(report_url "$STATUS_HTML")${NC}"
        echo    "  Report file      : $(native_path "$STATUS_HTML")"
    fi
    if [[ -n "$APP_URL" ]]; then
        echo -e "  Live application : ${CYAN:-\033[0;36m}$APP_URL${NC}"
    fi
    if [[ -n "$OUTPUT_DIR" ]]; then
        echo    "  Output directory : $(native_path "$OUTPUT_DIR")"
    fi
    echo    "  Run ID           : $RUN_ID"
    echo    "  Started (UTC)    : $RUN_STARTED_ISO"
    echo    "  Ended (UTC)      : ${RUN_ENDED_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    echo    "  Operator/origin  : $RUN_OPERATOR via $RUN_ORIGIN"
    echo    "  Version          : v$APP_VERSION (config v$CONFIG_VERSION), commit ${GIT_COMMIT:0:12} on $GIT_BRANCH"
    echo -e "  ${YELLOW}USE AT YOUR OWN RISK${NC} - intentionally vulnerable training environment."
    echo    "  $(project_meta copyright 'Copyright (c) Ninja Paws') - Licensed under $(project_meta license MIT)"
    echo
    return 0
}

finalize_report() {
    local result="$1" detail="${2:-}" percent=100
    if [[ "$RUN_FINAL" == true ]]; then
        return 0
    fi
    RUN_FINAL=true
    RUN_RESULT="$result"
    RUN_ENDED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$result" == failure ]]; then
        percent="$(auto_percent)"
        write_status_html complete failed "$percent" "$detail"
    else
        write_status_html complete success 100 "$detail"
    fi
    print_final_banner "$result"
}

on_exit() {
    local exit_code="$?"
    trap - EXIT
    if [[ -z "$STATUS_HTML" || "$RUN_FINAL" == true ]]; then
        exit "$exit_code"
    fi
    if ((exit_code != 0)); then
        if [[ -n "$CURRENT_TASK" ]]; then
            set_task "$CURRENT_TASK" failure "${FAILURE_MESSAGE:-Stage aborted with exit code $exit_code.}"
        fi
        finalize_report failure "${FAILURE_MESSAGE:-The run stopped with exit code $exit_code. See the console stream for the underlying Azure CLI error.}"
    fi
    exit "$exit_code"
}

write_status_html() {
        local phase="$1"
        local status="$2"
        local percent="$3"
        local detail="${4:-}"
        local final=false verdict verdict_class verdict_note headline build_badge live_badge total_since_attr
        local total_elapsed report_tmp steps_outcome current_task current_task_state task_index_value
        [[ -n "$STATUS_HTML" ]] || return 0
        printf '[%s] %s: %s\n' "$(date -u +%H:%M:%SZ)" "$phase" "$detail" >> "$STATUS_RAW_CONSOLE"
        if [[ "$status" == running || "$status" == starting || "$status" == waiting ]]; then
            CONSOLE_AUTORELOAD=true
            live_badge=' <span class="pill run" id="refresh-badge">Live</span>'
            total_since_attr=" data-since=\"$RUN_STARTED_AT\""
        else
            CONSOLE_AUTORELOAD=false
            final=true
            live_badge=''
            total_since_attr=''
        fi
        if [[ "$status" == failed ]]; then
            steps_outcome=failure
        elif [[ "$final" == true ]]; then
            steps_outcome=success
        else
            steps_outcome=progress
        fi
        current_task="No task is currently running."
        current_task_state=idle
        if [[ -n "$CURRENT_TASK" ]]; then
            task_index_value="$(task_index "$CURRENT_TASK")"
            if [[ "$task_index_value" != -1 ]]; then
                current_task="${TASK_LABELS[task_index_value]}"
                current_task_state="${TASK_STATUSES[task_index_value]}"
            fi
        fi
        write_console_html
        print_terminal_status "$phase" "$status" "$percent" "$detail"

        count_tasks
        count_checks
        total_elapsed=$(( $(date +%s) - RUN_STARTED_AT ))

        if [[ -z "$BUILD_FINGERPRINT" ]]; then
            build_badge='<span class="pill idle">Not evaluated</span>'
        elif [[ "$BUILD_SKIPPED" == true ]]; then
            build_badge='<span class="pill na">Unchanged &middot; rebuild and upload skipped</span>'
        else
            build_badge='<span class="pill ok">Changed &middot; rebuilt and pushed</span>'
        fi

        if [[ "$status" == failed ]]; then
            verdict="Failed"
            verdict_class="bad"
            headline="Executive report &middot; $(command_noun) failed"
            verdict_note="$TASK_DONE of $TASK_TOTAL lifecycle tasks completed before the run stopped. $TASK_FAILED task(s) failed."
        elif [[ "$final" == true ]]; then
            if ((CHECK_FAIL > 0)); then
                verdict="Completed with failures"
                verdict_class="bad"
            elif ((CHECK_UNKNOWN > 0)); then
                verdict="Completed with warnings"
                verdict_class="warn"
            else
                verdict="Verified"
                verdict_class="ok"
            fi
            headline="Executive report &middot; $(command_noun) complete"
            verdict_note="$TASK_DONE of $TASK_TOTAL lifecycle tasks succeeded, $TASK_SKIPPED skipped or not applicable. Verification: $CHECK_PASS pass, $CHECK_FAIL failure, $CHECK_UNKNOWN not sure, $CHECK_NA not applicable."
        else
            verdict="In progress"
            verdict_class="run"
            headline="Executive progress report"
            verdict_note="$TASK_DONE of $TASK_TOTAL lifecycle tasks complete, $TASK_RUNNING running, $TASK_PENDING queued, $TASK_SKIPPED skipped, $TASK_FAILED failed."
        fi

        mkdir -p "$(dirname "$STATUS_HTML")"
        report_tmp="$STATUS_HTML.tmp"
        cat > "$report_tmp" <<EOF
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ninja Paws Deployment - $(html_escape "$ENVIRONMENT")</title>
    <style>
        :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #eef3f8; color: #152238; }
        body { margin: 0; padding: 32px; background: radial-gradient(circle at 85% 0%, #cde7f2 0, transparent 35%), #eef3f8; }
        main { max-width: 1040px; margin: auto; }
        header, section { background: #fff; border: 1px solid #dbe3ee; border-radius: 14px; box-shadow: 0 8px 24px #17203312; }
        header { padding: 28px; margin-bottom: 18px; border-top: 5px solid #d98932; }
        .brand { display: flex; align-items: center; gap: 12px; color: #102f4d; letter-spacing: .08em; font-size: 13px; }
        .brand small { display: block; color: #77869a; font-size: 9px; letter-spacing: .16em; margin-top: 3px; }
        .mark { display: grid; place-items: center; width: 44px; height: 44px; border-radius: 12px 12px 12px 4px; background: #102f4d; color: #f2a24a; font-weight: 800; letter-spacing: 0; }
        h1 { margin: 24px 0 8px; font-size: 30px; }
        h2 { margin: 0 0 6px; font-size: 18px; }
        p { margin: 6px 0; color: #5b6678; }
        section { padding: 22px; margin: 18px 0; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px; }
        .item { background: #f7f9fc; border-radius: 10px; padding: 14px; }
        .label { color: #68758a; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
        .value { margin-top: 5px; font-weight: 650; overflow-wrap: anywhere; }
        .progress-stack { display: grid; gap: 16px; margin-top: 14px; }
        .progress-label { display: flex; justify-content: space-between; gap: 12px; color: #5b6678; font-size: 13px; }
        .progress-label strong { color: #152238; }
        .bar { height: 14px; background: #e7edf5; border-radius: 99px; overflow: hidden; margin: 7px 0 0; }
        .fill { height: 100%; width: ${percent}%; background: linear-gradient(90deg, #1769aa, #27a36a); transition: width .4s ease; }
        .current-fill { width: 0; background: #b9c6d5; }
        .current-fill.in_progress { width: 72%; background: linear-gradient(90deg, #1769aa, #50a6d8, #1769aa); background-size: 200% 100%; animation: task-progress 1.5s linear infinite; }
        .current-fill.success { width: 100%; background: #27a36a; }
        .current-fill.failure { width: 100%; background: #d64545; }
        @keyframes task-progress { to { background-position: -200% 0; } }
        .console { background: #101b2d; color: #d9e7f5; border-radius: 10px; padding: 16px; max-height: 280px; overflow: auto; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 12px; line-height: 1.55; }
        iframe { display: block; width: 100%; height: 420px; border: 0; border-radius: 10px; background: #101b2d; overflow: hidden; }
        code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 13px; background: #eef2f8; padding: 1px 5px; border-radius: 5px; }
        a { color: #1769aa; }
        .pill { display: inline-block; padding: 4px 10px; border-radius: 99px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; font-size: 11px; white-space: nowrap; }
        .pill.ok { background: #e7f5ee; color: #176b43; }
        .pill.bad { background: #fdeaea; color: #a02020; }
        .pill.warn { background: #fdf3e0; color: #8a5a10; }
        .pill.run { background: #e6f0fb; color: #14548c; }
        .pill.idle { background: #eef1f6; color: #5d6a7d; }
        .pill.na { background: #f0eef6; color: #5b4f80; }
        .verdict { font-size: 15px; padding: 7px 16px; }
        .task { display: grid; grid-template-columns: 34px 1fr auto; align-items: center; gap: 12px; padding: 12px 14px; border: 1px solid #e4eaf3; border-left-width: 4px; border-radius: 10px; margin-bottom: 8px; background: #fbfcfe; }
        .task.ok { border-left-color: #27a36a; }
        .task.bad { border-left-color: #d64545; background: #fffafa; }
        .task.run { border-left-color: #1769aa; background: #f7fbff; }
        .task.idle { border-left-color: #c8d2e0; }
        .task.na { border-left-color: #a99cd0; }
        .task-name { font-weight: 650; }
        .task-detail { color: #5b6678; font-size: 13px; margin-top: 2px; overflow-wrap: anywhere; }
        .task-meta { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; }
        .elapsed { color: #7b8798; font-size: 11px; font-variant-numeric: tabular-nums; }
        .ico { display: grid; place-items: center; width: 26px; height: 26px; border-radius: 50%; font-weight: 800; font-size: 14px; }
        .ico.ok { background: #27a36a; color: #fff; }
        .ico.bad { background: #d64545; color: #fff; }
        .ico.idle { background: #eef1f6; color: #7b8798; }
        .ico.na { background: #efecf7; color: #5b4f80; }
        .ico.run.spinner { background: transparent; border: 3px solid #cfe0f2; border-top-color: #1769aa; animation: spin .8s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }
        table { width: 100%; border-collapse: collapse; font-size: 14px; }
        th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #e7edf5; vertical-align: top; overflow-wrap: anywhere; }
        th { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #68758a; }
        ol.steps li, ul.steps li { margin-bottom: 10px; color: #3c4759; }
        .banner { padding: 14px 16px; border-radius: 10px; background: #fdeaea; border: 1px solid #f3c9c9; color: #7d1f1f; margin-top: 14px; }
        .console-panel { background: #101b2d; color: #d9e7f5; border-radius: 10px; padding: 10px 0; height: 420px; overflow: auto; overscroll-behavior: contain; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 12px; line-height: 1.55; }
        .console-panel .line { display: grid; grid-template-columns: 56px 1fr; border-bottom: 1px solid #ffffff0b; }
        .console-panel .number { padding: 3px 10px; color: #58718b; text-align: right; user-select: none; }
        .console-panel .text { padding: 3px 14px; white-space: pre-wrap; overflow-wrap: anywhere; }
        .console-panel .empty { color: #58718b; padding: 24px; text-align: center; }
        .actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-top: 16px; }
        button.pdf { font: inherit; font-weight: 700; cursor: pointer; border: 0; border-radius: 10px; padding: 12px 20px; background: #102f4d; color: #fff; box-shadow: 0 6px 16px #102f4d33; }
        button.pdf:hover { background: #17436e; }
        .hint { color: #77869a; font-size: 13px; }
        footer { margin: 24px 0 8px; padding: 20px 22px; border-top: 3px solid #d98932; background: #fff; border-radius: 14px; border: 1px solid #dbe3ee; }
        footer p { margin: 5px 0; font-size: 12px; color: #68758a; }
        footer .disclaimer { color: #7d1f1f; background: #fdeaea; border: 1px solid #f3c9c9; border-radius: 8px; padding: 10px 12px; font-size: 12px; }
        .print-only { display: none; }
        @media (max-width: 600px) { body { padding: 14px; } h1 { font-size: 23px; } .task { grid-template-columns: 28px 1fr; } .task-meta { grid-column: 2; align-items: flex-start; } }
        @media print {
            @page { size: A4; margin: 14mm 12mm; }
            :root, body { background: #fff !important; }
            body { padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            main { max-width: none; }
            header, section { box-shadow: none; border: 1px solid #d4dbe6; border-radius: 8px; break-inside: avoid; page-break-inside: avoid; }
            header { padding: 16px; margin-bottom: 10px; }
            section { padding: 14px; margin: 10px 0; }
            h1 { font-size: 21px; margin: 12px 0 6px; }
            h2 { font-size: 15px; }
            p, td, th, li { font-size: 11px; }
            .task { break-inside: avoid; page-break-inside: avoid; padding: 8px 10px; margin-bottom: 5px; }
            .ico.run.spinner { animation: none; border-top-color: #1769aa; }
            thead { display: table-header-group; }
            tr { break-inside: avoid; page-break-inside: avoid; }
            .no-print { display: none !important; }
            .print-only { display: block; }
            .grid { grid-template-columns: repeat(3, 1fr); }
            a { color: #14548c; text-decoration: none; }
        }
    </style>
</head>
<body>
<main>
    <header>
        <div class="brand"><span class="mark">NP</span><span><strong>NINJA PAWS</strong><small> CLOUD SECURITY DOJO</small></span></div>
        <h1 id="headline">$headline</h1>
        <p>Azure lifecycle command <code>$(html_escape "$COMMAND")</code> targeting environment <strong>$(html_escape "$ENVIRONMENT")</strong>.</p>
        <p><span class="pill $verdict_class verdict" id="verdict-pill">$(html_escape "$verdict")</span></p>
        <p id="verdict-note">$verdict_note</p>
        <p class="print-only">Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) &middot; subscription $(html_escape "$(mask_identifier "$SUBSCRIPTION_ID")")</p>
    </header>

    <section>
        <h2>Executive summary</h2>
        <div class="progress-stack">
            <div>
                <div class="progress-label"><span><strong>Overall lifecycle</strong> &middot; <span id="progress-percent">${percent}%</span></span><span>elapsed <span id="total-elapsed"$total_since_attr>$(format_duration "$total_elapsed")</span>$live_badge</span></div>
                <div class="bar"><div class="fill" id="progress-fill"></div></div>
            </div>
            <div>
                <div class="progress-label"><span><strong>Current task</strong></span><span id="current-task-name">$(html_escape "$current_task")</span></div>
                <div class="bar"><div class="fill current-fill $current_task_state" id="current-task-fill"></div></div>
            </div>
        </div>
        <p>Current phase <strong id="phase-name">$(html_escape "$phase")</strong>.</p>
        <p id="phase-detail">$(html_escape "$detail")</p>
        <div class="grid" style="margin-top:14px" id="summary-counts">$(render_summary_counts)</div>
        <div id="failure-banner">$( [[ "$status" == failed ]] && printf '<div class="banner"><strong>Failure cause:</strong> %s</div>' "$(html_escape "${FAILURE_MESSAGE:-$detail}")" )</div>
    </section>

    <section>
        <h2>Task list</h2>
        <p>Every stage in this run, with its live state and duration.</p>
        <div id="task-list">
$(render_task_rows)
        </div>
    </section>

    <section>
        <h2>Verification matrix</h2>
        <p>Each check is recorded as Pass, Failure, Not sure, or Not applicable with the evidence used to decide.</p>
        <table>
            <thead><tr><th style="width:32%">Check</th><th style="width:14%">Result</th><th>Evidence</th></tr></thead>
            <tbody id="check-rows">
$(render_check_rows)
            </tbody>
        </table>
    </section>

    <section>
        <h2>Environment access</h2>
        <p>Clickable entry points for the deployed environment and its Azure resources.</p>
        <div class="grid" id="env-links">
$(render_environment_links)
        </div>
    </section>

    <section>
        <h2>Run facts</h2>
        <div class="grid" id="run-facts">$(render_run_facts "$build_badge")</div>
    </section>

    <section>
        <h2>Next steps</h2>
        <ul class="steps" id="next-steps">
$(render_next_steps "$steps_outcome")
        </ul>
    </section>

    <section>
        <h2>Audit trail</h2>
        <p>Provenance for this run, retained alongside the archived report under <code>output/archive/</code>.</p>
        <div class="grid" id="audit-facts">$(render_audit_facts)</div>
    </section>

    <section class="no-print">
        <h2>Live console</h2>
        <p>Raw terminal stream, last 400 lines. Scroll inside the panel to read back; it snaps to the newest line unless you scroll up.</p>
        <div class="console-panel" id="console-panel"><div id="console-lines">$(render_console_lines)</div></div>
    </section>

    <section>
        <h2>Report</h2>
        <p class="print-only">Raw console output is excluded from this PDF. See the diagnostics files listed below.</p>
        <div class="actions no-print">
            <button type="button" class="pdf" id="pdf-button">Generate PDF</button>
            <span class="hint">Opens your browser's print dialog &mdash; choose <strong>Save as PDF</strong>. Always reflects the latest data on screen.</span>
        </div>
        <p>Azure CLI log: <a href="deployment-$ENVIRONMENT.log"><code>deployment-$ENVIRONMENT.log</code></a></p>
        <p>State manifest: <a href="deployment-$ENVIRONMENT.json"><code>deployment-$ENVIRONMENT.json</code></a></p>
        <p>Console stream: <a href="deployment-$ENVIRONMENT.console.html"><code>deployment-$ENVIRONMENT.console.html</code></a></p>
        <p id="live-note">$( [[ "$final" == true ]] && printf 'This is the final report for the run; live updates have stopped.' || printf 'This page updates itself in place every 2 seconds. It never reloads, so your scroll position and the PDF button stay put.' )</p>
    </section>

    <footer>
        <p class="disclaimer"><strong>USE AT YOUR OWN RISK.</strong> $(html_escape "$(project_meta disclaimer 'Provided as-is, without warranty of any kind.')")</p>
        <p>$(html_escape "$(project_meta name 'Ninja Paws Cloud Security Dojo')") v$(html_escape "$APP_VERSION") &middot; $(html_escape "$(project_meta copyright 'Copyright (c) Ninja Paws')") &middot; Licensed under $(html_escape "$(project_meta license MIT)")</p>
        <p>Author: $(html_escape "$(project_meta author 'Ninja Paws')") &middot; <a href="$(html_escape "$(project_meta repository '')")">Source repository</a> &middot; <a href="$(html_escape "$(project_meta support '')")">Report an issue</a></p>
        <p>Report generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by <code>scripts/deploy.sh</code> &middot; run <code>$(html_escape "$RUN_ID")</code> &middot; commit <code>$(html_escape "${GIT_COMMIT:0:12}")</code></p>
        <p class="print-only">This document is a point-in-time snapshot. Verify against the live environment before relying on it for audit evidence.</p>
    </footer>
</main>
<script>
(function () {
    var ENV = '$ENVIRONMENT';
    var POLL_MS = 2000;
    var finished = $final;

    function byId(id) { return document.getElementById(id); }
    function setHtml(id, html) {
        var el = byId(id);
        if (el && typeof html === 'string' && el.innerHTML !== html) { el.innerHTML = html; }
    }
    function setText(id, text) {
        var el = byId(id);
        if (el && typeof text === 'string' && el.textContent !== text) { el.textContent = text; }
    }

    function humanise(seconds) {
        var minutes = Math.floor(seconds / 60);
        var rest = seconds % 60;
        return minutes + 'm ' + (rest < 10 ? '0' : '') + rest + 's';
    }
    function tickDurations() {
        var now = Math.floor(Date.now() / 1000);
        var timers = document.querySelectorAll('[data-since]');
        for (var i = 0; i < timers.length; i++) {
            var since = parseInt(timers[i].getAttribute('data-since'), 10);
            if (since > 0) { timers[i].textContent = humanise(Math.max(0, now - since)); }
        }
    }
    window.setInterval(tickDurations, 1000);

    // Keep the console pinned to the newest line unless the reader scrolled up.
    var panel = byId('console-panel');
    var pinned = true;
    if (panel) {
        panel.addEventListener('scroll', function () {
            pinned = panel.scrollHeight - panel.scrollTop - panel.clientHeight < 24;
        }, { passive: true });
        panel.scrollTop = panel.scrollHeight;
    }

    window.npReport = function (state) {
        setHtml('headline', state.headline);
        setHtml('verdict-note', state.verdictNote);
        var pill = byId('verdict-pill');
        if (pill) {
            pill.className = 'pill ' + state.verdictClass + ' verdict';
            pill.textContent = state.verdict;
        }
        var fill = byId('progress-fill');
        if (fill) { fill.style.width = state.percent + '%'; }
        setText('progress-percent', state.percent + '%');
        setText('current-task-name', state.currentTask);
        var currentTaskFill = byId('current-task-fill');
        if (currentTaskFill) { currentTaskFill.className = 'fill current-fill ' + state.currentTaskState; }
        setText('phase-name', state.phase);
        setText('phase-detail', state.detail);
        setHtml('summary-counts', state.summaryHtml);
        setHtml('task-list', state.tasksHtml);
        setHtml('check-rows', state.checksHtml);
        setHtml('env-links', state.linksHtml);
        setHtml('run-facts', state.factsHtml);
        setHtml('audit-facts', state.auditHtml);
        setHtml('next-steps', state.stepsHtml);

        if (panel) {
            var lines = byId('console-lines');
            if (lines && lines.innerHTML !== state.consoleHtml) {
                lines.innerHTML = state.consoleHtml;
                if (pinned) { panel.scrollTop = panel.scrollHeight; }
            }
        }

        var elapsed = byId('total-elapsed');
        if (elapsed && !state.final) { elapsed.setAttribute('data-since', String(state.runStartedAt)); }
        tickDurations();

        if (state.final && !finished) {
            finished = true;
            var badge = byId('refresh-badge');
            if (badge) { badge.parentNode.removeChild(badge); }
            if (elapsed) { elapsed.removeAttribute('data-since'); elapsed.textContent = humanise(state.elapsed); }
            setText('live-note', 'This is the final report for the run; live updates have stopped.');
        }
    };

    function poll() {
        if (finished) { return; }
        var s = document.createElement('script');
        s.src = 'deployment-' + ENV + '.state.js?t=' + Date.now();
        s.onload = s.onerror = function () {
            if (s.parentNode) { s.parentNode.removeChild(s); }
            window.setTimeout(poll, POLL_MS);
        };
        document.body.appendChild(s);
    }
    if (!finished) { window.setTimeout(poll, POLL_MS); }

    var badge = byId('refresh-badge');
    if (badge && !finished) {
        var remaining = POLL_MS / 1000;
        window.setInterval(function () {
            remaining = remaining > 0 ? remaining - 1 : POLL_MS / 1000;
            badge.textContent = 'Live \u00b7 updating';
        }, 1000);
    }

    var pdf = byId('pdf-button');
    if (pdf) { pdf.addEventListener('click', function () { window.print(); }); }
})();
</script>
</body>
</html>
EOF
        publish_atomically "$report_tmp" "$STATUS_HTML"
        write_state_js "$phase" "$percent" "$detail" "$final" "$verdict" "$verdict_class" "$headline" "$verdict_note" "$build_badge" "$steps_outcome" "$current_task" "$current_task_state"
}

write_state() {
    local phase="$1"
    local status="$2"
    local message="${3:-}"
    mkdir -p "$OUTPUT_DIR"
    cat > "$STATE_FILE" <<EOF
{
    "environment": "$ENVIRONMENT",
    "scenarioId": "$SCENARIO_ID",
    "scenarioName": "$SCENARIO_NAME",
    "subscriptionId": "$(mask_identifier "$SUBSCRIPTION_ID")",
    "tenantId": "$(mask_identifier "$AZURE_TENANT_ID")",
  "resourceGroup": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "registryName": "$ACR_NAME",
  "appServiceName": "$APP_SERVICE_NAME",
  "imageName": "$IMAGE_NAME",
  "imageTag": "$IMAGE_TAG",
  "imageDigest": "$IMAGE_DIGEST",
  "buildFingerprint": "$BUILD_FINGERPRINT",
  "buildSkipped": $BUILD_SKIPPED,
  "rolloutSkipped": $ROLLOUT_SKIPPED,
  "phase": "$phase",
  "status": "$status",
  "message": "$message",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

resolve_settings() {
    resolve_scenario
    if [[ "$ENVIRONMENT" == auto ]]; then
        local branch_name
        branch_name="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || true)}"
        ENVIRONMENT="$(environment_for_branch "$branch_name")" || fail "Cannot detect deployment environment from Git branch '$branch_name'. Use --environment dev or --environment prod."
    fi

    case "$ENVIRONMENT" in
        dev|prod) ;;
        *) fail "--environment must be dev, prod, or auto." ;;
    esac
    LOCATION="${LOCATION:-$(config_setting location centralus)}"
    RESOURCE_GROUP="${RESOURCE_GROUP:-$(config_setting resourceGroup "")}"
    REGISTRY_NAME="${REGISTRY_NAME:-$(config_setting registryName "")}"
    APP_SERVICE_NAME="${APP_SERVICE_NAME:-$(config_setting appServiceName "")}"
    APP_SERVICE_PLAN_SKU="${APP_SERVICE_PLAN_SKU:-$(config_setting appServicePlanSku B2)}"
    IMAGE_NAME="${IMAGE_NAME:-$(config_setting imageName ninjapaws-dojo)}"
    BASE_OS_IMAGE="${BASE_OS_IMAGE:-$(config_setting baseOsImage ubuntu)}"
    BASE_OS_VERSION="${BASE_OS_VERSION:-$(config_setting baseOsVersion 24.04)}"
    NGINX_VERSION="${NGINX_VERSION:-$(config_setting nginxVersion 1.30.3)}"
    NODE_MAJOR_VERSION="${NODE_MAJOR_VERSION:-$(config_setting nodeMajorVersion 20)}"
    VULNERABILITY_STATUS="${VULNERABILITY_STATUS:-$(config_setting vulnerabilityStatus vulnerable)}"
    PORT="${PORT:-$(config_setting port 3000)}"
    NPM_REGISTRY_URL="${NPM_REGISTRY_URL:-$(config_setting npmRegistryUrl https://registry.npmjs.org)}"
    NPM_USE_MIRROR="${NPM_USE_MIRROR:-$(config_setting npmUseMirror true)}"
    NPM_NETWORK_MODE="${NPM_NETWORK_MODE:-$(config_setting npmNetworkMode online)}"
    DEFENDER_ENABLED="${DEFENDER_ENABLED:-$(config_setting defenderEnabled true)}"
    DEFENDER_SCAN_ENABLED="${DEFENDER_SCAN_ENABLED:-$(config_setting defender.scanAfterVerify true)}"
    DEFENDER_MANAGE_PLANS="${DEFENDER_MANAGE_PLANS:-$(config_setting defender.managePlans true)}"
    DEFENDER_TARGET_CVE="${DEFENDER_TARGET_CVE:-$SCENARIO_CVE}"
    DEFENDER_APPSERVICES_TIER="${DEFENDER_APPSERVICES_TIER:-$(config_setting defender.plans.AppServices Standard)}"
    DEFENDER_CONTAINERS_TIER="${DEFENDER_CONTAINERS_TIER:-$(config_setting defender.plans.Containers Standard)}"
    DEFENDER_CSPM_TIER="${DEFENDER_CSPM_TIER:-$(config_setting defender.plans.CloudPosture Standard)}"
    DEFENDER_ARM_TIER="${DEFENDER_ARM_TIER:-$(config_setting defender.plans.Arm Standard)}"
    DEFENDER_MANAGE_EXTENSIONS="${DEFENDER_MANAGE_EXTENSIONS:-$(config_setting defender.manageExtensions true)}"
    DEFENDER_CSPM_SERVERLESS_PROTECTION="${DEFENDER_CSPM_SERVERLESS_PROTECTION:-$(config_setting defender.cspmExtensions.AgentlessServerlessPosture true)}"
    DEFENDER_CSPM_SERVERLESS_CONTAINERS="${DEFENDER_CSPM_SERVERLESS_CONTAINERS:-$(config_setting defender.cspmExtensions.ServerlessContainers true)}"
    DEFENDER_CSPM_REGISTRY_ASSESSMENT="${DEFENDER_CSPM_REGISTRY_ASSESSMENT:-$(config_setting defender.cspmExtensions.ContainerRegistriesVulnerabilityAssessments true)}"
    DEFENDER_CSPM_KUBERNETES_DISCOVERY="${DEFENDER_CSPM_KUBERNETES_DISCOVERY:-$(config_setting defender.cspmExtensions.AgentlessDiscoveryForKubernetes false)}"
    DEFENDER_CSPM_VM_SCANNING="${DEFENDER_CSPM_VM_SCANNING:-$(config_setting defender.cspmExtensions.AgentlessVmScanning false)}"
    DEFENDER_CSPM_SENSITIVE_DATA="${DEFENDER_CSPM_SENSITIVE_DATA:-$(config_setting defender.cspmExtensions.SensitiveDataDiscovery false)}"
    DEFENDER_CSPM_PERMISSIONS_MANAGEMENT="${DEFENDER_CSPM_PERMISSIONS_MANAGEMENT:-$(config_setting defender.cspmExtensions.EntraPermissionsManagement false)}"
    DEFENDER_CSPM_API_POSTURE="${DEFENDER_CSPM_API_POSTURE:-$(config_setting defender.cspmExtensions.ApiPosture false)}"
    DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT="${DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT:-$(config_setting defender.containersExtensions.ContainerRegistriesVulnerabilityAssessments true)}"
    DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY="${DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY:-$(config_setting defender.containersExtensions.AgentlessDiscoveryForKubernetes false)}"
    DEFENDER_CONTAINERS_VM_SCANNING="${DEFENDER_CONTAINERS_VM_SCANNING:-$(config_setting defender.containersExtensions.AgentlessVmScanning false)}"
    DEFENDER_CONTAINERS_SENSOR="${DEFENDER_CONTAINERS_SENSOR:-$(config_setting defender.containersExtensions.ContainerSensor false)}"
    DEFENDER_DEVOPS_CONNECTOR_ENABLED="${DEFENDER_DEVOPS_CONNECTOR_ENABLED:-$(config_setting defender.devops.connectorEnabled true)}"
    DEFENDER_DEVOPS_CONNECTOR_NAME="${DEFENDER_DEVOPS_CONNECTOR_NAME:-$(config_setting defender.devops.connectorName ninjapaws-github)}"
    DEFENDER_DEVOPS_GITHUB_OWNER="${DEFENDER_DEVOPS_GITHUB_OWNER:-$(config_setting defender.devops.githubOwner ninjapaw)}"
    GITHUB_ADVANCED_SECURITY_EXPECTED="${GITHUB_ADVANCED_SECURITY_EXPECTED:-$(config_setting defender.devops.advancedSecurityExpected true)}"
    [[ -n "$RESOURCE_GROUP" ]] || fail "No resource group for '$ENVIRONMENT'. Set it in $CONFIG_FILE, AZURE_RESOURCE_GROUP, or --resource-group."
    if [[ "$COMMAND" != uninstall && "$COMMAND" != wizard ]]; then
        [[ -n "$REGISTRY_NAME" ]] || fail "No container registry for '$ENVIRONMENT'. Set it in $CONFIG_FILE, AZURE_CONTAINER_REGISTRY_NAME, or --registry-name."
        [[ -n "$APP_SERVICE_NAME" ]] || fail "No App Service for '$ENVIRONMENT'. Set it in $CONFIG_FILE, AZURE_APP_SERVICE_NAME, or --app-service-name."
    fi

    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan && "$COMMAND" != wizard ]]; then
        if [[ "$COMMAND" == uninstall ]]; then
            printf '\nUninstall wizard\n'
            printf 'Environment: %s (locked to the current Git branch)\n' "$ENVIRONMENT"
            printf 'Azure ownership tags will be verified before deletion.\n'
            RESOURCE_GROUP="$(prompt_default 'Resource group to delete' "$RESOURCE_GROUP")"
            if [[ "$WAIT_FOR_DELETE_EXPLICIT" == false ]]; then
                WAIT_FOR_DELETE="$(prompt_boolean 'Wait for Azure to confirm the resource group is deleted' true)"
            fi
        else
            LOCATION="$(prompt_region "$LOCATION")"
            RESOURCE_GROUP="$(prompt_default 'Resource group' "$RESOURCE_GROUP")"
            REGISTRY_NAME="$(prompt_default 'Container Registry' "$REGISTRY_NAME")"
            APP_SERVICE_NAME="$(prompt_default 'App Service' "$APP_SERVICE_NAME")"
        fi
    fi

    ACR_NAME="${REGISTRY_NAME//-/}"
    if [[ "$COMMAND" != uninstall && "$COMMAND" != wizard ]]; then
        [[ "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]] || fail "ACR name must be 5-50 lowercase letters or numbers after hyphen removal."
    fi
    output_base="${OUTPUT_ROOT:-$INVOCATION_DIR/output}"
    OUTPUT_DIR="$output_base/$ENVIRONMENT"
    STATUS_OPEN_MARKER="$output_base/.deployment-$ENVIRONMENT.browser-opened"
    if [[ -d "$OUTPUT_DIR" ]]; then
        if [[ "$ARCHIVE_OUTPUTS" == true ]]; then
            archive_dir="$output_base/archive/$(date -u +%Y%m%dT%H%M%SZ)-$ENVIRONMENT"
            mkdir -p "$archive_dir"
            cp -a "$OUTPUT_DIR/." "$archive_dir/" 2>/dev/null || true
            # Copy rather than move: an open browser tab must never see the report path disappear.
            find "$OUTPUT_DIR" -maxdepth 1 -type f \
                ! -name "deployment-$ENVIRONMENT.html" \
                ! -name "deployment-$ENVIRONMENT.console.html" \
                ! -name "deployment-$ENVIRONMENT.state.js" \
                -delete 2>/dev/null || true
        else
            rm -rf "$OUTPUT_DIR"
        fi
    fi
    mkdir -p "$OUTPUT_DIR"
    rm -f "$REPO_ROOT/deployment-output.json"
    STATE_FILE="$OUTPUT_DIR/deployment-$ENVIRONMENT.json"
    STATE_JS="$OUTPUT_DIR/deployment-$ENVIRONMENT.state.js"
    [[ "${NO_STATUS_HTML:-false}" == true ]] || STATUS_HTML="$OUTPUT_DIR/deployment-$ENVIRONMENT.html"
    STATUS_CONSOLE="$OUTPUT_DIR/deployment-$ENVIRONMENT.console.html"
    STATUS_RAW_CONSOLE="$OUTPUT_DIR/.deployment-$ENVIRONMENT.console.raw"
    ACR_NAME="${REGISTRY_NAME//-/}"
    set_task plan in_progress "Resolving names, output workspace, and image tag."
    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan && "$COMMAND" != wizard ]]; then
        : > "$STATUS_RAW_CONSOLE"
        write_status_html awaiting_user waiting 0 "Waiting for your input. The terminal is asking for deployment values; press Enter to accept each default."
        open_status_html
    fi
    start_console_capture
    if [[ "$COMMAND" == verify && "$IMAGE_TAG_EXPLICIT" == false && -f "$STATE_FILE" ]]; then
        IMAGE_TAG="$(sed -n 's/.*"imageTag": "\([^"]*\)".*/\1/p' "$STATE_FILE")"
    fi
    IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
    set_task plan success "Targeting $RESOURCE_GROUP in $LOCATION with image $IMAGE_NAME:$IMAGE_TAG."
    write_status_html planning starting "$(auto_percent)" "Resolved deployment settings and waiting for the selected lifecycle stage."
    open_status_html
}

environment_for_branch() {
    case "$1" in
        main) printf 'prod' ;;
        dev|dev/*|feature/*|feat/*|chore/*|fix/*|bugfix/*) printf 'dev' ;;
        *) return 1 ;;
    esac
}

enforce_branch_environment() {
    case "$COMMAND" in
        setup|provision|build|deploy|update|repair|rollout|uninstall) ;;
        *) return 0 ;;
    esac

    local branch_name expected_environment
    branch_name="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || true)}"
    expected_environment="$(environment_for_branch "$branch_name")" || fail "Mutating command '$COMMAND' requires a supported development branch or 'main'; current branch is '$branch_name'."
    [[ "$ENVIRONMENT" == "$expected_environment" ]] || fail "Branch '$branch_name' can only target environment '$expected_environment', not '$ENVIRONMENT'."
}

require_commands() {
    local command_name
    for command_name in az curl git tr; do
        command -v "$command_name" >/dev/null 2>&1 || fail "'$command_name' is required."
    done
}

authenticate() {
    local account_info current_subscription_id
    if ! az account show >/dev/null 2>&1; then
        echo -e "${YELLOW}Azure CLI is not authenticated. Starting device-code login.${NC}"
        if ! az login --use-device-code >/dev/null; then
            if [[ "$COMMAND" == wizard ]]; then
                AUTHENTICATION_SKIPPED=true
                echo -e "${YELLOW}Azure login was not completed. The read-only wizard stopped before inspecting Azure.${NC}"
                echo "Run 'az login' and start the wizard again when you are ready."
                return 0
            fi
            fail "Azure login was not completed. Run 'az login' and retry '$COMMAND'."
        fi
    fi
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        current_subscription_id="$(az account show --query id -o tsv 2>/dev/null || true)"
        SUBSCRIPTION_ID="$current_subscription_id"
    fi
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        az account set --subscription "$SUBSCRIPTION_ID" || fail "Unable to select subscription '$SUBSCRIPTION_ID'."
    fi
    # One call for every identity fact the audit trail needs; tsv returns one field per line.
    account_info="$(az account show --query "[id,tenantId,name,user.name]" -o tsv)"
    SUBSCRIPTION_ID="$(printf '%s\n' "$account_info" | sed -n 1p)"
    AZURE_TENANT_ID="${AZURE_TENANT_ID:-$(printf '%s\n' "$account_info" | sed -n 2p)}"
    SUBSCRIPTION_NAME="$(printf '%s\n' "$account_info" | sed -n 3p)"
    AZURE_ACCOUNT_NAME="$(printf '%s\n' "$account_info" | sed -n 4p)"
}

print_plan() {
    echo -e "${BLUE}Deployment plan${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Scenario: $SCENARIO_NAME ($SCENARIO_ID)"
    echo "Subscription: $(mask_identifier "${SUBSCRIPTION_ID:-current Azure subscription}")"
    echo "Resource group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Registry: $ACR_NAME"
    echo "App Service: $APP_SERVICE_NAME"
    echo "Plan SKU: $APP_SERVICE_PLAN_SKU"
    echo "Image: $IMAGE_NAME:$IMAGE_TAG"
    echo "Bicep: $REPO_ROOT/infra/main.bicep"
    echo "State: $STATE_FILE"
    if [[ -n "$STATUS_HTML" ]]; then
        echo "Live report: $(report_url "$STATUS_HTML")"
    fi
    return 0
}

run_bicep_deployment() {
    local deployment_name="$1"
    local deployment_output="$OUTPUT_DIR/deployment-output.json"
    local deployment_log="$OUTPUT_DIR/deployment-$ENVIRONMENT.log"
    local operations_seen="$OUTPUT_DIR/deployment-$ENVIRONMENT.operations"
    local deployment_pid state succeeded failed running percent operation_lines operation_line
    local -a deployment_args
    local expected_operations=6

    : > "$deployment_log"
    : > "$operations_seen"
    echo -e "${BLUE}Bicep deployment: $deployment_name${NC}"
    echo "Detailed Azure CLI output: $deployment_log"
    write_status_html provisioning running "$(auto_percent 5)" "Submitting Bicep infrastructure deployment."

    deployment_args=(
        deployment group create
        --name "$deployment_name"
        --resource-group "$RESOURCE_GROUP"
        --mode Incremental
        --template-file "$AZURE_REPO_ROOT/infra/main.bicep"
        --parameters
        "containerRegistryName=$ACR_NAME"
        "appServiceName=$APP_SERVICE_NAME"
        "appServicePlanSku=$APP_SERVICE_PLAN_SKU"
        "location=$LOCATION"
        "imageName=$IMAGE_NAME"
        imageTag=latest
        "nginxVersion=$NGINX_VERSION"
        "vulnerabilityStatus=$VULNERABILITY_STATUS"
        "port=$PORT"
        "defenderEnabled=$DEFENDER_ENABLED"
        "defenderAppServicesTier=$DEFENDER_APPSERVICES_TIER"
        "defenderContainersTier=$DEFENDER_CONTAINERS_TIER"
        "defenderCspmTier=$DEFENDER_CSPM_TIER"
        "defenderArmTier=$DEFENDER_ARM_TIER"
        "defenderServerlessProtection=$DEFENDER_CSPM_SERVERLESS_PROTECTION"
        "defenderServerlessContainers=$DEFENDER_CSPM_SERVERLESS_CONTAINERS"
        "defenderRegistryAssessment=$DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT"
        "defenderDevOpsConnector=$DEFENDER_DEVOPS_CONNECTOR_ENABLED"
        "githubAdvancedSecurity=$GITHUB_ADVANCED_SECURITY_EXPECTED"
        --output json
    )
    if [[ "$CONSOLE_CAPTURE_STARTED" == true ]]; then
        az "${deployment_args[@]}" > >(tee "$deployment_output") 2> >(tee "$deployment_log" >&2) &
    else
        az "${deployment_args[@]}" > >(tee "$deployment_output" | tee -a "$STATUS_RAW_CONSOLE") 2> >(tee "$deployment_log" | tee -a "$STATUS_RAW_CONSOLE" >&2) &
    fi
    deployment_pid=$!

    while kill -0 "$deployment_pid" 2>/dev/null; do
        state="$(az deployment group show --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query properties.provisioningState -o tsv 2>/dev/null || true)"
        succeeded="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Succeeded'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        failed="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Failed'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        running="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Running' || properties.provisioningState=='Accepted'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        operation_lines="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[].{state:properties.provisioningState,resource:targetResource.resourceName,type:targetResource.resourceType}" -o tsv 2>/dev/null || true)"

        if [[ "$succeeded" =~ ^[0-9]+$ ]]; then
            percent=$((succeeded * 100 / expected_operations))
            ((percent > 95)) && percent=95
        else
            percent=10
        fi
        printf '[%3s%%] state=%s succeeded=%s running=%s failed=%s\n' "$percent" "${state:-starting}" "$succeeded" "$running" "$failed"
        write_status_html provisioning running "$(auto_percent "$percent")" "Azure state: ${state:-starting}; succeeded=$succeeded; running=$running; failed=$failed."

        while IFS= read -r operation_line; do
            [[ -n "$operation_line" ]] || continue
            if ! line_seen "$operation_line" "$operations_seen"; then
                echo "  resource: $operation_line"
                printf '%s\n' "$operation_line" >> "$operations_seen"
            fi
        done <<< "$operation_lines"
        sleep 5
    done

    wait "$deployment_pid" || {
        FAILURE_MESSAGE="The Bicep deployment '$deployment_name' failed. The Azure CLI error is in deployment-$ENVIRONMENT.log and the console stream."
        echo -e "${RED}Bicep deployment failed. Full CLI details:${NC}"
        cat "$deployment_log"
        return 1
    }
    printf '[100%%] state=Succeeded succeeded=%s running=0 failed=%s\n' "$succeeded" "$failed"
    BICEP_OPERATIONS_SUCCEEDED="$succeeded"
    echo -e "${GREEN}Bicep deployment completed.${NC}"
}

provision() {
    local group_id
    set_task resourcegroup in_progress "Creating and tagging $RESOURCE_GROUP in $LOCATION."
    echo -e "${YELLOW}Provisioning resource group and Bicep infrastructure...${NC}"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    group_id="$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)"
    az tag update \
        --resource-id "$group_id" \
        --operation Merge \
        --tags ninjapaws-managed=true ninjapaws-environment="$ENVIRONMENT" \
        --output none
    record_check "Resource group exists and carries the Ninja Paws ownership tags" pass "$RESOURCE_GROUP in $LOCATION tagged ninjapaws-managed=true, ninjapaws-environment=$ENVIRONMENT."
    set_task resourcegroup success "$RESOURCE_GROUP is present in $LOCATION and tagged for environment $ENVIRONMENT."
    write_status_html provisioning running "$(auto_percent)" "Resource group ready; starting the Bicep deployment."

    set_task infra in_progress "Submitting the Bicep template and tracking each resource operation."
    run_bicep_deployment "ninjapaws-dojo-$(date +%s)"
    record_check "Bicep infrastructure deployment reached Succeeded" pass "${BICEP_OPERATIONS_SUCCEEDED:-All} resource operations completed without a failed state."
    set_task infra success "Registry, App Service, plan, and managed identity are deployed and in a Succeeded state."
    write_state provisioned success "Bicep infrastructure applied"
    write_status_html provisioning success "$(auto_percent)" "Bicep infrastructure completed successfully."
}

sha256_of_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

sha256_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# Content address for the image: every file the Dockerfile copies, plus every build argument.
compute_build_fingerprint() {
    local file manifest=""
    for file in Dockerfile package.json package-lock.json src/app.js nginx.conf entrypoint.sh scripts/verify.sh; do
        if [[ -f "$REPO_ROOT/$file" ]]; then
            manifest+="$file $(sha256_of_file "$REPO_ROOT/$file")"$'\n'
        else
            manifest+="$file absent"$'\n'
        fi
    done
    manifest+="args $BASE_OS_IMAGE $BASE_OS_VERSION $NODE_MAJOR_VERSION $NGINX_VERSION $VULNERABILITY_STATUS $PORT $DEFENDER_ENABLED"$'\n'
    manifest+="npmRegistryUrl $NPM_REGISTRY_URL"$'\n'
    manifest+="npmUseMirror $NPM_USE_MIRROR"$'\n'
    manifest+="npmNetworkMode $NPM_NETWORK_MODE"$'\n'
    printf '%s' "$manifest" | sha256_of_stdin | cut -c1-16
}

acr_tag_digest() {
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$1" --query digest -o tsv 2>/dev/null || true
}

# One registry round trip returns every tag on a manifest, instead of one lookup per tag.
# tsv renders a JSON array one element per line, so flatten to a single space-delimited string.
acr_tags_for_digest() {
    az acr manifest list-metadata --registry "$ACR_NAME" --name "$IMAGE_NAME" \
        --query "[?digest=='$1'].tags | [0]" -o tsv 2>/dev/null \
        | tr '\r\n\t' '   ' | tr -s ' ' || true
}

acr_digest_has_tag() {
    [[ " $1 " == *" $2 "* ]]
}

# Server-side retag so an unchanged image gains the new tag without a rebuild.
acr_alias_tag() {
    local digest="$1" tag="$2" registry_login="$3"
    az acr import \
        --name "$ACR_NAME" \
        --source "$registry_login/$IMAGE_NAME@$digest" \
        --image "$IMAGE_NAME:$tag" \
        --force \
        --output none
}

build_image() {
    local registry_login existing_digest tag aliased=0 existing_tags
    local build_log build_pid build_elapsed build_lines build_tail build_percent build_started
    set_task fingerprint in_progress "Hashing the build context and build arguments."
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)" || fail "ACR '$ACR_NAME' was not found. Run provision first."

    BUILD_FINGERPRINT="$(compute_build_fingerprint)"
    FINGERPRINT_TAG="fp-$BUILD_FINGERPRINT"
    echo -e "${BLUE}Build fingerprint: $BUILD_FINGERPRINT${NC}"

    if [[ "$FORCE_REBUILD" == false ]]; then
        existing_digest="$(acr_tag_digest "$FINGERPRINT_TAG")"
    else
        existing_digest=""
        echo -e "${YELLOW}--force-rebuild set; ignoring any matching image already in the registry.${NC}"
    fi

    if [[ -n "$existing_digest" ]]; then
        set_task fingerprint success "Fingerprint $BUILD_FINGERPRINT already exists in $ACR_NAME as $existing_digest, so no rebuild is required."
        record_check "Build context fingerprint compared against the registry" pass "Fingerprint $BUILD_FINGERPRINT matched an existing manifest, avoiding a rebuild and upload."
    elif [[ "$FORCE_REBUILD" == true ]]; then
        set_task fingerprint success "Fingerprint $BUILD_FINGERPRINT computed; the registry comparison was bypassed by --force-rebuild."
        record_check "Build context fingerprint compared against the registry" not_applicable "--force-rebuild was set, so the registry was not consulted for a matching digest."
    else
        set_task fingerprint success "Fingerprint $BUILD_FINGERPRINT is not in $ACR_NAME, so the image content changed and must be rebuilt."
        record_check "Build context fingerprint compared against the registry" pass "Fingerprint $BUILD_FINGERPRINT was absent, correctly triggering a rebuild."
    fi
    write_status_html building running "$(auto_percent)" "Fingerprint resolved as $BUILD_FINGERPRINT."

    if [[ -n "$existing_digest" ]]; then
        set_task image in_progress "Aliasing the existing digest onto the release tags instead of rebuilding."
        IMAGE_DIGEST="$existing_digest"
        echo -e "${GREEN}Identical image content already in ACR ($IMAGE_DIGEST). Skipping the build.${NC}"
        existing_tags="$(acr_tags_for_digest "$IMAGE_DIGEST")"
        write_status_html building running "$(auto_percent 50)" "Digest already carries tags: ${existing_tags:-none}. Aliasing anything missing."
        for tag in "$IMAGE_TAG" latest "$VULNERABILITY_STATUS"; do
            if ! acr_digest_has_tag "$existing_tags" "$tag"; then
                acr_alias_tag "$IMAGE_DIGEST" "$tag" "$registry_login" || fail "Could not alias tag '$tag' to digest $IMAGE_DIGEST. Re-run with --force-rebuild."
                echo "  aliased $IMAGE_NAME:$tag -> $IMAGE_DIGEST"
                aliased=$((aliased + 1))
            fi
        done
        BUILD_SKIPPED=true
        record_check "Container image is present in the registry" pass "Reused existing manifest $IMAGE_DIGEST; $aliased tag(s) were re-pointed server-side with no layer upload."
        set_task image skipped "No rebuild or upload needed: reused $IMAGE_DIGEST and re-pointed $aliased tag(s)."
        write_state image-built success "Reused existing image $IMAGE_DIGEST"
        write_status_html building success "$(auto_percent)" "Reused the existing image digest; no rebuild or upload was required."
        return 0
    fi

    set_task image in_progress "Running a remote ACR build for $IMAGE_NAME:$IMAGE_TAG."
    echo -e "${YELLOW}Building and pushing $registry_login/$IMAGE_NAME:$IMAGE_TAG...${NC}"
    write_status_html building running "$(auto_percent 10)" "Building and pushing the versioned, latest, fingerprint, and training-status images to ACR."
    build_log="$OUTPUT_DIR/acr-build-$ENVIRONMENT.log"
    : > "$build_log"
    build_started="$(date +%s)"
    az acr build \
        --registry "$ACR_NAME" \
        --image "$IMAGE_NAME:$IMAGE_TAG" \
        --image "$IMAGE_NAME:latest" \
        --image "$IMAGE_NAME:$VULNERABILITY_STATUS" \
        --image "$IMAGE_NAME:$FINGERPRINT_TAG" \
        --build-arg "BASE_OS_IMAGE=$BASE_OS_IMAGE" \
        --build-arg "BASE_OS_VERSION=$BASE_OS_VERSION" \
        --build-arg "NODE_MAJOR_VERSION=$NODE_MAJOR_VERSION" \
        --build-arg "NGINX_VERSION=$NGINX_VERSION" \
        --build-arg "VULNERABILITY_STATUS=$VULNERABILITY_STATUS" \
        --build-arg "PORT=$PORT" \
        --build-arg "DEFENDER_ENABLED=$DEFENDER_ENABLED" \
        --build-arg "NPM_REGISTRY_URL=$NPM_REGISTRY_URL" \
        --build-arg "NPM_USE_MIRROR=$NPM_USE_MIRROR" \
        --build-arg "NPM_NETWORK_MODE=$NPM_NETWORK_MODE" \
        "$AZURE_REPO_ROOT" > "$build_log" 2>&1 &
    build_pid=$!

    # The remote build is silent for minutes; heartbeat so the report keeps moving.
    while kill -0 "$build_pid" 2>/dev/null; do
        build_elapsed=$(( $(date +%s) - build_started ))
        build_lines="$(wc -l < "$build_log" 2>/dev/null || printf '0')"
        build_tail="$(tail -n 1 "$build_log" 2>/dev/null || true)"
        build_percent=$((build_elapsed * 100 / 180))
        ((build_percent > 95)) && build_percent=95
        printf '[%3s%%] acr build running %ss (%s log lines)\n' "$build_percent" "$build_elapsed" "$build_lines"
        write_status_html building running "$(auto_percent "$build_percent")" "ACR build running for ${build_elapsed}s; ${build_lines} log lines. Latest: ${build_tail:-waiting for the build agent}"
        sleep 5
    done
    if ! wait "$build_pid"; then
        FAILURE_MESSAGE="The ACR build for $IMAGE_NAME:$IMAGE_TAG failed. Full output is in acr-build-$ENVIRONMENT.log."
        echo -e "${RED}ACR build failed. Full output:${NC}"
        cat "$build_log"
        fail "$FAILURE_MESSAGE"
    fi
    cat "$build_log"
    IMAGE_DIGEST="$(acr_tag_digest "$IMAGE_TAG")"
    record_check "Container image is present in the registry" pass "Built and pushed $IMAGE_NAME with tags $IMAGE_TAG, latest, $FINGERPRINT_TAG, $VULNERABILITY_STATUS (digest ${IMAGE_DIGEST:-unresolved})."
    set_task image success "Pushed $IMAGE_NAME:$IMAGE_TAG plus latest, $FINGERPRINT_TAG, and $VULNERABILITY_STATUS (digest ${IMAGE_DIGEST:-unknown})."
    write_state image-built success "Image pushed to ACR"
    write_status_html building success "$(auto_percent)" "Container images pushed to ACR."
}

rollout_image() {
    local registry_login identity_client_id image_reference configured_image health_code app_host
    local previous_container
    set_task appconfig in_progress "Comparing the live App Service configuration against the target image."
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none || fail "Image '$IMAGE_NAME:$IMAGE_TAG' is not present in ACR."
    [[ -n "$IMAGE_DIGEST" ]] || IMAGE_DIGEST="$(acr_tag_digest "$IMAGE_TAG")"
    image_reference="DOCKER|$registry_login/$IMAGE_NAME:$IMAGE_TAG"

    configured_image="$(az webapp config container show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query "[?name=='DOCKER_CUSTOM_IMAGE_NAME'].value | [0]" -o tsv 2>/dev/null || true)"
    app_host="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query defaultHostName -o tsv)"
    if [[ "$FORCE_REBUILD" == false && "$BUILD_SKIPPED" == true && "$configured_image" == "$image_reference" ]]; then
        health_code="$(http_probe "https://$app_host/health")"
        if [[ "${health_code%% *}" == 200 ]]; then
            ROLLOUT_SKIPPED=true
            echo -e "${GREEN}App Service already runs $IMAGE_DIGEST and is healthy. Skipping reconfiguration and restart.${NC}"
            record_check "App Service container configuration matches the target image" pass "Already set to $image_reference; no configuration change was applied."
            set_task appconfig skipped "No change: App Service already points at $IMAGE_NAME:$IMAGE_TAG (${IMAGE_DIGEST:-digest unknown})."
            record_check "App Service restart was required" not_applicable "The running container already serves the target digest and answered /health with HTTP 200."
            set_task restart skipped "Restart avoided: the live container is already correct and healthy."
            write_state rolled-out success "App Service already running the target digest"
            write_status_html deploying success "$(auto_percent)" "App Service is already on the target image; no restart was needed."
            return 0
        fi
        echo -e "${YELLOW}Configured image matches but the app is unhealthy; reconfiguring and restarting.${NC}"
    fi

    identity_client_id="$(az identity show --resource-group "$RESOURCE_GROUP" --name "${APP_SERVICE_NAME}-identity" --query clientId -o tsv)"
    echo -e "${YELLOW}Configuring App Service for immutable image $IMAGE_TAG...${NC}"
    write_status_html deploying running "$(auto_percent 20)" "Configuring App Service with the immutable container image and managed identity."
    az webapp config set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_SERVICE_NAME" \
        --generic-configurations "{\"linuxFxVersion\":\"$image_reference\",\"acrUseManagedIdentityCreds\":true,\"acrUserManagedIdentityID\":\"$identity_client_id\"}" \
        --output none
    az webapp config appsettings set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_SERVICE_NAME" \
        --settings "DOCKER_REGISTRY_SERVER_URL=https://$registry_login" WEBSITES_PORT=80 WEBSITES_ENABLE_APP_SERVICE_STORAGE=false \
        --output none
    record_check "App Service container configuration matches the target image" pass "Set to $image_reference with managed-identity pull using client ID $identity_client_id."
    set_task appconfig success "App Service $APP_SERVICE_NAME points at $registry_login/$IMAGE_NAME:$IMAGE_TAG (${IMAGE_DIGEST:-digest unknown}) via managed identity."

    set_task restart in_progress "Restarting App Service and waiting for the new container to answer."
    write_status_html deploying running "$(auto_percent 20)" "Restarting App Service and waiting for the container to warm up."
    previous_container="$(status_field host "$(fetch_app_status "$app_host")")"
    az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --output none
    if wait_for_app_ready "$app_host" "$previous_container"; then
        record_check "App Service restart was required" pass "Restarted and container ${APP_CONTAINER_ID:-unknown} answered /health and /api/status with the expected build after $APP_READY_ATTEMPTS attempt(s)."
        set_task restart success "New container ${APP_CONTAINER_ID:-unknown} is serving traffic and reporting NGINX $NGINX_VERSION / $VULNERABILITY_STATUS after $APP_READY_ATTEMPTS attempt(s)."
    else
        record_check "App Service restart was required" fail "Restarted but the container never served the expected build; last health response was HTTP ${HEALTH_HTTP_CODE:-000} after $APP_READY_ATTEMPTS attempt(s)."
        set_task restart failure "The container did not serve the expected build within $APP_READY_ATTEMPTS attempts; last health response was HTTP ${HEALTH_HTTP_CODE:-000}."
        FAILURE_MESSAGE="App Service '$APP_SERVICE_NAME' restarted but never became healthy. Check the container logs with: az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_SERVICE_NAME"
        write_state rolled-out failure "Container did not become healthy"
        fail "$FAILURE_MESSAGE"
    fi
    write_state rolled-out success "App Service configured for immutable image"
    write_status_html deploying success "$(auto_percent)" "App Service configured, restarted, and answering health checks."
}

http_probe() {
    curl -o /dev/null -sS -w '%{http_code} %{time_total}' --max-time 30 "$1" 2>/dev/null || printf '000 0'
}

fetch_app_status() {
    curl -fsS --max-time 20 "https://$1/api/status" 2>/dev/null || true
}

status_field() {
    printf '%s' "${2:-}" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

# A restart keeps the outgoing container answering for a few seconds, so "healthy" alone proves
# nothing. Wait until a *different* container reports the build we just published.
wait_for_app_ready() {
    local host="$1" previous_container="${2:-}" max_attempts="${3:-24}"
    local attempt=0 body container probe expected_detected=false
    [[ "$VULNERABILITY_STATUS" == vulnerable ]] && expected_detected=true
    APP_READY_ATTEMPTS=0
    APP_CONTAINER_ID=""
    while ((attempt < max_attempts)); do
        attempt=$((attempt + 1))
        APP_READY_ATTEMPTS="$attempt"
        probe="$(http_probe "https://$host/health")"
        HEALTH_HTTP_CODE="${probe%% *}"
        if [[ "$HEALTH_HTTP_CODE" == 200 ]]; then
            body="$(fetch_app_status "$host")"
            container="$(status_field host "$body")"
            if [[ -n "$body" \
                && "$body" == *"\"$NGINX_VERSION\""* \
                && "$body" == *"\"detected\":$expected_detected"* \
                && ( -z "$previous_container" || "$container" != "$previous_container" ) ]]; then
                APP_CONTAINER_ID="$container"
                APP_STATUS_BODY="$body"
                return 0
            fi
        fi
        echo "  waiting for the new container (attempt $attempt/$max_attempts, health HTTP $HEALTH_HTTP_CODE, container ${container:-none})"
        write_status_html deploying running "$(auto_percent $((attempt * 90 / max_attempts)))" "Waiting for the replacement container to serve the new image (attempt $attempt of $max_attempts, health HTTP $HEALTH_HTTP_CODE)."
        sleep 10
    done
    return 1
}

# The connector needs a caller-supplied identifier; any stable UUID is accepted.
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        printf '%08x-%04x-4%03x-a%03x-%012x\n' \
            $((RANDOM * RANDOM)) $((RANDOM % 65536)) $((RANDOM % 4096)) \
            $((RANDOM % 4096)) $((RANDOM * RANDOM * RANDOM))
    fi
}

defender_plan_tier() {
    az security pricing show --name "$1" --query pricingTier -o tsv 2>/dev/null || true
}

# Azure reports extension state as the strings "True"/"False"; normalize for comparison.
defender_extension_state() {
    local value
    value="$(az security pricing show --name "$1" --query "extensions[?name=='$2'].isEnabled | [0]" -o tsv 2>/dev/null || true)"
    case "$value" in
        True|true) printf 'true' ;;
        False|false) printf 'false' ;;
        *) printf 'unknown' ;;
    esac
}

# Applies every extension for a plan in one call, because the API replaces the whole set.
apply_plan_extensions() {
    local plan="$1" tier="$2" spec="$3"
    local extension desired current drift=0 args=()

    [[ "$tier" == Standard ]] || return 0

    while IFS='=' read -r extension desired; do
        [[ -n "$extension" ]] || continue
        if [[ "$desired" == true ]]; then
            args+=(--extensions "name=$extension" isEnabled=True)
        else
            args+=(--extensions "name=$extension" isEnabled=False)
        fi
        current="$(defender_extension_state "$plan" "$extension")"
        [[ "$current" == "$desired" ]] || drift=1
    done <<<"$spec"

    ((${#args[@]} > 0)) || return 0
    if [[ "$DEFENDER_MANAGE_EXTENSIONS" != true ]]; then
        return 2
    fi
    ((drift == 1)) || return 0
    az security pricing create --name "$plan" --tier "$tier" "${args[@]}" --output none 2>/dev/null || return 1
    return 0
}

record_extension_checks() {
    local plan="$1" plan_label="$2" spec="$3"
    local extension desired current label

    while IFS='|' read -r extension desired label; do
        [[ -n "$extension" ]] || continue
        current="$(defender_extension_state "$plan" "$extension")"
        if [[ "$plan" == Containers && "$extension" == ContainerRegistriesVulnerabilityAssessments ]]; then
            DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE="$current"
        fi
        if [[ "$plan" == CloudPosture && "$extension" == AgentlessVmScanning ]]; then
            DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE="$current"
        fi
        if [[ "$plan" == CloudPosture && "$extension" == ApiPosture ]]; then
            DEFENDER_CSPM_API_POSTURE_AUDIT_STATE="$current"
        fi
        if [[ "$plan" == Containers && "$extension" == AgentlessVmScanning ]]; then
            DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE="$current"
        fi
        if [[ "$current" == "$desired" ]]; then
            if [[ "$desired" == true ]]; then
                record_check "$plan_label: $label" pass "Azure reports the extension enabled."
            else
                record_check "$plan_label: $label" not_applicable "Intentionally disabled; this scenario does not deploy that workload."
            fi
        elif [[ "$current" == unknown ]]; then
            record_check "$plan_label: $label" unknown "Azure did not report a state for this extension. It may be unavailable in this subscription or region."
        else
            record_check "$plan_label: $label" unknown "Azure reports '$current' while configuration requests '$desired'."
        fi
    done <<<"$spec"
}

# Creates the ARM connector only; the GitHub App authorization remains a manual portal step.
ensure_devops_connector() {
    local existing connector_name connector_state existing_rg

    if [[ "$DEFENDER_DEVOPS_CONNECTOR_ENABLED" != true ]]; then
        record_check "Defender for Cloud GitHub DevOps connector" not_applicable "Disabled by configuration (defender.devops.connectorEnabled=$DEFENDER_DEVOPS_CONNECTOR_ENABLED)."
        return 0
    fi

    existing="$(az security security-connector list --query "[?environmentName=='Github' || environmentName=='GitHub'].name | [0]" -o tsv 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        existing_rg="$(az security security-connector list --query "[?name=='$existing'].resourceGroup | [0]" -o tsv 2>/dev/null || true)"

        # The ARM resource existing proves nothing. Repository discovery only
        # works once the GitHub app is authorized, and that creates the devops
        # configuration below. Reporting on existence alone hides a connector
        # that will sit in progress forever.
        if az rest --method GET \
            --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${existing_rg}/providers/Microsoft.Security/securityConnectors/${existing}/devops/default?api-version=2024-04-01" \
            --output none 2>/dev/null; then
            record_check "Defender for Cloud GitHub DevOps connector" pass "Connector '$existing' is authorized and discovering repositories."
            DEFENDER_DEVOPS_CONNECTOR_STATE=connected
        else
            record_check "Defender for Cloud GitHub DevOps connector" unknown "Connector '$existing' exists in $existing_rg but has no DevOps configuration, so it is not authorized and will never discover repositories. Complete Defender for Cloud > Environment settings > the connector > Authorize, then install the DevOps security GitHub app for '$DEFENDER_DEVOPS_GITHUB_OWNER'. See https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-github."
            DEFENDER_DEVOPS_CONNECTOR_STATE=authorization_required
        fi
        return 0
    fi

    # The identifier only has to be a GUID; the binding to a GitHub organisation
    # is established by the interactive authorization, not by this value.
    if az security security-connector create \
        --name "$DEFENDER_DEVOPS_CONNECTOR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --hierarchy-identifier "$(generate_uuid)" \
        --environment-name GitHub \
        --environment-data github-scope='{}' \
        --offerings '[0].cspm-monitor-github={}' \
        --output none 2>/dev/null; then
        connector_name="$DEFENDER_DEVOPS_CONNECTOR_NAME"
        DEFENDER_DEVOPS_CONNECTOR_STATE=authorization_required
        record_check "Defender for Cloud GitHub DevOps connector" unknown "Created connector '$connector_name' in $RESOURCE_GROUP. Repository discovery stays empty until the DevOps security GitHub app is authorized and installed for the '$DEFENDER_DEVOPS_GITHUB_OWNER' organization; that step is interactive. See https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-github."
    else
        DEFENDER_DEVOPS_CONNECTOR_STATE=unavailable
        record_check "Defender for Cloud GitHub DevOps connector" unknown "Could not create the connector automatically. Create it in Defender for Cloud > Environment settings > Add environment > GitHub, then authorize and install the DevOps security GitHub app. See https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-github."
    fi
}

# GitHub is the source of truth for Advanced Security; report it rather than assume it.
record_advanced_security_state() {
    local repository analysis status

    if [[ "$GITHUB_ADVANCED_SECURITY_EXPECTED" != true ]]; then
        record_check "GitHub Advanced Security code scanning" not_applicable "Not expected by configuration (defender.devops.advancedSecurityExpected=$GITHUB_ADVANCED_SECURITY_EXPECTED)."
        GITHUB_ADVANCED_SECURITY_STATE=not_expected
        return 0
    fi

    repository="$(project_meta repository '')"
    repository="${repository#https://github.com/}"
    repository="${repository%.git}"
    if [[ -z "$repository" ]] || ! command -v gh >/dev/null 2>&1; then
        GITHUB_ADVANCED_SECURITY_STATE=unknown
        record_check "GitHub Advanced Security code scanning" unknown "GitHub CLI is unavailable here, so Advanced Security state was not read. CodeQL runs in this repository's validation workflow; confirm scanning under the repository Security tab."
        return 0
    fi

    analysis="$(gh api "repos/$repository" --jq '.security_and_analysis.advanced_security.status // "unknown"' 2>/dev/null || printf 'unknown')"
    case "$analysis" in
        enabled)
            GITHUB_ADVANCED_SECURITY_STATE=enabled
            record_check "GitHub Advanced Security code scanning" pass "GitHub reports Advanced Security enabled for $repository."
            ;;
        disabled)
            GITHUB_ADVANCED_SECURITY_STATE=disabled
            record_check "GitHub Advanced Security code scanning" unknown "GitHub reports Advanced Security disabled for $repository. Public repositories still get CodeQL through the checked-in workflow."
            ;;
        *)
            GITHUB_ADVANCED_SECURITY_STATE=unknown
            record_check "GitHub Advanced Security code scanning" unknown "GitHub did not report an Advanced Security state for $repository; the token may lack repository administration scope."
            ;;
    esac
}

run_defender_scan() {
    local appservices_tier containers_tier cspm_tier arm_tier assessment_json target_found=1 failures=0
    local plan_name desired_tier current_tier plan_label cspm_spec containers_spec extension_result plan_error plan_failed
    set_task defender in_progress "Activating configured Defender plans and requesting the latest assessment inventory."
    write_status_html defender running "$(auto_percent 10)" "Activating Defender for App Service, Defender for Containers, and Defender CSPM coverage, then scanning for $DEFENDER_TARGET_CVE."

    if [[ "$DEFENDER_SCAN_ENABLED" != true ]]; then
        record_check "Defender for Cloud post-verification scan" not_applicable "Disabled by configuration (defender.scanAfterVerify=$DEFENDER_SCAN_ENABLED)."
        record_check "Defender workload coverage" not_applicable "Defender plan management and scanning were disabled for this run."
        set_task defender skipped "Defender scan skipped by configuration."
        return 0
    fi

    appservices_tier="$DEFENDER_APPSERVICES_TIER"
    containers_tier="$DEFENDER_CONTAINERS_TIER"
    cspm_tier="$DEFENDER_CSPM_TIER"
    arm_tier="$DEFENDER_ARM_TIER"
    while IFS='|' read -r plan_name desired_tier plan_label; do
        [[ -n "$plan_name" ]] || continue
        if [[ "$desired_tier" == disabled || "$desired_tier" == off ]]; then
            record_check "Defender plan: $plan_label" not_applicable "Disabled by configuration; this workload is not requesting $plan_label coverage."
            continue
        fi
        current_tier="$(defender_plan_tier "$plan_name")"
        if [[ "$DEFENDER_MANAGE_PLANS" == true && "$current_tier" != "$desired_tier" ]]; then
            plan_failed=0
            plan_error="$(az security pricing create --name "$plan_name" --tier "$desired_tier" --output none 2>&1)" || plan_failed=1
            if ((plan_failed == 1)); then
                record_check "Defender plan: $plan_label" fail "Could not activate the requested $desired_tier tier: ${plan_error:-no error detail returned}. Check Microsoft.Security/pricings permissions and subscription eligibility."
                failures=$((failures + 1))
            else
                current_tier="$(defender_plan_tier "$plan_name")"
                if [[ "$current_tier" == "$desired_tier" ]]; then
                    record_check "Defender plan: $plan_label" pass "Activated the $desired_tier tier and Azure confirms it."
                else
                    record_check "Defender plan: $plan_label" unknown "Requested $desired_tier but Azure still reports '${current_tier:-not available}'. Plan writes can lag; re-run the verify stage to confirm."
                fi
            fi
        elif [[ "$current_tier" == "$desired_tier" ]]; then
            record_check "Defender plan: $plan_label" pass "Azure reports the configured $desired_tier tier."
        else
            record_check "Defender plan: $plan_label" unknown "Azure reports '${current_tier:-not available}', while configuration requests $desired_tier and plan management is disabled."
        fi
    done <<EOF
AppServices|$appservices_tier|Defender for App Service
Containers|$containers_tier|Defender for Containers
CloudPosture|$cspm_tier|Defender CSPM
Arm|$arm_tier|Defender for Resource Manager
EOF

    write_status_html defender running "$(auto_percent 35)" "Applying Defender CSPM and Defender for Containers extension configuration."
    cspm_spec="AgentlessServerlessPosture=$DEFENDER_CSPM_SERVERLESS_PROTECTION
ServerlessContainers=$DEFENDER_CSPM_SERVERLESS_CONTAINERS
ContainerRegistriesVulnerabilityAssessments=$DEFENDER_CSPM_REGISTRY_ASSESSMENT
AgentlessDiscoveryForKubernetes=$DEFENDER_CSPM_KUBERNETES_DISCOVERY
AgentlessVmScanning=$DEFENDER_CSPM_VM_SCANNING
SensitiveDataDiscovery=$DEFENDER_CSPM_SENSITIVE_DATA
EntraPermissionsManagement=$DEFENDER_CSPM_PERMISSIONS_MANAGEMENT
ApiPosture=$DEFENDER_CSPM_API_POSTURE"
    containers_spec="ContainerRegistriesVulnerabilityAssessments=$DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT
AgentlessDiscoveryForKubernetes=$DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY
AgentlessVmScanning=$DEFENDER_CONTAINERS_VM_SCANNING
ContainerSensor=$DEFENDER_CONTAINERS_SENSOR"

    extension_result=0
    apply_plan_extensions CloudPosture "$cspm_tier" "$cspm_spec" || extension_result=$?
    if ((extension_result == 1)); then
        record_check "Defender CSPM extension configuration applied" fail "Azure rejected the Defender CSPM extension update. Check Microsoft.Security/pricings write permission and extension availability."
        failures=$((failures + 1))
    fi
    extension_result=0
    apply_plan_extensions Containers "$containers_tier" "$containers_spec" || extension_result=$?
    if ((extension_result == 1)); then
        record_check "Defender for Containers extension configuration applied" fail "Azure rejected the Defender for Containers extension update. Check Microsoft.Security/pricings write permission and extension availability."
        failures=$((failures + 1))
    fi

    if [[ "$cspm_tier" == Standard ]]; then
        record_extension_checks CloudPosture "Defender CSPM" \
"AgentlessServerlessPosture|$DEFENDER_CSPM_SERVERLESS_PROTECTION|Serverless protection for App Service and Functions
ServerlessContainers|$DEFENDER_CSPM_SERVERLESS_CONTAINERS|Serverless container posture for Container Apps and Container Instances
ContainerRegistriesVulnerabilityAssessments|$DEFENDER_CSPM_REGISTRY_ASSESSMENT|Registry access for container image posture
AgentlessDiscoveryForKubernetes|$DEFENDER_CSPM_KUBERNETES_DISCOVERY|Agentless Kubernetes discovery
AgentlessVmScanning|$DEFENDER_CSPM_VM_SCANNING|Agentless scanning for machines
SensitiveDataDiscovery|$DEFENDER_CSPM_SENSITIVE_DATA|Sensitive data discovery
EntraPermissionsManagement|$DEFENDER_CSPM_PERMISSIONS_MANAGEMENT|Cloud infrastructure entitlement management
ApiPosture|$DEFENDER_CSPM_API_POSTURE|API Security Posture"
    else
        record_check "Defender CSPM extensions" not_applicable "Defender CSPM is not at the Standard tier, so its extensions do not apply."
    fi
    if [[ "$containers_tier" == Standard ]]; then
        record_extension_checks Containers "Defender for Containers" \
"ContainerRegistriesVulnerabilityAssessments|$DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT|Security findings for Azure Container Registry images
AgentlessDiscoveryForKubernetes|$DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY|Agentless Kubernetes discovery
AgentlessVmScanning|$DEFENDER_CONTAINERS_VM_SCANNING|Agentless scanning for machines
ContainerSensor|$DEFENDER_CONTAINERS_SENSOR|Kubernetes runtime threat sensor"
    else
        record_check "Defender for Containers extensions" not_applicable "Defender for Containers is not at the Standard tier, so its extensions do not apply."
    fi

    write_status_html defender running "$(auto_percent 50)" "Checking the Defender for Cloud DevOps connector and GitHub Advanced Security state."
    ensure_devops_connector
    record_advanced_security_state

    write_status_html defender running "$(auto_percent 65)" "Reading the latest Defender for Cloud assessments for $RESOURCE_GROUP."
    assessment_json="$(az security assessment list --resource-group "$RESOURCE_GROUP" -o json 2>/dev/null || true)"
    if [[ -z "$assessment_json" ]]; then
        record_check "Defender assessment inventory returned data" unknown "The assessment query returned no payload. Defender may still be initializing, or the account may lack Microsoft.Security/assessments/read."
    else
        record_check "Defender assessment inventory returned data" pass "Retrieved the latest Defender assessment inventory for $RESOURCE_GROUP."
        if [[ "$assessment_json" == *"$DEFENDER_TARGET_CVE"* ]]; then
            target_found=0
            record_check "Target CVE appears in Defender findings" pass "$DEFENDER_TARGET_CVE was present in the latest Defender assessment payload."
        else
            record_check "Target CVE appears in Defender findings" unknown "$DEFENDER_TARGET_CVE was not present in this payload. Vulnerability assessment is asynchronous and may require the image scan to complete."
        fi
    fi

    if [[ "$appservices_tier" == Standard ]]; then
        record_check "App Service workload is covered for attack detection" pass "Defender for App Service monitors App Service requests/responses, platform logs, sandboxes, and hosting VMs."
    else
        record_check "App Service workload is covered for attack detection" not_applicable "Defender for App Service is not enabled at the configured tier."
    fi
    DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE="$(defender_extension_state CloudPosture AgentlessVmScanning)"
    DEFENDER_CSPM_API_POSTURE_AUDIT_STATE="$(defender_extension_state CloudPosture ApiPosture)"
    DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE="$(defender_extension_state Containers ContainerRegistriesVulnerabilityAssessments)"
    DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE="$(defender_extension_state Containers AgentlessVmScanning)"
    if [[ "$cspm_tier" != Standard || "$DEFENDER_CSPM_VM_SCANNING" != true ]]; then
        record_check "CSPM agentless scanning for machines is enabled and audited" not_applicable "Defender CSPM AgentlessVmScanning is not requested at the Standard tier."
    elif [[ "$DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE" == true ]]; then
        record_check "CSPM agentless scanning for machines is enabled and audited" pass "Azure reports AgentlessVmScanning enabled for Defender CSPM. Defender scans machines for installed software, vulnerabilities, and secrets without relying on agents or impacting machine performance. Learn more: https://aka.ms/agentlessscanazure"
    elif [[ "$DEFENDER_CSPM_MACHINE_SCAN_AUDIT_STATE" == unknown ]]; then
        record_check "CSPM agentless scanning for machines is enabled and audited" unknown "Azure did not return the Defender CSPM AgentlessVmScanning state, so the requested setting could not be audited."
    else
        record_check "CSPM agentless scanning for machines is enabled and audited" fail "Azure reports Defender CSPM AgentlessVmScanning disabled even though configuration requests it enabled."
        failures=$((failures + 1))
    fi
    if [[ "$cspm_tier" != Standard || "$DEFENDER_CSPM_API_POSTURE" != true ]]; then
        record_check "CSPM API Security Posture is enabled and audited" not_applicable "Defender CSPM ApiPosture is not requested at the Standard tier."
    elif [[ "$DEFENDER_CSPM_API_POSTURE_AUDIT_STATE" == true ]]; then
        record_check "CSPM API Security Posture is enabled and audited" pass "Azure reports ApiPosture enabled for Defender CSPM. API Security Posture provides unified visibility across APIs published through Azure API Management and helps assess misconfigurations, dormant APIs, exposed APIs, and APIs handling sensitive data; preview discovery also covers APIs in Azure App Services, Azure Functions, and Azure Logic Apps."
    elif [[ "$DEFENDER_CSPM_API_POSTURE_AUDIT_STATE" == unknown ]]; then
        record_check "CSPM API Security Posture is enabled and audited" unknown "Azure did not return the Defender CSPM ApiPosture state, so the requested setting could not be audited."
    else
        record_check "CSPM API Security Posture is enabled and audited" fail "Azure reports Defender CSPM ApiPosture disabled even though configuration requests it enabled."
        failures=$((failures + 1))
    fi
    if [[ "$containers_tier" != Standard || "$DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT" != true ]]; then
        record_check "Registry image security findings are enabled and audited" not_applicable "Defender for Containers registry vulnerability assessment is not requested at the Standard tier."
    elif [[ "$DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE" == true ]]; then
        record_check "Registry image security findings are enabled and audited" pass "Azure reports ContainerRegistriesVulnerabilityAssessments enabled. Defender generates security findings artifacts and links them to new or updated ACR images for evaluation."
    elif [[ "$DEFENDER_REGISTRY_FINDINGS_AUDIT_STATE" == unknown ]]; then
        record_check "Registry image security findings are enabled and audited" unknown "Azure did not return the ContainerRegistriesVulnerabilityAssessments state, so the requested setting could not be audited."
    else
        record_check "Registry image security findings are enabled and audited" fail "Azure reports ContainerRegistriesVulnerabilityAssessments disabled even though configuration requests it enabled."
        failures=$((failures + 1))
    fi
    if [[ "$containers_tier" != Standard || "$DEFENDER_CONTAINERS_VM_SCANNING" != true ]]; then
        record_check "Agentless scanning for machines is enabled and audited" not_applicable "Defender for Containers AgentlessVmScanning is not requested at the Standard tier."
    elif [[ "$DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE" == true ]]; then
        record_check "Agentless scanning for machines is enabled and audited" pass "Azure reports AgentlessVmScanning enabled. Defender scans machines for installed software, vulnerabilities, and secrets without relying on agents or impacting machine performance. Learn more: https://aka.ms/agentlessscanazure"
    elif [[ "$DEFENDER_AGENTLESS_MACHINE_SCAN_AUDIT_STATE" == unknown ]]; then
        record_check "Agentless scanning for machines is enabled and audited" unknown "Azure did not return the AgentlessVmScanning state, so the requested setting could not be audited."
    else
        record_check "Agentless scanning for machines is enabled and audited" fail "Azure reports AgentlessVmScanning disabled even though configuration requests it enabled."
        failures=$((failures + 1))
    fi
    if [[ "$arm_tier" == Standard ]]; then
        record_check "Control plane operations are monitored for threats" pass "Defender for Resource Manager watches the deployment, role assignment, and registry operations this lifecycle performs through ARM."
    else
        record_check "Control plane operations are monitored for threats" not_applicable "Defender for Resource Manager is not enabled at the configured tier."
    fi
    record_check "Kubernetes runtime workload coverage" not_applicable "This deployment runs a custom container on App Service; it does not deploy AKS/Kubernetes nodes or workloads."
    record_check "Unrequested Defender workload plans" not_applicable "Defender for Servers, SQL, Storage, Key Vault, and DNS are not requested because this scenario deploys no virtual machines, databases, storage accounts, key vaults, or private DNS zones."

    if ((failures > 0)); then
        set_task defender failure "$failures Defender plan activation check(s) failed. See the verification matrix for details."
        FAILURE_MESSAGE="$failures Defender plan activation check(s) failed."
        fail "$FAILURE_MESSAGE"
    fi
    if ((target_found != 0)); then
        set_task defender success "Defender plans, extensions, and workload coverage were verified; CVE findings remain asynchronous and are recorded as Not sure when absent."
    else
        set_task defender success "Defender plans, extensions, and workload coverage were verified; $DEFENDER_TARGET_CVE was found in the assessment payload."
    fi
    write_status_html defender success "$(auto_percent)" "Defender for Cloud scan, extension configuration, and workload coverage verification completed."
}

verify() {
    local app_host registry_login configured_image expected_image identity_name identity_principal role_count
    local status_json probe settle_attempts deployed_tags runtime_binary_version runtime_package_version failures=0
    set_task verify in_progress "Running the Azure configuration, identity, and endpoint verification matrix."
    write_status_html verifying running "$(auto_percent 10)" "Checking image configuration, ACR pull permissions, and application endpoints."

    app_host="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query defaultHostName -o tsv 2>/dev/null || true)"
    if [[ -n "$app_host" ]]; then
        APP_URL="https://$app_host"
        record_check "App Service exists and has a public hostname" pass "Default host name: $app_host"
    else
        record_check "App Service exists and has a public hostname" fail "App Service '$APP_SERVICE_NAME' was not found in resource group '$RESOURCE_GROUP'."
        failures=$((failures + 1))
    fi

    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv 2>/dev/null || true)"
    if [[ -n "$registry_login" ]]; then
        record_check "Container registry is reachable" pass "Login server: $registry_login"
    else
        record_check "Container registry is reachable" fail "ACR '$ACR_NAME' was not found in resource group '$RESOURCE_GROUP'."
        failures=$((failures + 1))
    fi

    if az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none 2>/dev/null; then
        record_check "Expected image tag exists in ACR" pass "Found $IMAGE_NAME:$IMAGE_TAG in $ACR_NAME."
    else
        record_check "Expected image tag exists in ACR" fail "Tag '$IMAGE_NAME:$IMAGE_TAG' is missing from registry '$ACR_NAME'. Re-run the build stage."
        failures=$((failures + 1))
    fi

    if [[ -z "$BUILD_FINGERPRINT" ]]; then
        BUILD_FINGERPRINT="$(compute_build_fingerprint)"
        FINGERPRINT_TAG="fp-$BUILD_FINGERPRINT"
    fi
    [[ -n "$IMAGE_DIGEST" ]] || IMAGE_DIGEST="$(acr_tag_digest "$IMAGE_TAG")"
    deployed_tags="$(acr_tags_for_digest "$IMAGE_DIGEST")"
    if [[ -z "$IMAGE_DIGEST" || -z "$deployed_tags" ]]; then
        record_check "Deployed image matches the current source fingerprint" unknown "Tags for $IMAGE_TAG could not be read from ACR, so content equivalence is undetermined."
    elif acr_digest_has_tag "$deployed_tags" "$FINGERPRINT_TAG"; then
        record_check "Deployed image matches the current source fingerprint" pass "Digest $IMAGE_DIGEST carries both $IMAGE_TAG and $FINGERPRINT_TAG (tags: $deployed_tags)."
    else
        record_check "Deployed image matches the current source fingerprint" fail "Digest $IMAGE_DIGEST carries tags [$deployed_tags] but not $FINGERPRINT_TAG. The running image does not match the working tree."
        failures=$((failures + 1))
    fi

    configured_image="$(az webapp config container show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query "[?name=='DOCKER_CUSTOM_IMAGE_NAME'].value | [0]" -o tsv 2>/dev/null || true)"
    expected_image="DOCKER|$registry_login/$IMAGE_NAME:$IMAGE_TAG"
    if [[ -z "$configured_image" ]]; then
        record_check "App Service runs the expected immutable image" unknown "Could not read the container configuration from App Service; the image in use is undetermined."
    elif [[ "$configured_image" == "$expected_image" ]]; then
        record_check "App Service runs the expected immutable image" pass "Configured image matches $expected_image"
    else
        record_check "App Service runs the expected immutable image" fail "Image drift: expected '$expected_image' but App Service is configured with '$configured_image'."
        failures=$((failures + 1))
    fi

    identity_name="${APP_SERVICE_NAME}-identity"
    identity_principal="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$identity_name" --query principalId -o tsv 2>/dev/null || true)"
    if [[ -z "$identity_principal" ]]; then
        record_check "User-assigned managed identity has AcrPull on the registry" fail "Managed identity '$identity_name' was not found, so the App Service cannot pull images without credentials."
        failures=$((failures + 1))
    else
        role_count="$(az role assignment list --assignee-object-id "$identity_principal" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME" --query "[?roleDefinitionName=='AcrPull'] | length(@)" -o tsv 2>/dev/null || printf '')"
        if [[ -z "$role_count" ]]; then
            record_check "User-assigned managed identity has AcrPull on the registry" unknown "Role assignments could not be listed; your account may lack Microsoft.Authorization/roleAssignments/read."
        elif ((role_count > 0)); then
            record_check "User-assigned managed identity has AcrPull on the registry" pass "Principal $identity_principal holds AcrPull scoped to $ACR_NAME."
        else
            record_check "User-assigned managed identity has AcrPull on the registry" fail "Principal $identity_principal has no AcrPull assignment on $ACR_NAME; image pulls will fail."
            failures=$((failures + 1))
        fi
    fi

    if [[ -z "$APP_URL" ]]; then
        record_check "Public site responds over HTTPS" not_applicable "No public hostname is available yet."
        record_check "Health endpoint responds over HTTPS" not_applicable "No public hostname is available yet."
        record_check "Runtime status API is serving JSON" not_applicable "No public hostname is available yet."
        record_check "Runtime reports the expected NGINX version" not_applicable "No public hostname is available yet."
        record_check "CVE detection API reports the expected result" not_applicable "No public hostname is available yet."
    else
        # A container that is still swapping answers 502 for a few seconds; retry before judging it.
        settle_attempts=0
        while ((settle_attempts < 12)); do
            settle_attempts=$((settle_attempts + 1))
            probe="$(http_probe "$APP_URL/health")"
            [[ "${probe%% *}" == 200 ]] && break
            echo "  endpoint not ready yet (attempt $settle_attempts/12, HTTP ${probe%% *}); retrying"
            write_status_html verifying running "$(auto_percent $((settle_attempts * 60 / 12)))" "Waiting for the application to answer before recording endpoint results (attempt $settle_attempts of 12)."
            sleep 10
        done

        probe="$(http_probe "$APP_URL/")"
        APP_HTTP_CODE="${probe%% *}"
        APP_RESPONSE_TIME="${probe##* }"
        if [[ "$APP_HTTP_CODE" == 200 ]]; then
            record_check "Public site responds over HTTPS" pass "GET $APP_URL/ returned HTTP 200 in ${APP_RESPONSE_TIME}s."
        elif [[ "$APP_HTTP_CODE" == 000 ]]; then
            record_check "Public site responds over HTTPS" fail "GET $APP_URL/ did not complete after $settle_attempts attempt(s) (DNS, TLS, or container start failure)."
            failures=$((failures + 1))
        else
            record_check "Public site responds over HTTPS" fail "GET $APP_URL/ returned HTTP $APP_HTTP_CODE after $settle_attempts attempt(s)."
            failures=$((failures + 1))
        fi

        probe="$(http_probe "$APP_URL/health")"
        HEALTH_HTTP_CODE="${probe%% *}"
        if [[ "$HEALTH_HTTP_CODE" == 200 ]]; then
            record_check "Health endpoint responds over HTTPS" pass "GET $APP_URL/health returned HTTP 200."
        else
            record_check "Health endpoint responds over HTTPS" fail "GET $APP_URL/health returned HTTP $HEALTH_HTTP_CODE after $settle_attempts attempt(s)."
            failures=$((failures + 1))
        fi

        status_json="$(fetch_app_status "${APP_URL#https://}")"
        if [[ -z "$status_json" ]]; then
            record_check "Runtime status API is serving JSON" fail "GET $APP_URL/api/status returned no body; the container is not serving the application."
            failures=$((failures + 1))
            record_check "Runtime reports the expected NGINX version" unknown "The status payload was unavailable, so the running NGINX version could not be confirmed."
            record_check "CVE detection API reports the expected result" unknown "The status payload was unavailable, so advisory-condition detection could not be confirmed."
        else
            echo "$status_json"
            record_check "Runtime status API is serving JSON" pass "GET $APP_URL/api/status returned a payload of ${#status_json} bytes from container $(status_field host "$status_json")."
            if [[ "$status_json" == *"\"${NGINX_VERSION}\""* ]]; then
                record_check "Runtime reports the expected NGINX version" pass "Status payload contains the expected NGINX version $NGINX_VERSION."
            else
                record_check "Runtime reports the expected NGINX version" unknown "Status payload does not contain NGINX $NGINX_VERSION. The running image may predate the current build arguments."
            fi
            if [[ "$VULNERABILITY_STATUS" == vulnerable && "$status_json" == *'"detected":true'* ]]; then
                record_check "CVE detection API reports the expected result" pass "The API detected CVE-2026-42533 from actual NGINX version and affected map/regex configuration evidence."
            elif [[ "$VULNERABILITY_STATUS" != vulnerable && "$status_json" == *'"detected":false'* ]]; then
                record_check "CVE detection API reports the expected result" pass "The API did not detect CVE-2026-42533 because the fixed NGINX/configuration conditions are not present."
            else
                record_check "CVE detection API reports the expected result" unknown "The API result did not match the requested scenario state; inspect detection_reason and runtime evidence."
            fi
            runtime_binary_version="$(status_field nginx_binary_version "$status_json")"
            runtime_package_version="$(status_field nginx_package_version "$status_json")"
            if [[ "$runtime_binary_version" == "$NGINX_VERSION" && -n "$runtime_package_version" ]]; then
                record_check "NGINX binary and package provenance is verified" pass "Container startup measured nginx/$runtime_binary_version from the binary and package version $runtime_package_version from dpkg-query."
            else
                record_check "NGINX binary and package provenance is verified" unknown "Container provenance evidence was incomplete (binary=${runtime_binary_version:-missing}, package=${runtime_package_version:-missing}); the API may be from an older image."
            fi
            if [[ "$VULNERABILITY_STATUS" == vulnerable && "$status_json" == *'"scenario_config_state":"affected"'* && "$status_json" == *'"map_regex_enabled":true'* ]]; then
                record_check "Scenario 1 vulnerable map/regex configuration is active" pass "Runtime evidence confirms the affected map directive with regex matching is enabled for the vulnerable image."
            elif [[ "$VULNERABILITY_STATUS" != vulnerable && "$status_json" == *'"scenario_config_state":"remediated"'* && "$status_json" == *'"map_regex_enabled":false'* ]]; then
                record_check "Scenario 1 vulnerable map/regex configuration is removed" pass "Runtime evidence confirms the affected map directive with regex matching is disabled in the remediated image."
            else
                record_check "Scenario 1 map/regex configuration state is verified" unknown "Runtime configuration evidence did not match the expected $VULNERABILITY_STATUS state; the running image may predate Scenario 1 configuration evidence."
            fi
        fi
    fi

    if ((failures > 0)); then
        set_task verify failure "$failures verification check(s) failed. See the verification matrix for the exact evidence."
        write_state verified failure "$failures verification checks failed"
        fail "Verification failed: $failures check(s) did not pass. Review the verification matrix in the report."
    fi

    set_task verify success "All blocking verification checks passed for $APP_URL."
    write_state verified success "Runtime and Azure configuration verified"
    echo -e "${GREEN}Verification passed: $APP_URL${NC}"
    write_status_html verified success "$(auto_percent)" "Deployment verified successfully at $APP_URL."
}

doctor() {
    local bicep_output="$OUTPUT_DIR/doctor-main.bicep.json" bicep_version
    local whatif_output="$OUTPUT_DIR/doctor-whatif-$ENVIRONMENT.txt"
    mkdir -p "$OUTPUT_DIR"

    set_task bicep in_progress "Checking the Azure CLI Bicep toolchain and compiling infra/main.bicep."
    echo -e "${YELLOW}Checking the Azure CLI Bicep toolchain...${NC}"
    if ! bicep_version="$(az bicep version 2>&1)"; then
        record_check "Azure CLI Bicep toolchain is available" fail "The host could not start the Bicep compiler."
        set_task bicep failure "The host Bicep toolchain is unavailable."
        if [[ "$bicep_version" == *"ICU"* || "$bicep_version" == *"icu"* ]]; then
            FAILURE_MESSAGE="The Bicep compiler requires ICU on this host. Install libicu (or icu-libs), then retry scripts/deploy.sh doctor."
        else
            FAILURE_MESSAGE="The Azure CLI Bicep toolchain is unavailable: $bicep_version"
        fi
        fail "$FAILURE_MESSAGE"
    fi
    record_check "Azure CLI Bicep toolchain is available" pass "Azure CLI Bicep $bicep_version is available on the host."
    set_task bicep in_progress "Compiling infra/main.bicep with the Azure CLI Bicep toolchain."
    echo -e "${YELLOW}Compiling Bicep...${NC}"
    if az bicep build --file "$AZURE_REPO_ROOT/infra/main.bicep" --outfile "$bicep_output" >/dev/null; then
        record_check "Bicep template compiles" pass "infra/main.bicep compiled cleanly to ARM JSON."
        set_task bicep success "infra/main.bicep compiles without errors."
    else
        record_check "Bicep template compiles" fail "infra/main.bicep failed to compile; the template cannot be deployed."
        set_task bicep failure "infra/main.bicep did not compile."
        FAILURE_MESSAGE="infra/main.bicep failed to compile. Fix the template before deploying."
        fail "$FAILURE_MESSAGE"
    fi
    rm -f "$bicep_output"
    write_status_html doctor running "$(auto_percent)" "Bicep compiled. Running the what-if analysis."

    set_task whatif in_progress "Running az deployment group what-if against $RESOURCE_GROUP."
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        if az deployment group what-if \
            --resource-group "$RESOURCE_GROUP" \
            --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
            --parameters containerRegistryName="$ACR_NAME" appServiceName="$APP_SERVICE_NAME" appServicePlanSku="$APP_SERVICE_PLAN_SKU" location="$LOCATION" \
            --result-format ResourceIdOnly | tee "$whatif_output"; then
            record_check "What-if analysis completed against the live resource group" pass "Predicted changes were written to doctor-whatif-$ENVIRONMENT.txt."
            set_task whatif success "What-if completed; the predicted change set is in doctor-whatif-$ENVIRONMENT.txt."
        else
            record_check "What-if analysis completed against the live resource group" fail "az deployment group what-if returned an error against $RESOURCE_GROUP."
            set_task whatif failure "What-if failed against $RESOURCE_GROUP."
            FAILURE_MESSAGE="The what-if analysis failed. The template and the live resource group may be incompatible."
            fail "$FAILURE_MESSAGE"
        fi
    else
        echo "Resource group does not exist yet; provision will create it."
        record_check "What-if analysis completed against the live resource group" not_applicable "Resource group $RESOURCE_GROUP does not exist yet, so there is nothing to compare against."
        set_task whatif skipped "Nothing to compare: $RESOURCE_GROUP does not exist yet and provision will create it."
    fi
    echo -e "${GREEN}Preflight checks passed.${NC}"
}

wizard() {
    local resource_group_exists=false app_service_exists=false registry_exists=false
    local managed environment_tag resource_count role_names selected_action=""

    set_task permissions in_progress "Checking subscription read access and assigned roles for $AZURE_ACCOUNT_NAME."
    if az group list --query 'length(@)' -o tsv >/dev/null 2>&1; then
        role_names="$(az role assignment list --assignee "$AZURE_ACCOUNT_NAME" --include-inherited --all --query '[].roleDefinitionName' -o tsv 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
        record_check "Subscription read access" pass "Azure CLI can list resource groups in subscription $SUBSCRIPTION_ID."
        if [[ -n "$role_names" ]]; then
            record_check "Assigned Azure roles" pass "Detected roles: $role_names."
        else
            record_check "Assigned Azure roles" unknown "The current identity can read the subscription, but role assignments were not available for inspection."
        fi
        set_task permissions success "Subscription read access confirmed for ${AZURE_ACCOUNT_NAME:-the current Azure identity}."
    else
        record_check "Subscription read access" fail "Azure CLI could not list resource groups in subscription $SUBSCRIPTION_ID."
        set_task permissions failure "Cannot inspect this subscription with the current Azure identity."
        FAILURE_MESSAGE="The current Azure identity cannot read subscription $SUBSCRIPTION_ID. Select another subscription or sign in with an appropriate role."
        fail "$FAILURE_MESSAGE"
    fi

    set_task discover in_progress "Inspecting the configured resource group and supported resources."
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        resource_group_exists=true
        resource_count="$(az resource list --resource-group "$RESOURCE_GROUP" --query 'length(@)' -o tsv 2>/dev/null || printf 'unknown')"
        managed="$(az group show --name "$RESOURCE_GROUP" --query 'tags."ninjapaws-managed"' -o tsv 2>/dev/null || true)"
        environment_tag="$(az group show --name "$RESOURCE_GROUP" --query 'tags."ninjapaws-environment"' -o tsv 2>/dev/null || true)"
        if [[ -n "$APP_SERVICE_NAME" ]] && az webapp show --name "$APP_SERVICE_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
            app_service_exists=true
        fi
        if [[ -n "$ACR_NAME" ]] && az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --output none 2>/dev/null; then
            registry_exists=true
        fi
        record_check "Configured resource group" pass "$RESOURCE_GROUP exists with $resource_count resource(s); tags managed=${managed:-missing}, environment=${environment_tag:-missing}."
        set_task discover success "$RESOURCE_GROUP exists; App Service=$app_service_exists, registry=$registry_exists."
    else
        record_check "Configured resource group" not_applicable "$RESOURCE_GROUP does not exist in subscription $SUBSCRIPTION_ID."
        set_task discover success "$RESOURCE_GROUP is absent; install/provision is available."
    fi

    set_task options in_progress "Evaluating lifecycle actions against the discovered environment state."
    echo
    echo "Ninja Paws management wizard"
    echo "Environment: $ENVIRONMENT"
    echo "Subscription: $SUBSCRIPTION_NAME ($(mask_identifier "$SUBSCRIPTION_ID"))"
    echo "Resource group: $RESOURCE_GROUP ($([[ "$resource_group_exists" == true ]] && printf 'present' || printf 'absent'))"
    echo
    echo "Available actions"
    echo "  1) Plan                 Always available; no Azure changes."
    echo "  2) Deploy               Available; provisions or updates the full dojo lifecycle."
    if [[ "$resource_group_exists" == false ]]; then
        echo "  3) Install/provision    Available; the configured resource group is absent."
    else
        echo "  -) Install/provision    Unavailable; the configured resource group already exists."
    fi
    if [[ "$app_service_exists" == true && "$registry_exists" == true ]]; then
        echo "  4) Verify               Available; App Service and registry were detected."
        echo "  5) Rollout              Available; App Service and registry were detected."
    else
        echo "  -) Verify/rollout       Unavailable; App Service and registry must both exist."
    fi
    if [[ "$resource_group_exists" == true ]]; then
        echo "  6) Repair               Available; the configured environment exists."
    else
        echo "  -) Repair               Unavailable; install the environment first."
    fi
    if [[ "$resource_group_exists" == true && "$managed" == true && "$environment_tag" == "$ENVIRONMENT" ]]; then
        echo "  7) Uninstall            Available; live ownership tags match this environment."
    else
        echo "  -) Uninstall            Unavailable; a matching tagged environment was not detected."
    fi

    if [[ -t 0 && "$USE_DEFAULTS" == false ]]; then
        read -r -p "Choose an available action, or press Enter to exit: " selected_action
        case "$selected_action" in
            1) selected_action=plan ;;
            2) selected_action=deploy ;;
            3) [[ "$resource_group_exists" == false ]] && selected_action=provision || selected_action="" ;;
            4) [[ "$app_service_exists" == true && "$registry_exists" == true ]] && selected_action=verify || selected_action="" ;;
            5) [[ "$app_service_exists" == true && "$registry_exists" == true ]] && selected_action=rollout || selected_action="" ;;
            6) [[ "$resource_group_exists" == true ]] && selected_action=repair || selected_action="" ;;
            7) [[ "$resource_group_exists" == true && "$managed" == true && "$environment_tag" == "$ENVIRONMENT" ]] && selected_action=uninstall || selected_action="" ;;
            '') ;;
            *) selected_action="" ;;
        esac
    fi
    set_task options success "Lifecycle actions were evaluated from the live environment state."

    if [[ -n "$selected_action" ]]; then
        echo "Starting '$selected_action' with the detected environment defaults."
        exec "$SCRIPT_DIR/deploy.sh" "$selected_action" --environment "$ENVIRONMENT" --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --defaults
    fi
}

uninstall() {
    local managed environment_tag resource_count
    set_task discover in_progress "Looking up $RESOURCE_GROUP in subscription $SUBSCRIPTION_ID."
    [[ -n "$RESOURCE_GROUP" ]] || fail "Resource group is required for uninstall."
    if ! az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        echo "Resource group '$RESOURCE_GROUP' does not exist."
        record_check "Target resource group exists" not_applicable "$RESOURCE_GROUP is already absent from subscription $SUBSCRIPTION_ID."
        set_task discover skipped "Nothing to remove: $RESOURCE_GROUP does not exist."
        set_task ownership not_applicable "No resource group to validate."
        set_task delete not_applicable "No resource group to delete."
        set_task teardown success "The environment is already fully torn down."
        record_check "Environment is fully removed" pass "$RESOURCE_GROUP is not present, so no Ninja Paws resources remain."
        finalize_report success "Nothing to uninstall; $RESOURCE_GROUP is already absent."
        exit 0
    fi
    resource_count="$(az resource list --resource-group "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || printf 'unknown')"
    record_check "Target resource group exists" pass "$RESOURCE_GROUP holds $resource_count resource(s)."
    set_task discover success "$RESOURCE_GROUP found with $resource_count resource(s)."

    set_task ownership in_progress "Checking the ninjapaws-managed and ninjapaws-environment tags."
    managed="$(az group show --name "$RESOURCE_GROUP" --query 'tags."ninjapaws-managed"' -o tsv)"
    environment_tag="$(az group show --name "$RESOURCE_GROUP" --query 'tags."ninjapaws-environment"' -o tsv)"
    if [[ "$managed" == true && "$environment_tag" == "$ENVIRONMENT" ]]; then
        record_check "Resource group is owned by Ninja Paws for this environment" pass "Tags ninjapaws-managed=true and ninjapaws-environment=$ENVIRONMENT are both present."
        set_task ownership success "Ownership confirmed via tags; deletion is safe."
    elif [[ "$FORCE" == true ]]; then
        record_check "Resource group is owned by Ninja Paws for this environment" unknown "Ownership tags did not match (managed='$managed', environment='$environment_tag') but --force was supplied, so the guard was bypassed."
        set_task ownership skipped "Ownership guard bypassed by --force; deleting an untagged or foreign resource group."
    else
        record_check "Resource group is owned by Ninja Paws for this environment" fail "Tags did not match (managed='$managed', environment='$environment_tag'); refusing to delete."
        set_task ownership failure "Refusing to delete: $RESOURCE_GROUP is not tagged as a Ninja Paws '$ENVIRONMENT' deployment."
        FAILURE_MESSAGE="Resource group is not tagged as a Ninja Paws '$ENVIRONMENT' deployment. Use --force only after checking its contents."
        fail "$FAILURE_MESSAGE"
    fi
    write_status_html uninstalling running "$(auto_percent)" "Ownership resolved. Awaiting deletion confirmation."

    confirm "Delete resource group '$RESOURCE_GROUP' in environment '$ENVIRONMENT' from subscription '$SUBSCRIPTION_ID'? This is destructive."
    set_task delete in_progress "Submitting the resource group deletion request."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    record_check "Deletion request accepted by Azure" pass "az group delete was accepted for $RESOURCE_GROUP; Azure removes the resources asynchronously."
    set_task delete success "Azure accepted the deletion of $RESOURCE_GROUP and $resource_count resource(s)."
    write_state uninstall requested "Resource group deletion requested"
    if [[ "$WAIT_FOR_DELETE" == true ]]; then
        set_task teardown in_progress "Polling Azure until $RESOURCE_GROUP disappears."
        while az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; do
            echo "Waiting for resource group deletion..."
            write_status_html uninstalling running "$(auto_percent 50)" "Waiting for Azure to finish removing $RESOURCE_GROUP."
            sleep 15
        done
        record_check "Environment is fully removed" pass "$RESOURCE_GROUP no longer exists in subscription $SUBSCRIPTION_ID."
        set_task teardown success "$RESOURCE_GROUP and all its resources are gone."
        write_state uninstall complete "Resource group deletion confirmed"
    else
        record_check "Environment is fully removed" unknown "Deletion was requested with --no-wait, so removal was not confirmed. Re-run without --no-wait, or check the portal."
        set_task teardown skipped "Not waited on: deletion runs asynchronously. Run uninstall without --no-wait to confirm removal."
    fi
    echo -e "${GREEN}Uninstall requested for '$RESOURCE_GROUP'.${NC}"
}

while (($# > 0)); do
    case "$1" in
        setup|provision|build|deploy|update|verify|repair|doctor|plan|rollout|wizard|uninstall)
            COMMAND="$1"
            shift
            ;;
        --environment|--subscription|--location|--resource-group|--registry-name|--app-service-name|--app-service-plan-sku|--image-name|--image-tag|--scenario)
            (($# >= 2)) || fail "$1 requires a value."
            case "$1" in
                --environment) ENVIRONMENT="$2" ;;
                --subscription) SUBSCRIPTION_ID="$2" ;;
                --location) LOCATION="$2" ;;
                --resource-group) RESOURCE_GROUP="$2" ;;
                --registry-name) REGISTRY_NAME="$2" ;;
                --app-service-name) APP_SERVICE_NAME="$2" ;;
                --app-service-plan-sku) APP_SERVICE_PLAN_SKU="$2" ;;
                --image-name) IMAGE_NAME="$2" ;;
                --image-tag) IMAGE_TAG="$2"; IMAGE_TAG_EXPLICIT=true ;;
                --scenario) SCENARIO_ID="$2" ;;
            esac
            shift 2
            ;;
        --yes) ASSUME_YES=true; shift ;;
        --defaults) USE_DEFAULTS=true; shift ;;
        --force) FORCE=true; shift ;;
        --force-rebuild) FORCE_REBUILD=true; shift ;;
        --all-scenarios) ALL_SCENARIOS=true; shift ;;
        --wait) WAIT_FOR_DELETE=true; WAIT_FOR_DELETE_EXPLICIT=true; shift ;;
        --no-wait) WAIT_FOR_DELETE=false; WAIT_FOR_DELETE_EXPLICIT=true; shift ;;
        --no-status-html) NO_STATUS_HTML=true; shift ;;
        --no-open-status) OPEN_STATUS_HTML=false; shift ;;
        --no-archive) ARCHIVE_OUTPUTS=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

register_lifecycle_tasks
trap on_exit EXIT
resolve_audit_context
resolve_settings
enforce_branch_environment
if [[ "$COMMAND" == plan ]]; then
    set_task preflight not_applicable "Skipped: plan is a dry run and never contacts Azure."
    print_plan
    finalize_report success "Dry run only. No Azure resources were inspected or changed."
    exit 0
fi

set_task preflight in_progress "Checking required tooling and the Azure sign-in context."
require_commands
record_check "Required local tooling is installed" pass "az, curl, git, and tr are all available on PATH."
authenticate
if [[ "$AUTHENTICATION_SKIPPED" == true ]]; then
    record_check "Azure CLI authentication" unknown "Azure login was not completed; no Azure resources were inspected or changed."
    set_task preflight skipped "Stopped before Azure inspection because authentication was not completed."
    set_task permissions skipped "Skipped: Azure authentication was not completed."
    set_task discover skipped "Skipped: Azure authentication was not completed."
    set_task options skipped "Skipped: Azure authentication was not completed."
    finalize_report success "Management wizard stopped cleanly before Azure inspection; no resources were changed."
    exit 0
fi
record_check "Azure CLI is authenticated and the subscription is selectable" pass "Operating against subscription $SUBSCRIPTION_ID."
set_task preflight success "Tooling present and authenticated against subscription $SUBSCRIPTION_ID."
print_plan
write_status_html preflight running "$(auto_percent)" "Preflight complete. Starting the $COMMAND lifecycle."

case "$COMMAND" in
    doctor)
        doctor
        finalize_report success "Preflight checks passed. No Azure resources were changed."
        ;;
    provision)
        confirm "Provision or update Azure infrastructure?"
        provision
        finalize_report success "Infrastructure provisioned. Run the build and rollout stages to publish the application."
        ;;
    build)
        build_image
        finalize_report success "Container images built and pushed. Run the rollout stage to publish them."
        ;;
    setup|deploy|update)
        confirm "Provision, build, deploy, and verify Azure resources?"
        provision
        build_image
        rollout_image
        verify
        run_defender_scan
        finalize_report success "Full lifecycle completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    repair)
        confirm "Repair Azure infrastructure and redeploy the selected image?"
        provision
        build_image
        rollout_image
        verify
        run_defender_scan
        finalize_report success "Repair completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    rollout)
        confirm "Roll out the already-built image to Azure App Service?"
        rollout_image
        verify
        run_defender_scan
        finalize_report success "Rollout completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    verify)
        verify
        run_defender_scan
        finalize_report success "Verification completed for ${APP_URL:-the App Service URL}."
        ;;
    wizard)
        wizard
        finalize_report success "Management wizard completed without changing Azure resources."
        ;;
    uninstall)
        uninstall
        if [[ "$WAIT_FOR_DELETE" == true ]]; then
            finalize_report success "Uninstall completed. $RESOURCE_GROUP and all of its resources are gone."
        else
            finalize_report success "Uninstall requested. Azure removes $RESOURCE_GROUP asynchronously because --no-wait was supplied."
        fi
        ;;
esac

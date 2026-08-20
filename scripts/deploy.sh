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
if command -v wslpath >/dev/null 2>&1; then
    AZURE_REPO_ROOT="$(wslpath -w "$REPO_ROOT")"
fi
for azure_cli_dir in "/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" "/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"; do
    if [[ ! -x "$azure_cli_dir/az.cmd" && -f "$azure_cli_dir/az.cmd" ]]; then
        export PATH="$azure_cli_dir:$PATH"
        break
    fi
done
if ! command -v az >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    windows_az_path="$(cmd.exe /c where az 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ -n "$windows_az_path" ]]; then
        azure_cli_dir="$(dirname "$(wslpath -u "$windows_az_path")")"
        export PATH="$azure_cli_dir:$PATH"
    fi
fi

# Windows az.cmd emits CRLF output when called from WSL/Git Bash.
az() {
    command az "$@" | tr -d '\r'
}

COMMAND="deploy"
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-auto}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOCATION="${AZURE_LOCATION:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
REGISTRY_NAME="${AZURE_CONTAINER_REGISTRY_NAME:-}"
APP_SERVICE_NAME="${AZURE_APP_SERVICE_NAME:-}"
IMAGE_NAME="${IMAGE_NAME:-ninjapaws-dojo}"
IMAGE_TAG="${IMAGE_TAG:-}"
BASE_OS_IMAGE="${BASE_OS_IMAGE:-ubuntu}"
BASE_OS_VERSION="${BASE_OS_VERSION:-24.04}"
NGINX_VERSION="${NGINX_VERSION:-1.30.3}"
VULNERABILITY_STATUS="${VULNERABILITY_STATUS:-vulnerable}"
NODE_MAJOR_VERSION="${NODE_MAJOR_VERSION:-20}"
PORT="${PORT:-3000}"
DEFENDER_ENABLED="${DEFENDER_ENABLED:-false}"
ASSUME_YES=false
FORCE=false
WAIT_FOR_DELETE=false
STATE_FILE=""
STATUS_HTML=""
STATUS_CONSOLE=""
OUTPUT_DIR=""
ARCHIVE_OUTPUTS=true
OUTPUT_ROOT="${OUTPUT_ROOT:-}"
CONSOLE_CAPTURE_STARTED=false
IMAGE_TAG_EXPLICIT=false
USE_DEFAULTS=false
OPEN_STATUS_HTML=true
RUN_STARTED_AT="$(date +%s)"

usage() {
    cat <<'EOF'
Manage the Ninja Paws Cloud Security Dojo Azure lifecycle.

Usage: scripts/deploy.sh <command> [options]

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
  uninstall                Delete the owned resource group (requires --yes or confirmation)

Options:
    --environment <dev|prod|auto> Deployment environment (default: detected from Git branch)
  --subscription <id>      Azure subscription ID (default: current subscription)
  --location <region>      Azure region (default: centralus)
  --resource-group <name>  Azure resource group
  --registry-name <name>   Azure Container Registry name
  --app-service-name <name> App Service name
  --image-name <name>      Container image repository (default: ninjapaws-dojo)
  --image-tag <tag>        Image tag (default: current Git SHA)
    --yes                    Skip confirmation; required for non-interactive uninstall
    --defaults               Accept built-in defaults without interactive prompts
  --force                  Allow uninstall of an untagged resource group
  --wait                   Wait for resource-group deletion to finish
    --no-status-html         Disable the auto-refreshing HTML status report
    --no-open-status         Keep the report on disk without opening a browser
    --no-archive             Delete the previous environment output instead of archiving it
  --help                   Show this help

OIDC bootstrap is separate and should be run once per GitHub Environment:
  scripts/setup-azure-github-oidc.sh --environment <dev|prod> --provision
EOF
}

fail() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

prompt_default() {
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

line_seen() {
    local needle="$1"
    local line
    [[ -f "$2" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$needle" ]] && return 0
    done < "$2"
    return 1
}

render_console_html() {
    local line
    [[ -f "$STATUS_CONSOLE" ]] || return 0
    tail -n 80 "$STATUS_CONSOLE" | while IFS= read -r line; do
        printf '<div class="console-line">%s</div>\n' "$(html_escape "$line")"
    done
}

open_status_html() {
    [[ "$OPEN_STATUS_HTML" == true && -n "$STATUS_HTML" ]] || return 0
    local windows_path
    print_report_link
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$STATUS_HTML" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$STATUS_HTML" >/dev/null 2>&1 &
    elif command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        windows_path="$(wslpath -w "$STATUS_HTML")"
        cmd.exe /c start "" "$windows_path" >/dev/null 2>&1 &
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Start-Process '$STATUS_HTML'" >/dev/null 2>&1 &
    fi
}

print_report_link() {
    [[ -n "$STATUS_HTML" ]] || return 0
    local report_url="file://$STATUS_HTML"
    local copy_command=""
    if command -v clip.exe >/dev/null 2>&1; then
        printf '%s' "$report_url" | clip.exe 2>/dev/null || true
        copy_command="copied to clipboard"
    elif command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$report_url" | pbcopy 2>/dev/null || true
        copy_command="copied to clipboard"
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$report_url" | wl-copy 2>/dev/null || true
        copy_command="copied to clipboard"
    fi
    echo -e "${BLUE}╭─ LIVE DEPLOYMENT REPORT ─────────────────────────────╮${NC}"
    printf "${BLUE}│${NC} %-50s ${BLUE}│${NC}\n" "Environment: $ENVIRONMENT"
    printf "${BLUE}│${NC} ${CYAN:-\033[0;36m}Report: %s${NC} ${BLUE}│${NC}\n" "$report_url"
    printf "${BLUE}│${NC} %-50s ${BLUE}│${NC}\n" "${copy_command:-Copy the URL above to open it}"
    echo -e "${BLUE}╰──────────────────────────────────────────────────────╯${NC}"
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
        waiting|starting) icon="…"; color="$YELLOW" ;;
        *) icon="•"; color="$BLUE" ;;
    esac
    printf "\n${color}%s %s %-12s [%s%s] %3s%%  +%ss${NC}\n" "$icon" "$phase" "$status" "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' "$empty" '')" "$percent" "$elapsed"
    printf "  ${BLUE}↳${NC} %s\n" "$detail"
    print_report_link
}

start_console_capture() {
    [[ "$CONSOLE_CAPTURE_STARTED" == true || "${NO_STATUS_HTML:-false}" == true || "${NO_CONSOLE_CAPTURE:-false}" == true ]] && return 0
    [[ -n "$STATUS_CONSOLE" ]] || return 0
    [[ -t 1 ]] || return 0
    CONSOLE_CAPTURE_STARTED=true
    exec > >(tee -a "$STATUS_CONSOLE") 2>&1
}

write_status_html() {
        local phase="$1"
        local status="$2"
        local percent="$3"
        local detail="${4:-}"
        local refresh=""
        [[ -n "$STATUS_HTML" ]] || return 0
        printf '[%s] %s: %s\n' "$(date -u +%H:%M:%SZ)" "$phase" "$detail" >> "$STATUS_CONSOLE"
        print_terminal_status "$phase" "$status" "$percent" "$detail"
        [[ "$status" == running || "$status" == starting ]] && refresh='<meta http-equiv="refresh" content="3">'
        mkdir -p "$(dirname "$STATUS_HTML")"
        cat > "$STATUS_HTML" <<EOF
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    $refresh
    <title>Ninja Paws Deployment - $(html_escape "$ENVIRONMENT")</title>
    <style>
        :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #eef3f8; color: #152238; }
        body { margin: 0; padding: 32px; background: radial-gradient(circle at 85% 0%, #cde7f2 0, transparent 35%), #eef3f8; }
        main { max-width: 980px; margin: auto; }
        header, section { background: #fff; border: 1px solid #dbe3ee; border-radius: 14px; box-shadow: 0 8px 24px #17203312; }
        header { padding: 28px; margin-bottom: 18px; border-top: 5px solid #d98932; }
        .brand { display: flex; align-items: center; gap: 12px; color: #102f4d; letter-spacing: .08em; font-size: 13px; }
        .brand small { display: block; color: #77869a; font-size: 9px; letter-spacing: .16em; margin-top: 3px; }
        .mark { display: grid; place-items: center; width: 44px; height: 44px; border-radius: 12px 12px 12px 4px; background: #102f4d; color: #f2a24a; font-weight: 800; letter-spacing: 0; }
        h1 { margin: 24px 0 8px; font-size: 30px; }
        p { margin: 6px 0; color: #5b6678; }
        section { padding: 22px; margin: 18px 0; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }
        .item { background: #f7f9fc; border-radius: 10px; padding: 14px; }
        .label { color: #68758a; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
        .value { margin-top: 5px; font-weight: 650; overflow-wrap: anywhere; }
        .bar { height: 14px; background: #e7edf5; border-radius: 99px; overflow: hidden; margin: 14px 0 8px; }
        .fill { height: 100%; width: ${percent}%; background: linear-gradient(90deg, #1769aa, #27a36a); transition: width .4s ease; }
        .status { display: inline-block; padding: 5px 10px; border-radius: 99px; background: #e7f5ee; color: #176b43; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; font-size: 12px; }
        .console { background: #101b2d; color: #d9e7f5; border-radius: 10px; padding: 16px; max-height: 280px; overflow: auto; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 12px; line-height: 1.55; }
        .console-line { white-space: pre-wrap; overflow-wrap: anywhere; border-bottom: 1px solid #ffffff12; padding: 2px 0; }
        iframe { width: 100%; height: 300px; border: 0; border-radius: 10px; background: #101b2d; }
        code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 13px; }
        a { color: #1769aa; }
        @media (max-width: 600px) { body { padding: 14px; } h1 { font-size: 23px; } }
    </style>
</head>
<body>
<main>
    <header>
        <div class="brand"><span class="mark">NP</span><span><strong>NINJA PAWS</strong><small> CLOUD SECURITY DOJO</small></span></div>
        <h1>Deployment control room</h1>
        <p>Live Azure deployment status for <strong>$(html_escape "$ENVIRONMENT")</strong>.</p>
        <p class="status">$(html_escape "$status")</p>
    </header>
    <section>
        <div class="label">Progress</div>
        <div class="bar"><div class="fill"></div></div>
        <strong>${percent}%</strong>
        <p>$(html_escape "$detail")</p>
    </section>
    <section class="grid">
        <div class="item"><div class="label">Environment</div><div class="value">$(html_escape "$ENVIRONMENT")</div></div>
        <div class="item"><div class="label">Subscription</div><div class="value"><code>$(html_escape "$SUBSCRIPTION_ID")</code></div></div>
        <div class="item"><div class="label">Resource group</div><div class="value">$(html_escape "$RESOURCE_GROUP")</div></div>
        <div class="item"><div class="label">Region</div><div class="value">$(html_escape "$LOCATION")</div></div>
        <div class="item"><div class="label">Registry</div><div class="value">$(html_escape "$ACR_NAME")</div></div>
        <div class="item"><div class="label">App Service</div><div class="value">$(html_escape "$APP_SERVICE_NAME")</div></div>
        <div class="item"><div class="label">Image</div><div class="value"><code>$(html_escape "$IMAGE_NAME:$IMAGE_TAG")</code></div></div>
        <div class="item"><div class="label">Updated</div><div class="value">$(date -u +%Y-%m-%dT%H:%M:%SZ)</div></div>
    </section>
    <section>
        <div class="label">Diagnostics</div>
        <p>Detailed deployment output is written to <a href="deployment-$ENVIRONMENT.log"><code>deployment-$ENVIRONMENT.log</code></a>.</p>
        <p>State manifest: <a href="deployment-$ENVIRONMENT.json"><code>deployment-$ENVIRONMENT.json</code></a></p>
    </section>
    <section>
        <div class="label">Live console</div>
        <div class="console">$(render_console_html)</div>
        <p>Complete terminal stream:</p>
        <iframe src="deployment-$ENVIRONMENT.console" title="Complete deployment console"></iframe>
    </section>
</main>
</body>
</html>
EOF
}

write_state() {
    local phase="$1"
    local status="$2"
    local message="${3:-}"
    mkdir -p "$OUTPUT_DIR"
    cat > "$STATE_FILE" <<EOF
{
  "environment": "$ENVIRONMENT",
  "subscriptionId": "$SUBSCRIPTION_ID",
  "resourceGroup": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "registryName": "$ACR_NAME",
  "appServiceName": "$APP_SERVICE_NAME",
  "imageName": "$IMAGE_NAME",
  "imageTag": "$IMAGE_TAG",
  "phase": "$phase",
  "status": "$status",
  "message": "$message",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

resolve_settings() {
    if [[ "$ENVIRONMENT" == auto ]]; then
        local branch_name
        branch_name="$(git branch --show-current 2>/dev/null || true)"
        case "$branch_name" in
            dev) ENVIRONMENT=dev ;;
            main) ENVIRONMENT=prod ;;
            *) fail "Cannot detect deployment environment from Git branch '$branch_name'. Use --environment dev or --environment prod." ;;
        esac
    fi

    case "$ENVIRONMENT" in
        dev)
            LOCATION="${LOCATION:-centralus}"
            RESOURCE_GROUP="${RESOURCE_GROUP:-NP-ninjapaws-dojo-Dev-CentralUS}"
            REGISTRY_NAME="${REGISTRY_NAME:-ninjapawsdojodev}"
            APP_SERVICE_NAME="${APP_SERVICE_NAME:-ninjapaws-dojo-app-dev}"
            ;;
        prod)
            LOCATION="${LOCATION:-centralus}"
            RESOURCE_GROUP="${RESOURCE_GROUP:-NP-ninjapaws-dojo-CentralUS}"
            REGISTRY_NAME="${REGISTRY_NAME:-ninjapawsdojo}"
            APP_SERVICE_NAME="${APP_SERVICE_NAME:-ninjapaws-dojo-app}"
            ;;
        *)
            fail "--environment must be dev, prod, or auto."
            ;;
    esac

    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan ]]; then
        LOCATION="$(prompt_default 'Azure region' "$LOCATION")"
        RESOURCE_GROUP="$(prompt_default 'Resource group' "$RESOURCE_GROUP")"
        REGISTRY_NAME="$(prompt_default 'Container Registry' "$REGISTRY_NAME")"
        APP_SERVICE_NAME="$(prompt_default 'App Service' "$APP_SERVICE_NAME")"
    fi

    ACR_NAME="${REGISTRY_NAME//-/}"
    [[ "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]] || fail "ACR name must be 5-50 lowercase letters or numbers after hyphen removal."
    output_base="${OUTPUT_ROOT:-$INVOCATION_DIR/output}"
    OUTPUT_DIR="$output_base/$ENVIRONMENT"
    if [[ -d "$OUTPUT_DIR" ]]; then
        if [[ "$ARCHIVE_OUTPUTS" == true ]]; then
            archive_dir="$output_base/archive/$(date -u +%Y%m%dT%H%M%SZ)-$ENVIRONMENT"
            mkdir -p "$output_base/archive"
            if ! mv "$OUTPUT_DIR" "$archive_dir" 2>/dev/null; then
                OUTPUT_DIR="$output_base/$ENVIRONMENT/$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
                echo -e "${YELLOW}Previous output is locked; using fresh run directory: $OUTPUT_DIR${NC}"
            fi
        else
            rm -rf "$OUTPUT_DIR"
        fi
    fi
    mkdir -p "$OUTPUT_DIR"
    rm -f "$REPO_ROOT/deployment-output.json"
    STATE_FILE="$OUTPUT_DIR/deployment-$ENVIRONMENT.json"
    [[ "${NO_STATUS_HTML:-false}" == true ]] || STATUS_HTML="$OUTPUT_DIR/deployment-$ENVIRONMENT.html"
    STATUS_CONSOLE="$OUTPUT_DIR/deployment-$ENVIRONMENT.console"
    ACR_NAME="${REGISTRY_NAME//-/}"
    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan ]]; then
        : > "$STATUS_CONSOLE"
        write_status_html awaiting_user waiting 0 "Waiting for your input. The terminal is asking for deployment values; press Enter to accept each default."
        open_status_html
    fi
    start_console_capture
    if [[ "$COMMAND" == verify && "$IMAGE_TAG_EXPLICIT" == false && -f "$STATE_FILE" ]]; then
        IMAGE_TAG="$(sed -n 's/.*"imageTag": "\([^"]*\)".*/\1/p' "$STATE_FILE")"
    fi
    IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
    write_status_html planning starting 0 "Resolved deployment settings and waiting for the selected lifecycle stage."
    open_status_html
}

enforce_branch_environment() {
    case "$COMMAND" in
        setup|provision|build|deploy|update|repair|rollout|uninstall) ;;
        *) return 0 ;;
    esac

    local branch_name expected_environment
    branch_name="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || true)}"
    case "$branch_name" in
        dev) expected_environment=dev ;;
        main) expected_environment=prod ;;
        *) fail "Mutating command '$COMMAND' requires branch 'dev' or 'main'; current branch is '$branch_name'." ;;
    esac
    [[ "$ENVIRONMENT" == "$expected_environment" ]] || fail "Branch '$branch_name' can only target environment '$expected_environment', not '$ENVIRONMENT'."
}

require_commands() {
    local command_name
    for command_name in az curl git tr; do
        command -v "$command_name" >/dev/null 2>&1 || fail "'$command_name' is required."
    done
}

authenticate() {
    if ! az account show >/dev/null 2>&1; then
        echo -e "${YELLOW}Azure CLI is not authenticated. Starting device-code login.${NC}"
        az login --use-device-code >/dev/null
    fi
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        az account set --subscription "$SUBSCRIPTION_ID" || fail "Unable to select subscription '$SUBSCRIPTION_ID'."
    fi
    SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
}

print_plan() {
    echo -e "${BLUE}Deployment plan${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Subscription: ${SUBSCRIPTION_ID:-current Azure subscription}"
    echo "Resource group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Registry: $ACR_NAME"
    echo "App Service: $APP_SERVICE_NAME"
    echo "Image: $IMAGE_NAME:$IMAGE_TAG"
    echo "Bicep: $REPO_ROOT/infra/main.bicep"
    echo "State: $STATE_FILE"
    [[ -n "$STATUS_HTML" ]] && echo "Live status: $STATUS_HTML"
}

run_bicep_deployment() {
    local deployment_name="$1"
    local deployment_output="$OUTPUT_DIR/deployment-output.json"
    local deployment_log="$OUTPUT_DIR/deployment-$ENVIRONMENT.log"
    local operations_seen="$OUTPUT_DIR/deployment-$ENVIRONMENT.operations"
    local deployment_pid state succeeded failed running percent operation_lines operation_line
    local expected_operations=6

    : > "$deployment_log"
    : > "$operations_seen"
    echo -e "${BLUE}Bicep deployment: $deployment_name${NC}"
    echo "Detailed Azure CLI output: $deployment_log"
    write_status_html provisioning running 5 "Submitting Bicep infrastructure deployment."

    az deployment group create \
        --name "$deployment_name" \
        --resource-group "$RESOURCE_GROUP" \
        --mode Incremental \
        --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
        --parameters \
            containerRegistryName="$ACR_NAME" \
            appServiceName="$APP_SERVICE_NAME" \
            location="$LOCATION" \
            imageName="$IMAGE_NAME" \
            imageTag=latest \
            nginxVersion="$NGINX_VERSION" \
            vulnerabilityStatus="$VULNERABILITY_STATUS" \
            port="$PORT" \
            defenderEnabled="$DEFENDER_ENABLED" \
        --output json > "$deployment_output" 2> "$deployment_log" &
    deployment_pid=$!

    while kill -0 "$deployment_pid" 2>/dev/null; do
        state="$(az deployment group show --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query properties.provisioningState -o tsv 2>/dev/null || true)"
        succeeded="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Succeeded'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        failed="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Failed'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        running="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[?properties.provisioningState=='Running' || properties.provisioningState=='Accepted'] | length(@)" -o tsv 2>/dev/null || printf '0')"
        operation_lines="$(az deployment operation group list --name "$deployment_name" --resource-group "$RESOURCE_GROUP" --query "[].{state:properties.provisioningState,resource:targetResource.resourceName,type:targetResource.resourceType}" -o tsv 2>/dev/null || true)"

        if [[ "$succeeded" =~ ^[0-9]+$ ]]; then
            percent=$((10 + succeeded * 85 / expected_operations))
            ((percent > 95)) && percent=95
        else
            percent=10
        fi
        printf '[%3s%%] state=%s succeeded=%s running=%s failed=%s\n' "$percent" "${state:-starting}" "$succeeded" "$running" "$failed"
        write_status_html provisioning running "$percent" "Azure state: ${state:-starting}; succeeded=$succeeded; running=$running; failed=$failed."

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
        echo -e "${RED}Bicep deployment failed. Full CLI details:${NC}"
        cat "$deployment_log"
        return 1
    }
    printf '[100%%] state=Succeeded succeeded=%s running=0 failed=%s\n' "$succeeded" "$failed"
    write_status_html provisioning success 100 "Bicep infrastructure completed successfully."
    echo -e "${GREEN}Bicep deployment completed.${NC}"
}

provision() {
    echo -e "${YELLOW}Provisioning resource group and Bicep infrastructure...${NC}"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    az tag update \
        --resource-id "$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)" \
        --operation Merge \
        --tags ninjapaws-managed=true ninjapaws-environment="$ENVIRONMENT" \
        --output none

    run_bicep_deployment "ninjapaws-dojo-$(date +%s)"
    write_state provisioned success "Bicep infrastructure applied"
}

build_image() {
    local registry_login
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)" || fail "ACR '$ACR_NAME' was not found. Run provision first."
    echo -e "${YELLOW}Building and pushing $registry_login/$IMAGE_NAME:$IMAGE_TAG...${NC}"
    write_status_html building running 55 "Building and pushing the versioned, latest, and training-status images to ACR."
    az acr build \
        --registry "$ACR_NAME" \
        --image "$IMAGE_NAME:$IMAGE_TAG" \
        --image "$IMAGE_NAME:latest" \
        --image "$IMAGE_NAME:$VULNERABILITY_STATUS" \
        --build-arg "BASE_OS_IMAGE=$BASE_OS_IMAGE" \
        --build-arg "BASE_OS_VERSION=$BASE_OS_VERSION" \
        --build-arg "NODE_MAJOR_VERSION=$NODE_MAJOR_VERSION" \
        --build-arg "NGINX_VERSION=$NGINX_VERSION" \
        --build-arg "VULNERABILITY_STATUS=$VULNERABILITY_STATUS" \
        --build-arg "PORT=$PORT" \
        --build-arg "DEFENDER_ENABLED=$DEFENDER_ENABLED" \
        "$AZURE_REPO_ROOT"
    write_state image-built success "Image pushed to ACR"
    write_status_html building success 70 "Container images pushed to ACR."
}

rollout_image() {
    local registry_login identity_client_id image_reference
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none || fail "Image '$IMAGE_NAME:$IMAGE_TAG' is not present in ACR."
    identity_client_id="$(az identity show --resource-group "$RESOURCE_GROUP" --name "${APP_SERVICE_NAME}-identity" --query clientId -o tsv)"
    image_reference="DOCKER|$registry_login/$IMAGE_NAME:$IMAGE_TAG"
    echo -e "${YELLOW}Configuring App Service for immutable image $IMAGE_TAG...${NC}"
    write_status_html deploying running 75 "Configuring App Service with the immutable container image and managed identity."
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
    az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --output none
    write_state rolled-out success "App Service configured for immutable image"
    write_status_html deploying success 85 "App Service configured and restarted."
}

verify() {
    local app_host registry_login configured_image identity_name identity_principal role_count status_json
    write_status_html verifying running 90 "Checking image configuration, ACR pull permissions, and application endpoints."
    app_host="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query defaultHostName -o tsv)" || fail "App Service was not found."
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)" || fail "ACR was not found."
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none || fail "Expected image tag is missing from ACR."
    configured_image="$(az webapp config container show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query "[?name=='DOCKER_CUSTOM_IMAGE_NAME'].value | [0]" -o tsv)"
    expected_image="DOCKER|$registry_login/$IMAGE_NAME:$IMAGE_TAG"
    [[ "$configured_image" == "$expected_image" ]] || fail "App Service image drifted: expected '$expected_image', found '$configured_image'."

    identity_name="${APP_SERVICE_NAME}-identity"
    identity_principal="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$identity_name" --query principalId -o tsv)"
    role_count="$(az role assignment list --assignee-object-id "$identity_principal" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME" --query "[?roleDefinitionName=='AcrPull'] | length(@)" -o tsv)"
    [[ "$role_count" -gt 0 ]] || fail "App Service managed identity does not have AcrPull on the registry."

    status_json="$(curl -fsS "https://$app_host/api/status")" || fail "The application status endpoint is unavailable."
    curl -fsS "https://$app_host/health" >/dev/null || fail "The application health endpoint is unavailable."
    echo "$status_json"
    if [[ "$status_json" != *"\"${NGINX_VERSION}\""* ]]; then
        echo -e "${YELLOW}Warning: runtime status does not contain expected NGINX version $NGINX_VERSION.${NC}"
    fi
    if [[ "$status_json" != *"\"${VULNERABILITY_STATUS}\""* ]]; then
        echo -e "${YELLOW}Warning: runtime status does not contain expected training status $VULNERABILITY_STATUS.${NC}"
    fi
    write_state verified success "Runtime and Azure configuration verified"
    echo -e "${GREEN}Verification passed: https://$app_host${NC}"
    write_status_html verified success 100 "Deployment verified successfully at https://$app_host."
}

doctor() {
    require_commands
    authenticate
    echo -e "${YELLOW}Compiling Bicep...${NC}"
    local bicep_output="$OUTPUT_DIR/doctor-main.bicep.json"
    mkdir -p "$OUTPUT_DIR"
    az bicep build --file "$AZURE_REPO_ROOT/infra/main.bicep" --outfile "$bicep_output" >/dev/null
    rm -f "$bicep_output"
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        az deployment group what-if \
            --resource-group "$RESOURCE_GROUP" \
            --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
            --parameters containerRegistryName="$ACR_NAME" appServiceName="$APP_SERVICE_NAME" location="$LOCATION" \
            --result-format ResourceIdOnly
    else
        echo "Resource group does not exist yet; provision will create it."
    fi
    echo -e "${GREEN}Preflight checks passed.${NC}"
}

uninstall() {
    local managed environment_tag
    [[ -n "$RESOURCE_GROUP" ]] || fail "Resource group is required for uninstall."
    az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null || { echo "Resource group '$RESOURCE_GROUP' does not exist."; exit 0; }
    managed="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-managed']" -o tsv)"
    environment_tag="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-environment']" -o tsv)"
    if [[ "$managed" != true || "$environment_tag" != "$ENVIRONMENT" ]]; then
        [[ "$FORCE" == true ]] || fail "Resource group is not tagged as a Ninja Paws '$ENVIRONMENT' deployment. Use --force only after checking its contents."
    fi
    confirm "Delete resource group '$RESOURCE_GROUP' in environment '$ENVIRONMENT' from subscription '$SUBSCRIPTION_ID'? This is destructive."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    write_state uninstall requested "Resource group deletion requested"
    if [[ "$WAIT_FOR_DELETE" == true ]]; then
        while az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; do
            echo "Waiting for resource group deletion..."
            sleep 15
        done
        write_state uninstall complete "Resource group deletion confirmed"
    fi
    echo -e "${GREEN}Uninstall requested for '$RESOURCE_GROUP'.${NC}"
}

while (($# > 0)); do
    case "$1" in
        setup|provision|build|deploy|update|verify|repair|doctor|plan|rollout|uninstall)
            COMMAND="$1"
            shift
            ;;
        --environment|--subscription|--location|--resource-group|--registry-name|--app-service-name|--image-name|--image-tag)
            (($# >= 2)) || fail "$1 requires a value."
            case "$1" in
                --environment) ENVIRONMENT="$2" ;;
                --subscription) SUBSCRIPTION_ID="$2" ;;
                --location) LOCATION="$2" ;;
                --resource-group) RESOURCE_GROUP="$2" ;;
                --registry-name) REGISTRY_NAME="$2" ;;
                --app-service-name) APP_SERVICE_NAME="$2" ;;
                --image-name) IMAGE_NAME="$2" ;;
                --image-tag) IMAGE_TAG="$2"; IMAGE_TAG_EXPLICIT=true ;;
            esac
            shift 2
            ;;
        --yes) ASSUME_YES=true; shift ;;
        --defaults) USE_DEFAULTS=true; shift ;;
        --force) FORCE=true; shift ;;
        --wait) WAIT_FOR_DELETE=true; shift ;;
        --no-status-html) NO_STATUS_HTML=true; shift ;;
        --no-open-status) OPEN_STATUS_HTML=false; shift ;;
        --no-archive) ARCHIVE_OUTPUTS=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

resolve_settings
enforce_branch_environment
if [[ "$COMMAND" == plan ]]; then
    print_plan
    exit 0
fi

require_commands
authenticate
print_plan

case "$COMMAND" in
    doctor)
        doctor
        ;;
    provision)
        confirm "Provision or update Azure infrastructure?"
        provision
        ;;
    build)
        build_image
        ;;
    setup|deploy|update)
        confirm "Provision, build, deploy, and verify Azure resources?"
        provision
        build_image
        rollout_image
        verify
        ;;
    repair)
        confirm "Repair Azure infrastructure and redeploy the selected image?"
        provision
        build_image
        rollout_image
        verify
        ;;
    rollout)
        confirm "Roll out the already-built image to Azure App Service?"
        rollout_image
        verify
        ;;
    verify)
        verify
        ;;
    uninstall)
        uninstall
        ;;
esac

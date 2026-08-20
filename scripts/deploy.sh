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
if ! command -v az >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    windows_az_path="$(cmd.exe /c where az 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ -n "$windows_az_path" ]]; then
        azure_cli_dir="$(dirname "$(wslpath -u "$windows_az_path")")"
        export PATH="$azure_cli_dir:$PATH"
    fi
fi

# Windows az.cmd emits CRLF output when called from WSL/Git Bash. MSYS also rewrites arguments that
# look like Unix paths, which would corrupt resource IDs and role-assignment scopes, so exclude those.
az() {
    MSYS2_ARG_CONV_EXCL='/subscriptions/;/providers/;/resourceGroups/' command az "$@" | tr -d '\r'
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
FORCE_REBUILD=false
WAIT_FOR_DELETE=false
STATE_FILE=""
STATUS_HTML=""
STATUS_CONSOLE=""
STATUS_RAW_CONSOLE=""
OUTPUT_DIR=""
ARCHIVE_OUTPUTS=true
OUTPUT_ROOT="${OUTPUT_ROOT:-}"
CONSOLE_CAPTURE_STARTED=false
CONSOLE_AUTORELOAD=true
IMAGE_TAG_EXPLICIT=false
USE_DEFAULTS=false
OPEN_STATUS_HTML=true
RUN_STARTED_AT="$(date +%s)"

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
            ;;
        verify)
            register_task verify "Verify Azure configuration, identity, and live endpoints"
            ;;
        doctor)
            register_task bicep "Compile the Bicep template"
            register_task whatif "Run a what-if against the target resource group"
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
  --force-rebuild          Rebuild and redeploy even when the image content is unchanged
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
    FAILURE_MESSAGE="$1"
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

write_console_html() {
        local line line_number=0 reload_script=""
        [[ -n "$STATUS_CONSOLE" ]] || return 0
        if [[ "${CONSOLE_AUTORELOAD:-true}" == true ]]; then
            reload_script='        window.setTimeout(function () { window.location.reload(); }, 3000);'
        fi
        cat > "$STATUS_CONSOLE" <<EOF
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
        .line { display: grid; grid-template-columns: 52px 1fr; min-width: max-content; border-bottom: 1px solid #ffffff0b; }
        .number { padding: 5px 10px; color: #58718b; text-align: right; user-select: none; background: #0a1524; }
        .text { padding: 5px 14px; white-space: pre-wrap; overflow-wrap: anywhere; }
        .empty { color: #58718b; padding: 24px; text-align: center; }
    </style>
</head>
<body>
    <header><span class="mark">NP</span><span><strong>NINJA PAWS DEPLOYMENT CONSOLE</strong><small>LIVE RAW TERMINAL STREAM &middot; $(html_escape "$ENVIRONMENT")</small></span></header>
    <div class="terminal" id="terminal">
EOF
        if [[ -s "$STATUS_RAW_CONSOLE" ]]; then
                while IFS= read -r line; do
                        line_number=$((line_number + 1))
                        printf '    <div class="line"><span class="number">%s</span><span class="text">%s</span></div>\n' "$line_number" "$(html_escape "$line")" >> "$STATUS_CONSOLE"
                    done < "$STATUS_RAW_CONSOLE"
        else
                    printf '    <div class="empty">Waiting for deployment output...</div>\n' >> "$STATUS_CONSOLE"
        fi
                cat >> "$STATUS_CONSOLE" <<EOF
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
</body>
</html>
EOF
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
        failed) icon="✗"; color="$RED" ;;
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
    exec > >(tee -a "$STATUS_RAW_CONSOLE") 2>&1
}

render_task_rows() {
    local i status label detail started ended elapsed icon cls text
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
        if ((started > 0)); then
            if ((ended > 0)); then
                elapsed=$((ended - started))
            else
                elapsed=$(( $(date +%s) - started ))
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
        printf '<div class="task-meta"><span class="pill %s">%s</span><span class="elapsed">%s</span></div></div>\n' \
            "$cls" "$text" "$(format_duration "$elapsed")"
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
    local rg_url app_url_portal acr_url reachable
    rg_url="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview"
    app_url_portal="$(portal_link "/providers/Microsoft.Web/sites/$APP_SERVICE_NAME")"
    acr_url="$(portal_link "/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME")"

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
}

command_noun() {
    case "$COMMAND" in
        uninstall)              printf 'teardown' ;;
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
    local outcome="$1"
    if [[ "$outcome" == failure ]]; then
        cat <<EOF
        <li><strong>Read the failure detail above</strong>, then open the <a href="deployment-$ENVIRONMENT.console.html">full console stream</a> and <a href="deployment-$ENVIRONMENT.log"><code>deployment-$ENVIRONMENT.log</code></a> for the raw Azure CLI error.</li>
        <li>Re-run preflight only: <code>scripts/deploy.sh doctor --environment $ENVIRONMENT --defaults</code></li>
        <li>Re-run the failed command once the cause is fixed: <code>scripts/deploy.sh $COMMAND --environment $ENVIRONMENT --defaults</code></li>
        <li>If Azure resources are in a half-built state, repair them: <code>scripts/deploy.sh repair --environment $ENVIRONMENT --defaults</code></li>
        <li>If the container will not start, tail its logs: <code>az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_SERVICE_NAME</code></li>
        <li>As a last resort, tear down and start clean: <code>scripts/deploy.sh uninstall --environment $ENVIRONMENT --yes --wait</code></li>
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
        <li>Re-run with <code>--wait</code> if you need the command to block until every resource is gone.</li>
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
        <li><strong>Exercise the training scenario</strong>: the image was built with training status <code>$(html_escape "$VULNERABILITY_STATUS")</code> on NGINX <code>$(html_escape "$NGINX_VERSION")</code>. Compare <code>/api/status</code> against those values before running an exercise.</li>
        <li><strong>Run the automated smoke tests</strong>: <code>scripts/test.sh</code></li>
        <li><strong>Re-verify at any time without redeploying</strong>: <code>scripts/deploy.sh verify --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Re-running deploy is cheap</strong>: the build context is fingerprinted, so an unchanged image is neither rebuilt nor re-uploaded and a healthy App Service is not restarted. Force a full rebuild with <code>--force-rebuild</code>.</li>
        <li><strong>Rotate the scenario</strong>: <code>VULNERABILITY_STATUS=patched scripts/deploy.sh deploy --environment $ENVIRONMENT --defaults</code></li>
        <li><strong>Review cost and exposure</strong> in the <a href="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview" target="_blank" rel="noopener">resource group</a>. This environment is intentionally vulnerable &mdash; keep it isolated and delete it when the exercise ends: <code>scripts/deploy.sh uninstall --environment $ENVIRONMENT --yes --wait</code></li>
EOF
            ;;
    esac
}

finalize_report() {
    local result="$1"
    local detail="${2:-}"
    if [[ "$RUN_FINAL" == true ]]; then
        return 0
    fi
    RUN_FINAL=true
    RUN_RESULT="$result"
    if [[ "$result" == failure ]]; then
        write_status_html complete failed 100 "$detail"
    else
        write_status_html complete success 100 "$detail"
    fi
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
        local refresh="" final=false verdict verdict_class verdict_note headline build_badge
        local total_elapsed
        [[ -n "$STATUS_HTML" ]] || return 0
        printf '[%s] %s: %s\n' "$(date -u +%H:%M:%SZ)" "$phase" "$detail" >> "$STATUS_RAW_CONSOLE"
        if [[ "$status" == running || "$status" == starting || "$status" == waiting ]]; then
            CONSOLE_AUTORELOAD=true
            refresh='        window.setTimeout(function () { window.location.reload(); }, 3000);'
        else
            CONSOLE_AUTORELOAD=false
            final=true
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
        cat > "$STATUS_HTML" <<EOF
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
        .bar { height: 14px; background: #e7edf5; border-radius: 99px; overflow: hidden; margin: 14px 0 8px; }
        .fill { height: 100%; width: ${percent}%; background: linear-gradient(90deg, #1769aa, #27a36a); transition: width .4s ease; }
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
        @media (max-width: 600px) { body { padding: 14px; } h1 { font-size: 23px; } .task { grid-template-columns: 28px 1fr; } .task-meta { grid-column: 2; align-items: flex-start; } }
    </style>
</head>
<body>
<main>
    <header>
        <div class="brand"><span class="mark">NP</span><span><strong>NINJA PAWS</strong><small> CLOUD SECURITY DOJO</small></span></div>
        <h1>$headline</h1>
        <p>Azure lifecycle command <code>$(html_escape "$COMMAND")</code> targeting environment <strong>$(html_escape "$ENVIRONMENT")</strong>.</p>
        <p><span class="pill $verdict_class verdict">$(html_escape "$verdict")</span></p>
        <p>$verdict_note</p>
    </header>

    <section>
        <h2>Executive summary</h2>
        <div class="bar"><div class="fill"></div></div>
        <p><strong>${percent}%</strong> &middot; current phase <strong>$(html_escape "$phase")</strong> &middot; elapsed $(format_duration "$total_elapsed")</p>
        <p>$(html_escape "$detail")</p>
        <div class="grid" style="margin-top:14px">
            <div class="item"><div class="label">Tasks succeeded</div><div class="value">$TASK_DONE / $TASK_TOTAL</div></div>
            <div class="item"><div class="label">Tasks failed</div><div class="value">$TASK_FAILED</div></div>
            <div class="item"><div class="label">Checks passed</div><div class="value">$CHECK_PASS / $CHECK_TOTAL</div></div>
            <div class="item"><div class="label">Checks failed / not sure</div><div class="value">$CHECK_FAIL / $CHECK_UNKNOWN</div></div>
        </div>
$( [[ "$status" == failed ]] && printf '        <div class="banner"><strong>Failure cause:</strong> %s</div>\n' "$(html_escape "${FAILURE_MESSAGE:-$detail}")" )
    </section>

    <section>
        <h2>Task list</h2>
        <p>Every stage in this run, with its live state and duration.</p>
$(render_task_rows)
    </section>

    <section>
        <h2>Verification matrix</h2>
        <p>Each check is recorded as Pass, Failure, Not sure, or Not applicable with the evidence used to decide.</p>
        <table>
            <thead><tr><th style="width:32%">Check</th><th style="width:14%">Result</th><th>Evidence</th></tr></thead>
            <tbody>
$(render_check_rows)
            </tbody>
        </table>
    </section>

    <section>
        <h2>Environment access</h2>
        <p>Clickable entry points for the deployed environment and its Azure resources.</p>
        <div class="grid">
$(render_environment_links)
        </div>
    </section>

    <section>
        <h2>Run facts</h2>
        <div class="grid">
            <div class="item"><div class="label">Environment</div><div class="value">$(html_escape "$ENVIRONMENT")</div></div>
            <div class="item"><div class="label">Subscription</div><div class="value"><code>$(html_escape "$SUBSCRIPTION_ID")</code></div></div>
            <div class="item"><div class="label">Resource group</div><div class="value">$(html_escape "$RESOURCE_GROUP")</div></div>
            <div class="item"><div class="label">Region</div><div class="value">$(html_escape "$LOCATION")</div></div>
            <div class="item"><div class="label">Registry</div><div class="value">$(html_escape "$ACR_NAME")</div></div>
            <div class="item"><div class="label">App Service</div><div class="value">$(html_escape "$APP_SERVICE_NAME")</div></div>
            <div class="item"><div class="label">Image</div><div class="value"><code>$(html_escape "$IMAGE_NAME:$IMAGE_TAG")</code></div></div>
            <div class="item"><div class="label">Image digest</div><div class="value"><code>$(html_escape "${IMAGE_DIGEST:-not resolved}")</code></div></div>
            <div class="item"><div class="label">Build fingerprint</div><div class="value"><code>$(html_escape "${BUILD_FINGERPRINT:-not computed}")</code><br>$build_badge</div></div>
            <div class="item"><div class="label">Training status</div><div class="value">$(html_escape "$VULNERABILITY_STATUS") on NGINX $(html_escape "$NGINX_VERSION")</div></div>
            <div class="item"><div class="label">Updated</div><div class="value">$(date -u +%Y-%m-%dT%H:%M:%SZ)</div></div>
        </div>
    </section>

    <section>
        <h2>Next steps</h2>
        <ul class="steps">
$(render_next_steps "$([[ "$status" == failed ]] && printf failure || { [[ "$final" == true ]] && printf success || printf progress; })")
        </ul>
    </section>

    <section>
        <h2>Live console</h2>
        <p>Raw terminal stream. Scroll inside the panel to read back; it snaps to the newest line unless you scroll up.</p>
        <iframe src="deployment-$ENVIRONMENT.console.html" title="Complete deployment console" scrolling="no"></iframe>
    </section>

    <section>
        <h2>Diagnostics</h2>
        <p>Azure CLI log: <a href="deployment-$ENVIRONMENT.log"><code>deployment-$ENVIRONMENT.log</code></a></p>
        <p>State manifest: <a href="deployment-$ENVIRONMENT.json"><code>deployment-$ENVIRONMENT.json</code></a></p>
        <p>Console stream: <a href="deployment-$ENVIRONMENT.console.html"><code>deployment-$ENVIRONMENT.console.html</code></a></p>
        <p>$( [[ "$final" == true ]] && printf 'Live auto-refresh has stopped; this is the final report for the run.' || printf 'This page auto-refreshes every 3 seconds while the run is active and keeps your scroll position.' )</p>
    </section>
</main>
<script>
(function () {
    var KEY = 'np-report-scroll-$ENVIRONMENT';
    var store = null;
    try { store = window.sessionStorage; store.getItem(KEY); } catch (error) { store = null; }

    // Reloading to pick up new output must not throw the reader back to the top.
    if (store) {
        var saved = store.getItem(KEY);
        if (saved !== null) { window.scrollTo(0, parseInt(saved, 10)); }
        window.addEventListener('scroll', function () {
            store.setItem(KEY, String(window.scrollY));
        }, { passive: true });
    }

$refresh
})();
</script>
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
    STATUS_CONSOLE="$OUTPUT_DIR/deployment-$ENVIRONMENT.console.html"
    STATUS_RAW_CONSOLE="$OUTPUT_DIR/.deployment-$ENVIRONMENT.console.raw"
    ACR_NAME="${REGISTRY_NAME//-/}"
    set_task plan in_progress "Resolving names, output workspace, and image tag."
    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan ]]; then
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
    write_status_html provisioning running "$(auto_percent 5)" "Submitting Bicep infrastructure deployment."

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
    for file in Dockerfile package.json package-lock.json app.js nginx.conf entrypoint.sh; do
        if [[ -f "$REPO_ROOT/$file" ]]; then
            manifest+="$file $(sha256_of_file "$REPO_ROOT/$file")"$'\n'
        else
            manifest+="$file absent"$'\n'
        fi
    done
    manifest+="args $BASE_OS_IMAGE $BASE_OS_VERSION $NODE_MAJOR_VERSION $NGINX_VERSION $VULNERABILITY_STATUS $PORT $DEFENDER_ENABLED"$'\n'
    printf '%s' "$manifest" | sha256_of_stdin | cut -c1-16
}

acr_tag_digest() {
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$1" --query digest -o tsv 2>/dev/null || true
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
    local registry_login existing_digest tag aliased=0
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
        for tag in "$IMAGE_TAG" latest "$VULNERABILITY_STATUS"; do
            if [[ "$(acr_tag_digest "$tag")" != "$IMAGE_DIGEST" ]]; then
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
        "$AZURE_REPO_ROOT"
    IMAGE_DIGEST="$(acr_tag_digest "$IMAGE_TAG")"
    record_check "Container image is present in the registry" pass "Built and pushed $IMAGE_NAME with tags $IMAGE_TAG, latest, $FINGERPRINT_TAG, $VULNERABILITY_STATUS (digest ${IMAGE_DIGEST:-unresolved})."
    set_task image success "Pushed $IMAGE_NAME:$IMAGE_TAG plus latest, $FINGERPRINT_TAG, and $VULNERABILITY_STATUS (digest ${IMAGE_DIGEST:-unknown})."
    write_state image-built success "Image pushed to ACR"
    write_status_html building success "$(auto_percent)" "Container images pushed to ACR."
}

rollout_image() {
    local registry_login identity_client_id image_reference configured_image health_code app_host
    local attempt=0 max_attempts=18
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
    az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --output none
    while ((attempt < max_attempts)); do
        attempt=$((attempt + 1))
        health_code="$(http_probe "https://$app_host/health")"
        health_code="${health_code%% *}"
        [[ "$health_code" == 200 ]] && break
        echo "  waiting for container start (attempt $attempt/$max_attempts, last HTTP $health_code)"
        write_status_html deploying running "$(auto_percent $((attempt * 90 / max_attempts)))" "Waiting for the container to answer /health (attempt $attempt of $max_attempts, last HTTP $health_code)."
        sleep 10
    done
    if [[ "$health_code" == 200 ]]; then
        record_check "App Service restart was required" pass "Restarted and the container answered /health with HTTP 200 after $attempt attempt(s)."
        set_task restart success "Container is serving traffic; /health returned HTTP 200 after $attempt attempt(s)."
    else
        record_check "App Service restart was required" fail "Restarted but /health still returned HTTP $health_code after $attempt attempt(s). The container is not starting."
        set_task restart failure "The container did not answer /health within $max_attempts attempts; last response was HTTP $health_code."
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

verify() {
    local app_host registry_login configured_image expected_image identity_name identity_principal role_count
    local status_json probe fingerprint_digest failures=0
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
    fingerprint_digest="$(acr_tag_digest "$FINGERPRINT_TAG")"
    if [[ -z "$IMAGE_DIGEST" || -z "$fingerprint_digest" ]]; then
        record_check "Deployed image matches the current source fingerprint" unknown "Digest for $IMAGE_TAG or $FINGERPRINT_TAG could not be read from ACR, so content equivalence is undetermined."
    elif [[ "$IMAGE_DIGEST" == "$fingerprint_digest" ]]; then
        record_check "Deployed image matches the current source fingerprint" pass "$IMAGE_TAG and $FINGERPRINT_TAG both resolve to $IMAGE_DIGEST."
    else
        record_check "Deployed image matches the current source fingerprint" fail "Tag $IMAGE_TAG is $IMAGE_DIGEST but the current source fingerprint $FINGERPRINT_TAG is $fingerprint_digest. The running image does not match the working tree."
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
        record_check "Runtime reports the expected NGINX version" not_applicable "No public hostname is available yet."
        record_check "Runtime reports the expected training status" not_applicable "No public hostname is available yet."
    else
        probe="$(http_probe "$APP_URL/")"
        APP_HTTP_CODE="${probe%% *}"
        APP_RESPONSE_TIME="${probe##* }"
        if [[ "$APP_HTTP_CODE" == 200 ]]; then
            record_check "Public site responds over HTTPS" pass "GET $APP_URL/ returned HTTP 200 in ${APP_RESPONSE_TIME}s."
        elif [[ "$APP_HTTP_CODE" == 000 ]]; then
            record_check "Public site responds over HTTPS" fail "GET $APP_URL/ did not complete (DNS, TLS, or container start failure). The container may still be warming up."
            failures=$((failures + 1))
        else
            record_check "Public site responds over HTTPS" fail "GET $APP_URL/ returned HTTP $APP_HTTP_CODE."
            failures=$((failures + 1))
        fi

        probe="$(http_probe "$APP_URL/health")"
        HEALTH_HTTP_CODE="${probe%% *}"
        if [[ "$HEALTH_HTTP_CODE" == 200 ]]; then
            record_check "Health endpoint responds over HTTPS" pass "GET $APP_URL/health returned HTTP 200."
        else
            record_check "Health endpoint responds over HTTPS" fail "GET $APP_URL/health returned HTTP $HEALTH_HTTP_CODE."
            failures=$((failures + 1))
        fi

        status_json="$(curl -fsS --max-time 30 "$APP_URL/api/status" 2>/dev/null || true)"
        if [[ -z "$status_json" ]]; then
            record_check "Runtime status API is serving JSON" fail "GET $APP_URL/api/status returned no body; the container is not serving the application."
            failures=$((failures + 1))
            record_check "Runtime reports the expected NGINX version" unknown "The status payload was unavailable, so the running NGINX version could not be confirmed."
            record_check "Runtime reports the expected training status" unknown "The status payload was unavailable, so the training status could not be confirmed."
        else
            echo "$status_json"
            record_check "Runtime status API is serving JSON" pass "GET $APP_URL/api/status returned a payload of ${#status_json} bytes."
            if [[ "$status_json" == *"\"${NGINX_VERSION}\""* ]]; then
                record_check "Runtime reports the expected NGINX version" pass "Status payload contains the expected NGINX version $NGINX_VERSION."
            else
                record_check "Runtime reports the expected NGINX version" unknown "Status payload does not contain NGINX $NGINX_VERSION. The running image may predate the current build arguments."
            fi
            if [[ "$status_json" == *"\"${VULNERABILITY_STATUS}\""* ]]; then
                record_check "Runtime reports the expected training status" pass "Status payload reports training status $VULNERABILITY_STATUS."
            else
                record_check "Runtime reports the expected training status" unknown "Status payload does not report training status $VULNERABILITY_STATUS. Confirm which scenario image is live before running an exercise."
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
    local bicep_output="$OUTPUT_DIR/doctor-main.bicep.json"
    local whatif_output="$OUTPUT_DIR/doctor-whatif-$ENVIRONMENT.txt"
    mkdir -p "$OUTPUT_DIR"

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
            --parameters containerRegistryName="$ACR_NAME" appServiceName="$APP_SERVICE_NAME" location="$LOCATION" \
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
    managed="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-managed']" -o tsv)"
    environment_tag="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-environment']" -o tsv)"
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
        record_check "Environment is fully removed" unknown "Deletion was requested with --no-wait, so removal was not confirmed. Re-run with --wait, or check the portal."
        set_task teardown skipped "Not waited on: deletion runs asynchronously. Use --wait to confirm removal."
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
        --force-rebuild) FORCE_REBUILD=true; shift ;;
        --wait) WAIT_FOR_DELETE=true; shift ;;
        --no-status-html) NO_STATUS_HTML=true; shift ;;
        --no-open-status) OPEN_STATUS_HTML=false; shift ;;
        --no-archive) ARCHIVE_OUTPUTS=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

register_lifecycle_tasks
trap on_exit EXIT
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
        finalize_report success "Full lifecycle completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    repair)
        confirm "Repair Azure infrastructure and redeploy the selected image?"
        provision
        build_image
        rollout_image
        verify
        finalize_report success "Repair completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    rollout)
        confirm "Roll out the already-built image to Azure App Service?"
        rollout_image
        verify
        finalize_report success "Rollout completed and verified at ${APP_URL:-the App Service URL}."
        ;;
    verify)
        verify
        finalize_report success "Verification completed for ${APP_URL:-the App Service URL}."
        ;;
    uninstall)
        uninstall
        if [[ "$WAIT_FOR_DELETE" == true ]]; then
            finalize_report success "Uninstall completed. $RESOURCE_GROUP and all of its resources are gone."
        else
            finalize_report success "Uninstall requested. Azure removes $RESOURCE_GROUP asynchronously; re-run with --wait to confirm."
        fi
        ;;
esac

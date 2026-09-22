#!/usr/bin/env bash

# Scenario 2 lifecycle: SQL Server on an Azure VM, hardened with Defender for Servers Plan 2
# (Defender for Endpoint) and Defender for SQL, seeded with the Futon Manufacturing sample
# database. This mirrors the conventions of scripts/deploy.sh (Scenario 1) but is a separate,
# self-contained script because the two scenarios provision fundamentally different Azure
# architectures (App Service + ACR vs. IaaS VM + SQL Server) and should not share deployment
# state or accidentally cross-apply App Service settings to a VM, or vice versa.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE="${DEPLOY_CONFIG_FILE:-$REPO_ROOT/config/deploy.config.json}"
SCENARIO_ID="defender-sql-scenario-2"
COMMAND="deploy"
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-dev}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
LOCATION="${AZURE_LOCATION:-centralus}"
RESOURCE_GROUP=""
VM_NAME=""
WEB_APP_NAME=""
WEB_APP_HOSTNAME=""
KEY_VAULT_NAME=""
SQL_PUBLIC_IP=""
ADMIN_USERNAME="${SQL_VM_ADMIN_USERNAME:-ninjapawsadmin}"
ASSUME_YES=false
OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/output}"
RUN_STARTED_AT="$(date +%s)"
RUN_STARTED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ENDED_ISO=""
RUN_ID=""
RUN_INVOCATION="${*:-$COMMAND}"
RUN_OPERATOR="${GITHUB_ACTOR:-${USER:-${USERNAME:-unknown}}}"
RUN_HOST="$(hostname 2>/dev/null || printf 'unknown')"
RUN_ORIGIN="Local workstation"
RUN_ORIGIN_DETAIL="interactive shell on $RUN_HOST"
APP_VERSION="unknown"
CONFIG_VERSION="unknown"
GIT_COMMIT="unknown"
GIT_DIRTY="unknown"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
AZURE_ACCOUNT_NAME=""
SUBSCRIPTION_NAME=""
STATUS_HTML=""
FINAL_REPORT_FILE=""
STATUS_OPEN_MARKER=""
OPEN_STATUS_HTML=true
NO_STATUS_HTML=false
REPORT_LINK_PRINTED=false
STATUS_BROWSER_OPENED=false
CURRENT_STATUS_PHASE="Starting"
CURRENT_STATUS_DETAIL="Preparing Scenario 2 lifecycle command."
CURRENT_STATUS_PERCENT=5

# config_lookup and config_scenario_ids come from lib/common.sh.
config_setting() {
    local key="$1" fallback="$2" value
    value="$(config_lookup "environments.$ENVIRONMENT.$key")"
    [[ -n "$value" ]] || value="$(config_lookup "sqlScenario.$key")"
    printf '%s' "${value:-$fallback}"
}

fail() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    RUN_ENDED_ISO="${RUN_ENDED_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    if [[ -n "$STATUS_HTML" ]]; then
        write_status_report "Failed" "$1" "${CURRENT_STATUS_PERCENT:-100}" true
        print_report_link_once
    fi
    exit 1
}
info() { echo -e "${BLUE}==>${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

usage() {
    cat <<'EOF'
Usage: scripts/deploy-sql-scenario.sh <command> [options]

Commands:
  plan       Show what would be deployed without contacting Azure.
  doctor     Read-only Azure preflight checks (login, subscription, quota).
  deploy     Provision the VM, SQL Server, Defender plans, and seed the database.
  uninstall  Delete the resource group created for this scenario.

Options:
  --environment <dev|prod>   Environment to target (default: dev)
  --subscription <id>        Azure subscription ID
  --location <region>        Azure region (default: centralus)
  --resource-group <name>    Override the resource group name
  --vm-name <name>           Override the VM name
  --web-app-name <name>      Override the Pawton Manufacturing Web App name
  --admin-username <name>    Windows admin username (default: ninjapawsadmin)
  --defaults                 Accepted for CLI consistency with deploy.sh; this script has no
                              interactive setting prompts to skip. Use --yes to also skip the
                              deployment confirmation prompt.
  --yes                      Skip confirmation prompts
    --no-status-html           Disable the auto-refreshing HTML status report
    --no-open-status           Keep the status report on disk without opening a browser
  --help                     Show this help
EOF
}

while (($# > 0)); do
    case "$1" in
        plan|doctor|deploy|uninstall) COMMAND="$1"; shift ;;
        --environment) ENVIRONMENT="$2"; shift 2 ;;
        --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --vm-name) VM_NAME="$2"; shift 2 ;;
        --web-app-name) WEB_APP_NAME="$2"; shift 2 ;;
        --admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
        --defaults) shift ;;
        --yes) ASSUME_YES=true; shift ;;
        --no-status-html) NO_STATUS_HTML=true; OPEN_STATUS_HTML=false; shift ;;
        --no-open-status) OPEN_STATUS_HTML=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

SCENARIO_NAME="$(config_lookup "scenarios.$SCENARIO_ID.name")"
SCENARIO_WORKLOADS="$(config_lookup "scenarios.$SCENARIO_ID.workloads")"
[[ -n "$SCENARIO_NAME" ]] || fail "Scenario '$SCENARIO_ID' is not registered in $CONFIG_FILE."

RESOURCE_GROUP="${RESOURCE_GROUP:-$(config_setting sqlResourceGroup "NP-ninjapaws-dojo-sql-${ENVIRONMENT}")}"
VM_NAME="${VM_NAME:-$(config_setting sqlVmName "ninjapaws-sql-vm-${ENVIRONMENT}")}"
LOCATION="$(config_setting location "$LOCATION")"
VM_SIZE="$(config_setting vmSize Standard_D4s_v4)"
SQL_IMAGE_SKU="$(config_setting sqlImageSku sqldev-gen2)"
DEPLOY_BASTION="$(config_setting deployBastion true)"
AUTO_ALLOW_BASTION_RDP="$(config_setting autoAllowBastionRdp true)"
ALLOW_PUBLIC_SQL_ACCESS="$(config_setting allowPublicSqlAccess false)"
ALLOW_PUBLIC_KEY_VAULT_ACCESS="$(config_setting allowPublicKeyVaultAccess true)"
DEFENDER_SERVERS_PLAN="$(config_lookup sqlScenario.defender.serversPlan)"
DEFENDER_SERVERS_PLAN="${DEFENDER_SERVERS_PLAN:-VirtualMachines}"
DEFENDER_SERVERS_SUBPLAN="$(config_lookup sqlScenario.defender.serversSubPlan)"
DEFENDER_SERVERS_SUBPLAN="${DEFENDER_SERVERS_SUBPLAN:-P2}"
DEFENDER_SQL_PLAN="$(config_lookup sqlScenario.defender.sqlPlan)"
DEFENDER_SQL_PLAN="${DEFENDER_SQL_PLAN:-SqlServerVirtualMachines}"
DEPLOY_WEB_APP="$(config_setting deployWebApp true)"
WEB_APP_NAME="${WEB_APP_NAME:-$(config_setting webAppName "ninjapaws-pawton-${ENVIRONMENT}")}"
WEB_APP_PLAN_SKU="$(config_setting webAppPlanSku B1)"
ADMIN_PORTAL_USERNAME="$(config_setting adminPortalUsername "dojo-admin")"
CENTRAL_WORKSPACE_RESOURCE_GROUP="$(config_setting centralWorkspaceResourceGroup "NP-Sentinel-CentralUS")"
CENTRAL_WORKSPACE_NAME="$(config_setting centralWorkspaceName "log-np-sentinel-centralus")"
CENTRAL_WORKSPACE_RETENTION_DAYS="$(config_setting workspaceRetentionDays 30)"
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'dev')"
BOOTSTRAP_SCRIPT_URL="https://raw.githubusercontent.com/ninjapaw/ninjapaws-cloud-security-dojo/${GIT_BRANCH}/scripts/sql/Setup-FutonManufacturing.ps1"
BICEP_FILE="$AZURE_REPO_ROOT/infra/sql-defender-scenario/main.bicep"

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
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        RUN_ORIGIN="GitHub Actions"
        RUN_ORIGIN_DETAIL="workflow ${GITHUB_WORKFLOW:-unknown}, run ${GITHUB_RUN_ID}, attempt ${GITHUB_RUN_ATTEMPT:-1}, triggered by ${GITHUB_EVENT_NAME:-unknown}"
    fi
}

mask_identifier() {
    local value="${1:-}"
    if [[ ${#value} -le 8 ]]; then
        printf '%s' "${value:-not recorded}"
    else
        printf '%s...%s' "${value:0:4}" "${value: -4}"
    fi
}

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

mark_status_html_opened() {
    [[ -n "$STATUS_OPEN_MARKER" ]] || return 0
    printf '%s\n' "$1" > "$STATUS_OPEN_MARKER" 2>/dev/null || true
}

print_report_link() {
    [[ -n "$STATUS_HTML" ]] || return 0
    local url copy_note=""
    url="$(report_url "$STATUS_HTML")"
    if command -v clip.exe >/dev/null 2>&1; then
        printf '%s' "$url" | clip.exe 2>/dev/null && copy_note="(copied to clipboard)"
    fi
    echo -e "${BLUE}--- LIVE SCENARIO 2 STATUS REPORT (${ENVIRONMENT}) ---${NC}"
    echo -e "  ${CYAN}${url}${NC} ${copy_note}"
}

print_report_link_once() {
    [[ "$REPORT_LINK_PRINTED" == false ]] || return 0
    print_report_link
    REPORT_LINK_PRINTED=true
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
    for browser in msedge.exe microsoft-edge microsoft-edge-dev edge; do
        if command -v "$browser" >/dev/null 2>&1; then
            STATUS_BROWSER_OPENED=true
            "$browser" "$native" >/dev/null 2>&1 &
            mark_status_html_opened "$url"
            return 0
        fi
    done
    if [[ "$native" == *:\\* ]]; then
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

initialize_status_report() {
    [[ "$NO_STATUS_HTML" == false ]] || return 0
    local out_dir
    out_dir="$OUTPUT_ROOT/$ENVIRONMENT"
    mkdir -p "$out_dir"
    STATUS_HTML="$out_dir/sql-deployment-$ENVIRONMENT.status.html"
    FINAL_REPORT_FILE="$out_dir/sql-deployment-$ENVIRONMENT.html"
    STATUS_OPEN_MARKER="$OUTPUT_ROOT/.sql-deployment-$ENVIRONMENT.browser-opened"
    update_status "Starting" "Preparing Scenario 2 lifecycle command." 5
    open_status_html
}

update_status() {
    CURRENT_STATUS_PHASE="$1"
    CURRENT_STATUS_DETAIL="$2"
    CURRENT_STATUS_PERCENT="$3"
    write_status_report "$CURRENT_STATUS_PHASE" "$CURRENT_STATUS_DETAIL" "$CURRENT_STATUS_PERCENT" false
}

complete_status() {
    local phase="$1" detail="$2" percent="${3:-100}"
    RUN_ENDED_ISO="${RUN_ENDED_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    write_status_report "$phase" "$detail" "$percent" true
    print_report_link_once
}

count_checks() {
    STATUS_PASS=0; STATUS_FAIL=0; STATUS_UNKNOWN=0; STATUS_NA=0; STATUS_TOTAL=0
    local result
    for result in "${CHECK_RESULTS[@]}"; do
        STATUS_TOTAL=$((STATUS_TOTAL + 1))
        case "$result" in
            pass) STATUS_PASS=$((STATUS_PASS + 1)) ;;
            fail) STATUS_FAIL=$((STATUS_FAIL + 1)) ;;
            unknown) STATUS_UNKNOWN=$((STATUS_UNKNOWN + 1)) ;;
            not_applicable) STATUS_NA=$((STATUS_NA + 1)) ;;
        esac
    done
}

render_status_checks() {
    if ((${#CHECK_LABELS[@]} == 0)); then
        printf '<tr><td colspan="3">No verification checks have run yet. They will appear here as Azure evidence is collected.</td></tr>\n'
        return 0
    fi
    render_check_rows_html
}

write_status_report() {
    local phase="$1" detail="$2" percent="$3" final="${4:-false}"
    local out_tmp refresh final_link final_label status_class ended
    [[ -n "$STATUS_HTML" ]] || return 0
    count_checks
    ended="${RUN_ENDED_ISO:-in progress}"
    final_link="Not available yet. It is written after verification completes."
    if [[ -n "$FINAL_REPORT_FILE" && -f "$FINAL_REPORT_FILE" ]]; then
        final_link="<a href=\"$(html_escape "$(basename "$FINAL_REPORT_FILE")")\">Open final audit report</a>"
    fi
    if [[ "$final" == true ]]; then
        refresh=""
        final_label="Complete"
    else
        refresh='<meta http-equiv="refresh" content="5">'
        final_label="Monitoring"
    fi
    case "$phase" in
        *Failed*|*failed*) status_class=bad ;;
        *Complete*|*complete*|*Succeeded*|*succeeded*) status_class=ok ;;
        *) status_class=warn ;;
    esac
    out_tmp="$STATUS_HTML.tmp"
    cat > "$out_tmp" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$refresh
<title>$(html_escape "$(project_meta name 'Ninja Paws Cloud Security Dojo')") — Scenario 2 live status ($ENVIRONMENT)</title>
<style>
    :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #eef3f8; color: #152238; }
    body { margin: 0; padding: 28px; background: radial-gradient(circle at 82% 0%, #cde7f2 0, transparent 34%), #eef3f8; }
    main { max-width: 1080px; margin: auto; }
    header, section { background: #fff; border: 1px solid #dbe3ee; border-radius: 14px; box-shadow: 0 8px 24px #17203312; }
    header { padding: 28px; margin-bottom: 18px; border-top: 5px solid #d98932; }
    .brand { display: flex; align-items: center; gap: 12px; color: #102f4d; letter-spacing: .08em; font-size: 13px; }
    .brand small { display: block; color: #77869a; font-size: 9px; letter-spacing: .16em; margin-top: 3px; }
    .mark { display: grid; place-items: center; width: 44px; height: 44px; border-radius: 12px 12px 12px 4px; background: #102f4d; color: #f2a24a; font-weight: 800; letter-spacing: 0; }
    h1 { margin: 22px 0 8px; font-size: 30px; }
    h2 { margin: 0 0 8px; font-size: 18px; }
    p { margin: 6px 0; color: #5b6678; }
    section { padding: 22px; margin: 18px 0; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px; }
    .item { background: #f7f9fc; border-radius: 10px; padding: 14px; }
    .label { color: #68758a; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
    .value { margin-top: 5px; font-weight: 650; overflow-wrap: anywhere; }
    .bar { height: 14px; border-radius: 999px; background: #e7edf5; overflow: hidden; margin-top: 14px; }
    .fill { height: 100%; width: ${percent}%; background: linear-gradient(90deg, #1769aa, #d98932); }
    code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 13px; background: #eef2f8; padding: 1px 5px; border-radius: 5px; }
    a { color: #1769aa; }
    .pill { display: inline-block; padding: 4px 10px; border-radius: 99px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; font-size: 11px; white-space: nowrap; }
    .pill.ok { background: #e7f5ee; color: #176b43; }
    .pill.bad { background: #fdeaea; color: #a02020; }
    .pill.warn { background: #fdf3e0; color: #8a5a10; }
    .pill.na { background: #f0eef6; color: #5b4f80; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #e7edf5; vertical-align: top; overflow-wrap: anywhere; }
    th { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #68758a; }
    .banner { padding: 14px 16px; border-radius: 10px; background: #fdeaea; border: 1px solid #f3c9c9; color: #7d1f1f; margin-top: 14px; }
    @media (max-width: 600px) { body { padding: 14px; } h1 { font-size: 23px; } }
</style>
</head>
<body>
<main>
    <header>
        <div class="brand"><span class="mark">NP</span><span><strong>NINJA PAWS</strong><small> CLOUD SECURITY DOJO</small></span></div>
        <h1>Scenario 2 live status: $(html_escape "$ENVIRONMENT")</h1>
        <p><span class="pill $status_class">$(html_escape "$final_label")</span> $(html_escape "$phase")</p>
        <p>$(html_escape "$detail")</p>
        <div class="bar" aria-label="Deployment progress"><div class="fill"></div></div>
    </header>

    <section>
        <h2>Status summary</h2>
        <div class="grid">
            <div class="item"><div class="label">Scenario</div><div class="value">$(html_escape "$SCENARIO_NAME")<br><code>$(html_escape "$SCENARIO_ID")</code></div></div>
            <div class="item"><div class="label">Command</div><div class="value"><code>deploy-sql-scenario.sh $(html_escape "$RUN_INVOCATION")</code></div></div>
            <div class="item"><div class="label">Resource group</div><div class="value">$(html_escape "$RESOURCE_GROUP")</div></div>
            <div class="item"><div class="label">SQL VM</div><div class="value">$(html_escape "$VM_NAME") / $(html_escape "$VM_SIZE")</div></div>
            <div class="item"><div class="label">Dashboard</div><div class="value">$(html_escape "$WEB_APP_NAME")<br>$([[ -n "$WEB_APP_HOSTNAME" ]] && printf '<a href="https://%s/" target="_blank" rel="noopener">https://%s/</a>' "$(html_escape "$WEB_APP_HOSTNAME")" "$(html_escape "$WEB_APP_HOSTNAME")" || printf 'Waiting for deployment output')</div></div>
            <div class="item"><div class="label">Checks</div><div class="value">Pass $STATUS_PASS / Fail $STATUS_FAIL / Not sure $STATUS_UNKNOWN / Total $STATUS_TOTAL</div></div>
            <div class="item"><div class="label">Started / Ended UTC</div><div class="value">$(html_escape "$RUN_STARTED_ISO")<br>$(html_escape "$ended")</div></div>
            <div class="item"><div class="label">Final audit report</div><div class="value">$final_link</div></div>
        </div>
    </section>

    <section>
        <h2>Monitoring links</h2>
        <div class="grid">
            <div class="item"><div class="label">Resource group</div><div class="value"><a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/overview" target="_blank" rel="noopener">$(html_escape "$RESOURCE_GROUP")</a></div></div>
            <div class="item"><div class="label">SQL VM</div><div class="value"><a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/providers/Microsoft.Compute/virtualMachines/$(html_escape "$VM_NAME")/overview" target="_blank" rel="noopener">VM overview</a> &middot; <a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/providers/Microsoft.Compute/virtualMachines/$(html_escape "$VM_NAME")/metrics" target="_blank" rel="noopener">metrics</a></div></div>
            <div class="item"><div class="label">Pawton Web App</div><div class="value"><a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/providers/Microsoft.Web/sites/$(html_escape "$WEB_APP_NAME")/overview" target="_blank" rel="noopener">App Service overview</a> &middot; <a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/providers/Microsoft.Web/sites/$(html_escape "$WEB_APP_NAME")/metrics" target="_blank" rel="noopener">metrics</a></div></div>
            <div class="item"><div class="label">Defender for Cloud</div><div class="value"><a href="https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade" target="_blank" rel="noopener">Security recommendations</a></div></div>
        </div>
    </section>

    <section>
        <h2>Verification matrix</h2>
        <table>
            <thead><tr><th>Check</th><th>Result</th><th>Detail</th></tr></thead>
            <tbody>
$(render_status_checks)
            </tbody>
        </table>
    </section>

    <section>
        <h2>Audit context</h2>
        <div class="grid">
            <div class="item"><div class="label">Run ID</div><div class="value"><code>$(html_escape "$RUN_ID")</code></div></div>
            <div class="item"><div class="label">Operator / Origin</div><div class="value">$(html_escape "$RUN_OPERATOR")<br>$(html_escape "$RUN_ORIGIN_DETAIL")</div></div>
            <div class="item"><div class="label">Git</div><div class="value">$(html_escape "$GIT_BRANCH")<br><code>$(html_escape "${GIT_COMMIT:0:12}")</code> &middot; $(html_escape "$GIT_DIRTY")</div></div>
            <div class="item"><div class="label">Azure identity</div><div class="value">$(html_escape "${AZURE_ACCOUNT_NAME:-not recorded}")<br>$(html_escape "${SUBSCRIPTION_NAME:-unknown}") / <code>$(html_escape "$(mask_identifier "$SUBSCRIPTION_ID")")</code></div></div>
            <div class="item"><div class="label">Tool version</div><div class="value">v$(html_escape "$APP_VERSION") / config v$(html_escape "$CONFIG_VERSION")</div></div>
            <div class="item"><div class="label">Updated UTC</div><div class="value">$(date -u +%Y-%m-%dT%H:%M:%SZ)</div></div>
        </div>
        <div class="banner"><strong>USE AT YOUR OWN RISK.</strong> This is a deliberately vulnerable, billable training environment. Keep it isolated and uninstall it when the exercise ends.</div>
    </section>
</main>
</body>
</html>
HTML
    mv -f "$out_tmp" "$STATUS_HTML" 2>/dev/null || cp -f "$out_tmp" "$STATUS_HTML"
}

CHECK_LABELS=()
CHECK_RESULTS=()
CHECK_DETAILS=()
record_check() {
    CHECK_LABELS+=("$1"); CHECK_RESULTS+=("$2"); CHECK_DETAILS+=("$3")
    case "$2" in
        pass) echo -e "  ${GREEN}✓${NC} $1 — $3" ;;
        fail) echo -e "  ${RED}✗${NC} $1 — $3" ;;
        unknown) echo -e "  ${YELLOW}?${NC} $1 — $3" ;;
        *) echo -e "  ${CYAN}∅${NC} $1 — $3" ;;
    esac
}

require_login() {
    local account_info
    account_info="$(az account show --query "[id,tenantId,name,user.name]" -o tsv 2>/dev/null || true)"
    [[ -n "$account_info" ]] || fail "Azure login required. Run 'az login' first."
    IFS=$'\t' read -r acct_sub acct_tenant acct_name acct_user <<<"$account_info"
    SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$acct_sub}"
    [[ "$SUBSCRIPTION_ID" == "$acct_sub" ]] || az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
    AZURE_TENANT_ID="$acct_tenant"
    SUBSCRIPTION_NAME="$acct_name"
    AZURE_ACCOUNT_NAME="$acct_user"
    ok "Signed in as $acct_user against subscription $acct_name ($SUBSCRIPTION_ID)"
}

print_plan() {
    cat <<EOF

${BLUE}Scenario:${NC} $SCENARIO_NAME ($SCENARIO_ID)
${BLUE}Workloads:${NC} $SCENARIO_WORKLOADS
${BLUE}Sample database:${NC} Futon Manufacturing (microsoft/sql-server-samples)

${BLUE}Environment:${NC} $ENVIRONMENT
${BLUE}Resource group:${NC} $RESOURCE_GROUP
${BLUE}Location:${NC} $LOCATION
${BLUE}VM name:${NC} $VM_NAME
${BLUE}VM size:${NC} $VM_SIZE
${BLUE}SQL image SKU:${NC} $SQL_IMAGE_SKU (MicrosoftSQLServer:sql2022-ws2022)
${BLUE}Azure Bastion:${NC} $DEPLOY_BASTION
${BLUE}Bastion RDP auto-allowed (no JIT request):${NC} $AUTO_ALLOW_BASTION_RDP
${BLUE}Public SQL endpoint:${NC} $ALLOW_PUBLIC_SQL_ACCESS (TCP 1433 from public networks)
${BLUE}Public Key Vault endpoint:${NC} $ALLOW_PUBLIC_KEY_VAULT_ACCESS
${BLUE}Defender for Servers:${NC} $DEFENDER_SERVERS_PLAN / $DEFENDER_SERVERS_SUBPLAN (includes Defender for Endpoint)
${BLUE}Defender for SQL:${NC} $DEFENDER_SQL_PLAN (Standard tier)
${BLUE}Central Log Analytics workspace:${NC} $CENTRAL_WORKSPACE_NAME (resource group $CENTRAL_WORKSPACE_RESOURCE_GROUP) — standardized across every scenario in this repo
${BLUE}Bootstrap script:${NC} $BOOTSTRAP_SCRIPT_URL
${BLUE}Pawton Manufacturing Web App:${NC} $WEB_APP_NAME ($WEB_APP_PLAN_SKU, deployWebApp=$DEPLOY_WEB_APP)
${BLUE}Web App network path:${NC} private regional VNet integration to the SQL VM subnet

EOF
}

cmd_plan() {
    initialize_status_report
    info "Dry run — no Azure calls will be made."
    print_plan
    complete_status "Complete" "Dry run completed. No Azure resources were changed." 100
}

cmd_doctor() {
    require_login
    initialize_status_report
    update_status "Preflight" "Running read-only Azure preflight checks." 25
    print_plan
    info "Checking VM size quota for $VM_SIZE in $LOCATION..."
    local family usage
    family="$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --query "[0].family" -o tsv 2>/dev/null || true)"
    if [[ -n "$family" ]]; then
        usage="$(az vm list-usage --location "$LOCATION" --query "[?name.value=='$family'].{limit:limit,current:currentValue}" -o tsv 2>/dev/null || true)"
        if [[ -n "$usage" ]]; then
            ok "Quota family $family: $usage (current/limit)"
        else
            warn "Could not read quota usage for family $family; verify manually before deploying."
        fi
    else
        warn "Could not resolve the VM size family for quota checks."
    fi
    info "Checking resource providers..."
    local provider state
    for provider in Microsoft.Compute Microsoft.Network Microsoft.SqlVirtualMachine Microsoft.OperationalInsights Microsoft.Security; do
        state="$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || true)"
        [[ "$state" == Registered ]] && ok "$provider: Registered" || warn "$provider: ${state:-unknown} (deploy will attempt to register it)"
    done
    info "Checking central Log Analytics workspace '$CENTRAL_WORKSPACE_NAME'..."
    if az monitor log-analytics workspace show --resource-group "$CENTRAL_WORKSPACE_RESOURCE_GROUP" \
        --workspace-name "$CENTRAL_WORKSPACE_NAME" --output none 2>/dev/null; then
        ok "Central workspace '$CENTRAL_WORKSPACE_NAME' already exists in '$CENTRAL_WORKSPACE_RESOURCE_GROUP'."
    else
        warn "Central workspace '$CENTRAL_WORKSPACE_NAME' does not exist yet; 'deploy' will create it in '$CENTRAL_WORKSPACE_RESOURCE_GROUP'."
    fi
    complete_status "Complete" "Doctor checks completed. Review warnings before deploying." 100
}

ensure_resource_group() {
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        ok "Resource group '$RESOURCE_GROUP' already exists."
    else
        info "Creating resource group '$RESOURCE_GROUP' in $LOCATION..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        ok "Resource group created."
    fi
}

# Every scenario in this repo forwards Defender/SQL telemetry into one standardized workspace
# instead of provisioning a workspace per scenario/VM, so training exercises share a single place
# to query and correlate signal. Idempotent: leaves an existing workspace untouched.
ensure_central_workspace() {
    if az group show --name "$CENTRAL_WORKSPACE_RESOURCE_GROUP" --output none 2>/dev/null; then
        ok "Central workspace resource group '$CENTRAL_WORKSPACE_RESOURCE_GROUP' already exists."
    else
        info "Creating central workspace resource group '$CENTRAL_WORKSPACE_RESOURCE_GROUP' in $LOCATION..."
        az group create --name "$CENTRAL_WORKSPACE_RESOURCE_GROUP" --location "$LOCATION" --output none
        ok "Central workspace resource group created."
    fi
    if az monitor log-analytics workspace show --resource-group "$CENTRAL_WORKSPACE_RESOURCE_GROUP" \
        --workspace-name "$CENTRAL_WORKSPACE_NAME" --output none 2>/dev/null; then
        ok "Central Log Analytics workspace '$CENTRAL_WORKSPACE_NAME' already exists."
    else
        info "Creating central Log Analytics workspace '$CENTRAL_WORKSPACE_NAME'..."
        az monitor log-analytics workspace create --resource-group "$CENTRAL_WORKSPACE_RESOURCE_GROUP" \
            --workspace-name "$CENTRAL_WORKSPACE_NAME" --location "$LOCATION" \
            --sku PerGB2018 --retention-time "$CENTRAL_WORKSPACE_RETENTION_DAYS" --output none
        ok "Central Log Analytics workspace created."
    fi
}

generate_password() {
    # 24 alnum characters plus one random special character inserted at a random position,
    # so the generated password satisfies Windows complexity rules without any fixed,
    # predictable suffix (a static suffix would leak part of every password we generate).
    local core specials='!@#$%^&*-_=' special_char pos
    if command -v openssl >/dev/null 2>&1; then
        core="$(openssl rand -base64 33 | tr -dc 'A-Za-z0-9')"
    else
        core="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    fi
    core="${core:0:24}"
    special_char="${specials:$((RANDOM % ${#specials})):1}"
    pos=$((RANDOM % (${#core} + 1)))
    printf '%s%s%s' "${core:0:pos}" "$special_char" "${core:pos}"
}

# Reads one "properties.outputs" field out of a bicep deployment's JSON, without a jq dependency.
read_output() {
    printf '%s' "$1" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).$2.value)" 2>/dev/null || true
}

run_deployment() {
    local admin_password sql_app_login_password admin_portal_password admin_session_secret sql_admin_ops_password
    local deployment_name output_json vm_principal_id creds_dir creds_file
    admin_password="$(generate_password)"
    sql_app_login_password="$(generate_password)"
    admin_portal_password="$(generate_password)"
    sql_admin_ops_password="$(generate_password)"
    admin_session_secret="$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    deployment_name="sql-scenario-$(date -u +%Y%m%dT%H%M%SZ)"

    info "Deploying infrastructure ($deployment_name)..."
    update_status "Deploying infrastructure" "Creating or updating the SQL VM, network, Key Vault, and optional dashboard resources." 25
    output_json="$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$deployment_name" \
        --template-file "$BICEP_FILE" \
        --parameters vmName="$VM_NAME" adminUsername="$ADMIN_USERNAME" adminPassword="$admin_password" \
                     vmSize="$VM_SIZE" sqlImageSku="$SQL_IMAGE_SKU" bootstrapScriptUrl="$BOOTSTRAP_SCRIPT_URL" \
                     deployBastion="$DEPLOY_BASTION" autoAllowBastionRdp="$AUTO_ALLOW_BASTION_RDP" \
                     allowPublicSqlAccess="$ALLOW_PUBLIC_SQL_ACCESS" \
                     allowPublicKeyVaultAccess="$ALLOW_PUBLIC_KEY_VAULT_ACCESS" \
                     deployWebApp="$DEPLOY_WEB_APP" webAppName="$WEB_APP_NAME" \
                     webAppPlanSku="$WEB_APP_PLAN_SKU" sqlAppLoginPassword="$sql_app_login_password" \
                     centralWorkspaceResourceGroup="$CENTRAL_WORKSPACE_RESOURCE_GROUP" \
                     centralWorkspaceName="$CENTRAL_WORKSPACE_NAME" \
                     adminPortalUsername="$ADMIN_PORTAL_USERNAME" adminPortalPassword="$admin_portal_password" \
                     adminSessionSecret="$admin_session_secret" sqlAdminOpsPassword="$sql_admin_ops_password" \
        --query "properties.outputs" -o json)" || fail "Bicep deployment failed. Re-run with 'az deployment group create' directly for full diagnostics."
    ok "Infrastructure deployed."
    update_status "Infrastructure deployed" "Bicep deployment finished. Capturing outputs and credentials." 42

    # ARM only applies osProfile.adminPassword when the VM is first created; redeploying an
    # existing VM with a new generated password leaves the OS password unchanged, so the
    # recorded/Key Vault credentials would silently stop matching what's on the VM. The
    # VMAccess extension resets the OS password directly, keeping the two in sync every run.
    if az vm user update --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
        --username "$ADMIN_USERNAME" --password "$admin_password" --output none 2>/dev/null; then
        record_check "VM admin password synced to the OS" pass "Reset via the VMAccess extension so Bastion sign-in matches the recorded credentials."
    else
        record_check "VM admin password synced to the OS" fail "VMAccess extension reset failed; the recorded password may not match the VM. Re-run 'az vm user update' manually."
    fi

    # Persist the generated admin password to the gitignored local output/ directory for Bastion
    # and other SQL VM access. Never print it to stdout, which CI systems capture in logs.
    creds_dir="$OUTPUT_ROOT/$ENVIRONMENT"
    mkdir -p "$creds_dir"
    creds_file="$creds_dir/sql-vm-credentials.txt"
    {
        printf 'VM name:        %s\n' "$VM_NAME"
        printf 'Admin username: %s\n' "$ADMIN_USERNAME"
        printf 'Admin password: %s\n' "$admin_password"
        printf 'Generated:      %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'Connect through Azure Bastion in the portal, or use the public SQL endpoint shown in the report.\n'
    } > "$creds_file"
    chmod 600 "$creds_file" 2>/dev/null || true
    unset admin_password
    warn "Admin credentials saved to $creds_file — treat it as a secret and delete it once you finish the exercise."
    record_check "VM admin credentials saved locally" pass "Written to $creds_file (not committed; output/ is gitignored). Delete this file when the exercise ends."

    KEY_VAULT_NAME="$(read_output "$output_json" keyVaultName)"
    WEB_APP_HOSTNAME="$(read_output "$output_json" webAppHostName)"
    SQL_PUBLIC_IP="$(read_output "$output_json" sqlPublicIpAddress)"
    unset sql_app_login_password

    # The admin portal password is regenerated every deploy (like the VM admin password above), so
    # the previous value silently stops working; persist it locally the same way so /admin sign-in
    # matches what's actually configured on this run.
    admin_portal_creds_file="$creds_dir/admin-portal-credentials.txt"
    {
        printf 'Admin portal URL:      https://%s/admin\n' "$WEB_APP_HOSTNAME"
        printf 'Admin portal username: %s\n' "$ADMIN_PORTAL_USERNAME"
        printf 'Admin portal password: %s\n' "$admin_portal_password"
        printf 'Generated:             %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$admin_portal_creds_file"
    chmod 600 "$admin_portal_creds_file" 2>/dev/null || true
    unset admin_portal_password sql_admin_ops_password admin_session_secret
    warn "Admin portal credentials saved to $admin_portal_creds_file — treat it as a secret and delete it once you finish the exercise."
    record_check "Admin portal credentials saved locally" pass "Written to $admin_portal_creds_file (not committed; output/ is gitignored). This account can enable/disable/rotate the sa login from the dashboard -- delete this file when the exercise ends."

    if [[ -n "$KEY_VAULT_NAME" ]]; then
        record_check "futon_app SQL login password stored in Key Vault" pass "Secret 'sql-app-login-password' in $KEY_VAULT_NAME; retrieve with 'az keyvault secret show --vault-name $KEY_VAULT_NAME --name sql-app-login-password'."
        record_check "VM admin credentials stored in Key Vault" pass "Secrets 'vm-admin-username' and 'vm-admin-password' in $KEY_VAULT_NAME; retrieve them with 'az keyvault secret show --vault-name $KEY_VAULT_NAME --name <secret-name>'."
    fi

    vm_principal_id="$(read_output "$output_json" principalId)"
    if [[ -n "$vm_principal_id" ]]; then
        record_check "VM has a system-assigned managed identity" pass "principalId $vm_principal_id is available for future Key Vault or RBAC assignments."
    else
        record_check "VM has a system-assigned managed identity" unknown "Could not read the managed identity principal ID from deployment outputs."
    fi

    info "Activating Defender for Servers ($DEFENDER_SERVERS_SUBPLAN) — includes Defender for Endpoint onboarding..."
    update_status "Activating Defender" "Enabling Defender for Servers Plan 2 and Defender for SQL coverage." 52
    if az security pricing create --name "$DEFENDER_SERVERS_PLAN" --tier Standard --sub-plan "$DEFENDER_SERVERS_SUBPLAN" --output none 2>/dev/null; then
        ok "Defender for Servers Plan 2 activated at subscription scope."
    else
        warn "Could not activate Defender for Servers automatically; requires Microsoft.Security/pricings write permission at subscription scope."
    fi

    info "Activating Defender for SQL on the VM..."
    if az security pricing create --name "$DEFENDER_SQL_PLAN" --tier Standard --output none 2>/dev/null; then
        ok "Defender for SQL (Azure VMs) activated at subscription scope."
    else
        warn "Could not activate Defender for SQL automatically; requires Microsoft.Security/pricings write permission at subscription scope."
    fi

    info "Waiting for the futon-manufacturing bootstrap extension to finish (this restores the sample database)..."
    update_status "Waiting for SQL bootstrap" "The VM Custom Script Extension is restoring the Futon Manufacturing sample database." 62
    local attempt=0 ext_state=""
    while ((attempt < 60)); do
        ext_state="$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name futon-manufacturing-bootstrap --query provisioningState -o tsv 2>/dev/null || true)"
        [[ "$ext_state" == Succeeded || "$ext_state" == Failed ]] && break
        sleep 15
        attempt=$((attempt + 1))
        update_status "Waiting for SQL bootstrap" "Bootstrap extension state: ${ext_state:-unknown}; attempt $attempt of 60." "$((62 + attempt / 2))"
    done
    [[ "$ext_state" == Succeeded ]] && ok "Bootstrap extension finished: $ext_state" || warn "Bootstrap extension state: ${ext_state:-unknown} — check the VM's C:\\NinjaPawsDojo\\bootstrap.log over Bastion."

    if [[ "$DEPLOY_WEB_APP" == true && -n "$WEB_APP_NAME" ]]; then
        deploy_web_app_code
    else
        record_check "Pawton Manufacturing dashboard deployed" not_applicable "Disabled by configuration (deployWebApp=$DEPLOY_WEB_APP)."
    fi
}

# Zips the Astro/Node.js app source (no node_modules/dist) and lets App Service's Oryx
# build step run "npm install && npm run build" server-side, matching SCM_DO_BUILD_DURING_DEPLOYMENT.
deploy_web_app_code() {
    local app_dir zip_path deploy_error
    app_dir="$REPO_ROOT/apps/pawton-manufacturing"
    zip_path="$(mktemp -u).zip"

    info "Packaging the Pawton Manufacturing dashboard from $app_dir..."
    update_status "Packaging dashboard" "Preparing the Pawton Manufacturing App Service deployment package." 75
    if command -v zip >/dev/null 2>&1; then
        (cd "$app_dir" && zip -rq "$zip_path" . -x 'node_modules/*' -x 'dist/*' -x '.astro/*')
    else
        # Git Bash on Windows has no 'zip' binary; fall back to PowerShell's Compress-Archive,
        # which is always present, instead of skipping the deployment step entirely.
        local ps_bin="" win_app_dir win_zip_path
        for candidate in pwsh.exe powershell.exe; do
            if command -v "$candidate" >/dev/null 2>&1; then ps_bin="$candidate"; break; fi
        done
        if [[ -z "$ps_bin" ]]; then
            record_check "Pawton Manufacturing dashboard deployed" unknown "Neither 'zip' nor PowerShell is available here; deploy manually with 'az webapp deploy --resource-group $RESOURCE_GROUP --name $WEB_APP_NAME --src-path <app.zip> --type zip'."
            return 0
        fi
        if command -v wslpath >/dev/null 2>&1; then
            win_app_dir="$(wslpath -w "$app_dir")"
            win_zip_path="$(wslpath -w "$zip_path")"
        elif command -v cygpath >/dev/null 2>&1; then
            win_app_dir="$(cygpath -w "$app_dir")"
            win_zip_path="$(cygpath -w "$zip_path")"
        else
            win_app_dir="$app_dir"
            win_zip_path="$zip_path"
        fi
        "$ps_bin" -NoProfile -Command "Get-ChildItem -LiteralPath '$win_app_dir' -Force | Where-Object { \$_.Name -notin @('node_modules','dist','.astro') } | Compress-Archive -DestinationPath '$win_zip_path' -CompressionLevel Optimal -Force" \
            || { record_check "Pawton Manufacturing dashboard deployed" fail "PowerShell Compress-Archive failed while packaging $app_dir."; return 0; }
    fi

    info "Deploying to $WEB_APP_NAME (remote build via Oryx)..."
    update_status "Deploying dashboard" "Zip-deploying the Pawton Manufacturing dashboard; App Service/Oryx will build it remotely." 82
    if deploy_error="$(az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --src-path "$zip_path" --type zip --async false --output none 2>&1)"; then
        ok "Pawton Manufacturing dashboard code deployed."
        az webapp config set --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --startup-file "node ./dist/server/entry.mjs" --output none
        az webapp config appsettings set --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" \
            --settings HOST=0.0.0.0 SQL_CONNECT_TIMEOUT_MS=5000 SQL_REQUEST_TIMEOUT_MS=5000 --output none
        record_check "Pawton Manufacturing dashboard deployed" pass "Zip-deployed $app_dir to $WEB_APP_NAME; Oryx runs the Astro build remotely."
    else
        warn "Web app code deployment failed: ${deploy_error:-no error detail returned}"
        record_check "Pawton Manufacturing dashboard deployed" fail "az webapp deploy failed: ${deploy_error:-no error detail returned}"
    fi
    rm -f "$zip_path"
}

run_verification() {
    info "Running verification checks..."
    update_status "Running verification" "Collecting Azure evidence for VM state, Defender coverage, networking, Key Vault, and dashboard health." 88
    local vm_state defender_servers_tier defender_servers_subplan defender_sql_tier nic_public_ip bastion_state bastion_rdp_rule sqlvm_state ext_state
    local web_app_state web_app_subnet defender_appservices_tier health_body root_http_code health_http_code

    vm_state="$(az vm get-instance-view --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null || true)"
    if [[ "$vm_state" == "VM running" ]]; then
        record_check "Azure VM is running" pass "Instance view reports '$vm_state'."
    else
        record_check "Azure VM is running" unknown "Instance view reports '${vm_state:-unavailable}'."
    fi

    sqlvm_state="$(az resource show --resource-group "$RESOURCE_GROUP" --resource-type Microsoft.SqlVirtualMachine/sqlVirtualMachines --name "$VM_NAME" --query properties.provisioningState -o tsv 2>/dev/null || true)"
    if [[ "$sqlvm_state" == Succeeded ]]; then
        record_check "SQL VM resource registered (SQL IaaS Agent)" pass "Azure manages this VM as a SQL Server VM (patching, backup, best-practice assessment)."
    else
        record_check "SQL VM resource registered (SQL IaaS Agent)" unknown "Provisioning state: ${sqlvm_state:-unavailable}."
    fi

    defender_servers_tier="$(az security pricing show --name "$DEFENDER_SERVERS_PLAN" --query pricingTier -o tsv 2>/dev/null || true)"
    defender_servers_subplan="$(az security pricing show --name "$DEFENDER_SERVERS_PLAN" --query subPlan -o tsv 2>/dev/null || true)"
    if [[ "$defender_servers_tier" == Standard && "$defender_servers_subplan" == "$DEFENDER_SERVERS_SUBPLAN" ]]; then
        record_check "Defender for Servers Plan 2 (Defender for Endpoint)" pass "Subscription plan is Standard/$defender_servers_subplan."
    else
        record_check "Defender for Servers Plan 2 (Defender for Endpoint)" unknown "Subscription reports tier='${defender_servers_tier:-unknown}' subPlan='${defender_servers_subplan:-unknown}'."
    fi

    defender_sql_tier="$(az security pricing show --name "$DEFENDER_SQL_PLAN" --query pricingTier -o tsv 2>/dev/null || true)"
    if [[ "$defender_sql_tier" == Standard ]]; then
        record_check "Defender for SQL on Azure VMs" pass "Subscription plan is Standard."
    else
        record_check "Defender for SQL on Azure VMs" unknown "Subscription reports tier='${defender_sql_tier:-unknown}'."
    fi

    nic_public_ip="$(az network nic show --resource-group "$RESOURCE_GROUP" --name "${VM_NAME}-nic" --query "ipConfigurations[0].publicIPAddress" -o tsv 2>/dev/null || true)"
    if [[ -n "$nic_public_ip" ]]; then
        record_check "SQL Server VM public SQL endpoint" pass "The VM NIC has public IP resource $nic_public_ip; inbound TCP 1433 is enabled by the Scenario 2 NSG."
    else
        record_check "SQL Server VM public SQL endpoint" not_applicable "No public IP is attached; use the private endpoint or Bastion path."
    fi

    if [[ "$DEPLOY_BASTION" == true ]]; then
        bastion_state="$(az network bastion show --resource-group "$RESOURCE_GROUP" --name "${VM_NAME}-bastion" --query provisioningState -o tsv 2>/dev/null || true)"
        [[ "$bastion_state" == Succeeded ]] && record_check "Azure Bastion provisioned" pass "Bastion is available for browser-based RDP." \
            || record_check "Azure Bastion provisioned" unknown "Provisioning state: ${bastion_state:-unavailable}."

        if [[ "$AUTO_ALLOW_BASTION_RDP" == true ]]; then
            bastion_rdp_rule="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "${VM_NAME}-nsg" --name AllowBastionRdp --query provisioningState -o tsv 2>/dev/null || true)"
            [[ "$bastion_rdp_rule" == Succeeded ]] && record_check "Bastion RDP auto-allowed" pass "NSG rule AllowBastionRdp permits RDP from the Bastion subnet without a Just-in-Time request." \
                || record_check "Bastion RDP auto-allowed" unknown "AllowBastionRdp rule not found; Bastion connections may require a JIT request."
        else
            record_check "Bastion RDP auto-allowed" not_applicable "Auto-allow was disabled by configuration; approve a Just-in-Time request before each RDP session."
        fi
    else
        record_check "Azure Bastion provisioned" not_applicable "Bastion was disabled by configuration."
    fi

    ext_state="$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name futon-manufacturing-bootstrap --query provisioningState -o tsv 2>/dev/null || true)"
    [[ "$ext_state" == Succeeded ]] && record_check "Futon Manufacturing sample database restored" pass "Bootstrap Custom Script Extension finished successfully." \
        || record_check "Futon Manufacturing sample database restored" unknown "Bootstrap extension state: ${ext_state:-unavailable}."

    if [[ "$DEPLOY_WEB_APP" != true || -z "$WEB_APP_NAME" ]]; then
        record_check "Pawton Manufacturing dashboard is running" not_applicable "Disabled by configuration."
        return 0
    fi

    web_app_state="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --query state -o tsv 2>/dev/null || true)"
    [[ "$web_app_state" == Running ]] && record_check "Pawton Manufacturing Web App is running" pass "App Service reports state '$web_app_state'." \
        || record_check "Pawton Manufacturing Web App is running" unknown "App Service reports state '${web_app_state:-unavailable}'."

    web_app_subnet="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --query virtualNetworkSubnetId -o tsv 2>/dev/null || true)"
    if [[ -n "$web_app_subnet" && "$web_app_subnet" == *webapp-integration-subnet* ]]; then
        record_check "Web App reaches SQL over a private VNet connection" pass "Regional VNet integration is configured; no public database endpoint is involved."
    else
        record_check "Web App reaches SQL over a private VNet connection" unknown "virtualNetworkSubnetId reported: '${web_app_subnet:-none}'."
    fi

    if [[ -n "$KEY_VAULT_NAME" ]] && az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name sql-app-login-password --query id -o tsv >/dev/null 2>&1; then
        record_check "SQL app login password retrievable from Key Vault" pass "Secret 'sql-app-login-password' exists in $KEY_VAULT_NAME and is readable with the current identity."
    else
        record_check "SQL app login password retrievable from Key Vault" unknown "Could not confirm the secret in ${KEY_VAULT_NAME:-the Key Vault}; the current identity may lack the Key Vault Secrets Officer/User role."
    fi

    # Defender for App Service is a subscription-wide plan, so this Web App is covered by the
    # same plan Scenario 1 requests -- this check demonstrates that shared coverage, not a
    # separate activation, which is why this script never calls 'az security pricing create' for it.
    defender_appservices_tier="$(az security pricing show --name AppServices --query pricingTier -o tsv 2>/dev/null || true)"
    if [[ "$defender_appservices_tier" == Standard ]]; then
        record_check "Defender for App Service covers this Web App" pass "Subscription-wide AppServices plan is Standard, so it protects $WEB_APP_NAME automatically."
    else
        record_check "Defender for App Service covers this Web App" unknown "Subscription reports AppServices tier='${defender_appservices_tier:-unknown}'. Enable it via Scenario 1's deploy or 'az security pricing create --name AppServices --tier Standard'."
    fi

    if [[ -n "$WEB_APP_HOSTNAME" ]]; then
        root_http_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "https://$WEB_APP_HOSTNAME/" 2>/dev/null || true)"
        [[ "$root_http_code" == 200 ]] && record_check "Dashboard home page responds" pass "HTTP $root_http_code from https://$WEB_APP_HOSTNAME/." \
            || record_check "Dashboard home page responds" unknown "HTTP ${root_http_code:-no response} from https://$WEB_APP_HOSTNAME/; the Oryx build may still be running."

        health_body="$(curl -sk --max-time 20 "https://$WEB_APP_HOSTNAME/health" 2>/dev/null || true)"
        health_http_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "https://$WEB_APP_HOSTNAME/health" 2>/dev/null || true)"
        if [[ "$health_http_code" == 200 && "$health_body" == *'"connected"'* ]]; then
            record_check "Dashboard reaches the SQL Server VM" pass "/health reports the database connected."
        else
            record_check "Dashboard reaches the SQL Server VM" unknown "/health returned HTTP ${health_http_code:-no response}: ${health_body:-no body}."
        fi
    else
        record_check "Dashboard home page responds" unknown "No web app hostname was returned by the deployment outputs."
    fi
}

render_check_rows_html() {
    local i result label detail cls text
    for i in "${!CHECK_LABELS[@]}"; do
        result="${CHECK_RESULTS[$i]}"; label="${CHECK_LABELS[$i]}"; detail="${CHECK_DETAILS[$i]}"
        case "$result" in
            pass) cls=ok; text='Pass' ;;
            fail) cls=bad; text='Failure' ;;
            unknown) cls=warn; text='Not sure' ;;
            *) cls=na; text='Not applicable' ;;
        esac
        printf '<tr><td>%s</td><td><span class="pill %s">%s</span></td><td>%s</td></tr>\n' \
            "$(html_escape "$label")" "$cls" "$text" "$(html_escape "$detail")"
    done
}

write_report() {
    local out_dir out_file pass_count fail_count unknown_count demo_site_html
    local app_version verdict verdict_class verdict_note headline
    out_dir="$OUTPUT_ROOT/$ENVIRONMENT"
    mkdir -p "$out_dir"
    out_file="$out_dir/sql-deployment-$ENVIRONMENT.html"
    FINAL_REPORT_FILE="$out_file"
    RUN_ENDED_ISO="${RUN_ENDED_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    pass_count=0; fail_count=0; unknown_count=0
    for r in "${CHECK_RESULTS[@]}"; do
        case "$r" in
            pass) pass_count=$((pass_count + 1)) ;;
            fail) fail_count=$((fail_count + 1)) ;;
            unknown) unknown_count=$((unknown_count + 1)) ;;
        esac
    done
    app_version="$(sed -n 's/.*"version"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/package.json" 2>/dev/null | head -1)"
    app_version="${app_version:-unknown}"
    if [[ -n "$WEB_APP_HOSTNAME" ]]; then
        demo_site_html="<a href=\"https://$WEB_APP_HOSTNAME/\" target=\"_blank\" rel=\"noopener\">https://$WEB_APP_HOSTNAME/</a><br><a href=\"https://$WEB_APP_HOSTNAME/api/status\" target=\"_blank\" rel=\"noopener\">/api/status</a> &middot; <a href=\"https://$WEB_APP_HOSTNAME/health\" target=\"_blank\" rel=\"noopener\">/health</a>"
    else
        demo_site_html='Not deployed (deployWebApp=false).'
    fi

    if ((fail_count > 0)); then
        verdict="FAILED"; verdict_class="bad"
        verdict_note="$fail_count check(s) failed. Review the verification matrix below before relying on this environment."
    elif ((unknown_count > 0)); then
        verdict="COMPLETED WITH WARNINGS"; verdict_class="warn"
        verdict_note="$unknown_count check(s) could not be confirmed automatically. Review the verification matrix below."
    else
        verdict="SUCCEEDED"; verdict_class="ok"
        verdict_note="All $pass_count checks passed."
    fi
    headline="Scenario 2 deployment: $ENVIRONMENT"

    cat > "$out_file" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(html_escape "$(project_meta name 'Ninja Paws Cloud Security Dojo')") — Scenario 2 deployment ($ENVIRONMENT)</title>
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
    code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: 13px; background: #eef2f8; padding: 1px 5px; border-radius: 5px; }
    a { color: #1769aa; }
    .pill { display: inline-block; padding: 4px 10px; border-radius: 99px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; font-size: 11px; white-space: nowrap; }
    .pill.ok { background: #e7f5ee; color: #176b43; }
    .pill.bad { background: #fdeaea; color: #a02020; }
    .pill.warn { background: #fdf3e0; color: #8a5a10; }
    .pill.na { background: #f0eef6; color: #5b4f80; }
    .verdict { font-size: 15px; padding: 7px 16px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #e7edf5; vertical-align: top; overflow-wrap: anywhere; }
    th { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #68758a; }
    .banner { padding: 14px 16px; border-radius: 10px; background: #fdeaea; border: 1px solid #f3c9c9; color: #7d1f1f; margin-top: 14px; }
    footer { margin: 24px 0 8px; padding: 20px 22px; border-top: 3px solid #d98932; background: #fff; border-radius: 14px; border: 1px solid #dbe3ee; }
    footer p { margin: 5px 0; font-size: 12px; color: #68758a; }
    footer .disclaimer { color: #7d1f1f; background: #fdeaea; border: 1px solid #f3c9c9; border-radius: 8px; padding: 10px 12px; font-size: 12px; }
    @media (max-width: 600px) { body { padding: 14px; } h1 { font-size: 23px; } }
    @media print {
        @page { size: A4; margin: 14mm 12mm; }
        :root, body { background: #fff !important; }
        body { padding: 0; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        main { max-width: none; }
        header, section, footer { box-shadow: none; border: 1px solid #d4dbe6; border-radius: 8px; break-inside: avoid; page-break-inside: avoid; }
        table { break-inside: avoid; page-break-inside: avoid; }
        tr { break-inside: avoid; page-break-inside: avoid; }
        thead { display: table-header-group; }
    }
</style>
</head>
<body>
<main>
    <header>
        <div class="brand"><span class="mark">NP</span><span><strong>NINJA PAWS</strong><small> CLOUD SECURITY DOJO</small></span></div>
        <h1>$(html_escape "$headline")</h1>
        <p>Azure lifecycle command <code>deploy-sql-scenario.sh deploy</code> targeting environment <strong>$(html_escape "$ENVIRONMENT")</strong>.</p>
        <p><span class="pill $verdict_class verdict">$(html_escape "$verdict")</span></p>
        <p>$(html_escape "$verdict_note")</p>
    </header>

    <section>
        <h2>Executive summary</h2>
        <div class="grid">
            <div class="item"><div class="label">Scenario</div><div class="value">$(html_escape "$SCENARIO_NAME")<br><code>$(html_escape "$SCENARIO_ID")</code></div></div>
            <div class="item"><div class="label">Environment</div><div class="value">$(html_escape "$ENVIRONMENT")</div></div>
            <div class="item"><div class="label">Resource group</div><div class="value">$(html_escape "$RESOURCE_GROUP")</div></div>
            <div class="item"><div class="label">Region</div><div class="value">$(html_escape "$LOCATION")</div></div>
            <div class="item"><div class="label">VM name / size</div><div class="value">$(html_escape "$VM_NAME") / $(html_escape "$VM_SIZE")</div></div>
            <div class="item"><div class="label">SQL image</div><div class="value">MicrosoftSQLServer:sql2022-ws2022:$(html_escape "$SQL_IMAGE_SKU")</div></div>
            <div class="item"><div class="label">Sample database</div><div class="value">Futon Manufacturing (<a href="https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/futon-manufacturing" target="_blank" rel="noopener">source</a>)</div></div>
            <div class="item"><div class="label">Defender for Servers</div><div class="value">$(html_escape "$DEFENDER_SERVERS_PLAN") / $(html_escape "$DEFENDER_SERVERS_SUBPLAN")</div></div>
            <div class="item"><div class="label">Defender for SQL</div><div class="value">$(html_escape "$DEFENDER_SQL_PLAN")</div></div>
            <div class="item"><div class="label">Pawton Manufacturing dashboard</div><div class="value">$(html_escape "$WEB_APP_NAME") ($(html_escape "$WEB_APP_PLAN_SKU"))</div></div>
            <div class="item"><div class="label">Checks passed</div><div class="value">$pass_count / ${#CHECK_RESULTS[@]}</div></div>
            <div class="item"><div class="label">Run started (UTC)</div><div class="value">$(html_escape "$RUN_STARTED_ISO")</div></div>
        </div>
        $( ((fail_count > 0)) && printf '<div class="banner"><strong>%s check(s) failed.</strong> See the verification matrix below.</div>' "$fail_count" )
    </section>

    <section>
        <h2>Run audit</h2>
        <p>Who ran this lifecycle command, from which repo state, against which Azure identity.</p>
        <div class="grid">
            <div class="item"><div class="label">Run ID</div><div class="value"><code>$(html_escape "$RUN_ID")</code></div></div>
            <div class="item"><div class="label">Command</div><div class="value"><code>deploy-sql-scenario.sh $(html_escape "$RUN_INVOCATION")</code></div></div>
            <div class="item"><div class="label">Started / Ended UTC</div><div class="value">$(html_escape "$RUN_STARTED_ISO")<br>$(html_escape "$RUN_ENDED_ISO")</div></div>
            <div class="item"><div class="label">Duration</div><div class="value">$(( $(date +%s) - RUN_STARTED_AT )) seconds</div></div>
            <div class="item"><div class="label">Operator</div><div class="value">$(html_escape "$RUN_OPERATOR")</div></div>
            <div class="item"><div class="label">Origin</div><div class="value">$(html_escape "$RUN_ORIGIN")<br><span class="label">$(html_escape "$RUN_ORIGIN_DETAIL")</span></div></div>
            <div class="item"><div class="label">Git branch</div><div class="value">$(html_escape "$GIT_BRANCH")</div></div>
            <div class="item"><div class="label">Git commit</div><div class="value"><code>$(html_escape "$GIT_COMMIT")</code></div></div>
            <div class="item"><div class="label">Working tree</div><div class="value">$(html_escape "$GIT_DIRTY")</div></div>
            <div class="item"><div class="label">Tool version</div><div class="value">v$(html_escape "$APP_VERSION") / config v$(html_escape "$CONFIG_VERSION")</div></div>
            <div class="item"><div class="label">Azure identity</div><div class="value">$(html_escape "${AZURE_ACCOUNT_NAME:-not recorded}")</div></div>
            <div class="item"><div class="label">Tenant / Subscription</div><div class="value"><code>$(html_escape "$(mask_identifier "$AZURE_TENANT_ID")")</code><br>$(html_escape "${SUBSCRIPTION_NAME:-unknown}") / <code>$(html_escape "$(mask_identifier "$SUBSCRIPTION_ID")")</code></div></div>
        </div>
    </section>

    <section>
        <h2>Verification matrix</h2>
        <p>Every automated check run against the live Azure environment after deployment.</p>
        <table>
            <thead><tr><th>Check</th><th>Result</th><th>Detail</th></tr></thead>
            <tbody>
$(render_check_rows_html)
            </tbody>
        </table>
    </section>

    <section>
        <h2>Environment access</h2>
        <div class="grid">
            <div class="item"><div class="label">Live demo site</div><div class="value">$demo_site_html</div></div>
            <div class="item"><div class="label">Resource group (portal)</div><div class="value"><a href="https://portal.azure.com/#@/resource/subscriptions/$(html_escape "$SUBSCRIPTION_ID")/resourceGroups/$(html_escape "$RESOURCE_GROUP")/overview" target="_blank" rel="noopener">$(html_escape "$RESOURCE_GROUP")</a></div></div>
            <div class="item"><div class="label">Connect (Azure Bastion)</div><div class="value">Portal &gt; $(html_escape "$VM_NAME") &gt; Connect &gt; Bastion.</div></div>
            <div class="item"><div class="label">SQL public endpoint</div><div class="value">$(html_escape "${SQL_PUBLIC_IP:-not deployed}"):1433</div></div>
            <div class="item"><div class="label">VM admin credentials</div><div class="value"><code>$(html_escape "$OUTPUT_ROOT/$ENVIRONMENT/sql-vm-credentials.txt")</code><br>Local file only, not committed. Delete it once you finish the exercise.</div></div>
            <div class="item"><div class="label">SQL app login password</div><div class="value">Key Vault <code>$(html_escape "${KEY_VAULT_NAME:-not deployed}")</code>, secret <code>sql-app-login-password</code></div></div>
            <div class="item"><div class="label">Defender recommendations</div><div class="value"><a href="https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade" target="_blank" rel="noopener">Security recommendations</a></div></div>
            <div class="item"><div class="label">Bootstrap log on the VM</div><div class="value"><code>C:\NinjaPawsDojo\bootstrap.log</code></div></div>
        </div>
    </section>

    <footer>
        <p class="disclaimer"><strong>USE AT YOUR OWN RISK.</strong> $(html_escape "$(project_meta disclaimer 'Provided as-is, without warranty of any kind.')") This provisions a billable Azure VM and Log Analytics workspace; keep it in an isolated subscription and delete it with the uninstall command when the exercise ends.</p>
        <p>$(html_escape "$(project_meta name 'Ninja Paws Cloud Security Dojo')") v$(html_escape "$app_version") &middot; $(html_escape "$(project_meta copyright 'Copyright (c) Ninja Paws')") &middot; Licensed under $(html_escape "$(project_meta license MIT)") &middot; Provided as-is, without warranty. Generated $(date -u +%Y-%m-%dT%H:%M:%SZ).</p>
    </footer>
</main>
</body>
</html>
HTML
    ok "Report written to $out_file"
}

cmd_deploy() {
    require_login
    initialize_status_report
    update_status "Reviewing plan" "Resolved Scenario 2 settings and waiting for deployment confirmation." 12
    print_plan
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Proceed with deployment? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || fail "Aborted."
    fi
    update_status "Preparing resource group" "Ensuring the Scenario 2 resource group exists." 18
    ensure_resource_group
    ensure_central_workspace
    run_deployment
    run_verification
    update_status "Writing audit report" "Writing the final Scenario 2 audit and verification report." 96
    write_report
    complete_status "Complete" "Scenario 2 deployment completed. The final audit report is linked from this page." 100
    echo
    ok "Scenario 2 deployment complete. See the report above for verification results."
    [[ -n "$WEB_APP_HOSTNAME" ]] && echo -e "${GREEN}Pawton Manufacturing dashboard:${NC} https://$WEB_APP_HOSTNAME/ (Oryx build can take a couple of minutes after this script finishes)"
    echo -e "${YELLOW}Reminder:${NC} run '$0 uninstall --environment $ENVIRONMENT --yes' when finished to avoid ongoing VM charges."
}

cmd_uninstall() {
    require_login
    initialize_status_report
    update_status "Confirming uninstall" "Preparing to delete the Scenario 2 resource group." 20
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Delete resource group '$RESOURCE_GROUP' and everything in it? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || fail "Aborted."
    fi
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        info "Deleting resource group '$RESOURCE_GROUP'..."
        update_status "Deleting resource group" "Azure accepted teardown for $RESOURCE_GROUP; deletion continues asynchronously." 70
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait --output none
        ok "Deletion requested. It will finish asynchronously in Azure."
        complete_status "Complete" "Deletion was requested. Monitor the resource group in Azure until it disappears." 100
    else
        warn "Resource group '$RESOURCE_GROUP' does not exist; nothing to delete."
        complete_status "Complete" "Resource group $RESOURCE_GROUP did not exist; nothing was deleted." 100
    fi
}

resolve_audit_context

case "$COMMAND" in
    plan) cmd_plan ;;
    doctor) cmd_doctor ;;
    deploy) cmd_deploy ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 1 ;;
esac

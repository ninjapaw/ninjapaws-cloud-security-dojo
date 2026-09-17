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
ADMIN_USERNAME="${SQL_VM_ADMIN_USERNAME:-ninjapawsadmin}"
ASSUME_YES=false
OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/output}"
RUN_STARTED_AT="$(date +%s)"
RUN_STARTED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# config_lookup and config_scenario_ids come from lib/common.sh.
config_setting() {
    local key="$1" fallback="$2" value
    value="$(config_lookup "environments.$ENVIRONMENT.$key")"
    [[ -n "$value" ]] || value="$(config_lookup "sqlScenario.$key")"
    printf '%s' "${value:-$fallback}"
}

fail() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 1; }
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
  --admin-username <name>    Windows admin username (default: ninjapawsadmin)
  --defaults                 Accepted for CLI consistency with deploy.sh; this script has no
                              interactive setting prompts to skip. Use --yes to also skip the
                              deployment confirmation prompt.
  --yes                      Skip confirmation prompts
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
        --admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
        --defaults) shift ;;
        --yes) ASSUME_YES=true; shift ;;
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
VM_SIZE="$(config_setting vmSize Standard_D4s_v5)"
SQL_IMAGE_SKU="$(config_setting sqlImageSku sqldev)"
DEPLOY_BASTION="$(config_setting deployBastion true)"
DEFENDER_SERVERS_PLAN="$(config_lookup sqlScenario.defender.serversPlan)"
DEFENDER_SERVERS_PLAN="${DEFENDER_SERVERS_PLAN:-VirtualMachines}"
DEFENDER_SERVERS_SUBPLAN="$(config_lookup sqlScenario.defender.serversSubPlan)"
DEFENDER_SERVERS_SUBPLAN="${DEFENDER_SERVERS_SUBPLAN:-P2}"
DEFENDER_SQL_PLAN="$(config_lookup sqlScenario.defender.sqlPlan)"
DEFENDER_SQL_PLAN="${DEFENDER_SQL_PLAN:-SqlServerVirtualMachines}"
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'dev')"
BOOTSTRAP_SCRIPT_URL="https://raw.githubusercontent.com/ninjapaw/ninjapaws-cloud-security-dojo/${GIT_BRANCH}/scripts/sql/Setup-FutonManufacturing.ps1"
BICEP_FILE="$AZURE_REPO_ROOT/infra/sql-defender-scenario/main.bicep"

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
${BLUE}Azure Bastion:${NC} $DEPLOY_BASTION (no public IP is attached to the VM)
${BLUE}Defender for Servers:${NC} $DEFENDER_SERVERS_PLAN / $DEFENDER_SERVERS_SUBPLAN (includes Defender for Endpoint)
${BLUE}Defender for SQL:${NC} $DEFENDER_SQL_PLAN (Standard tier)
${BLUE}Bootstrap script:${NC} $BOOTSTRAP_SCRIPT_URL

EOF
}

cmd_plan() {
    info "Dry run — no Azure calls will be made."
    print_plan
}

cmd_doctor() {
    require_login
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

run_deployment() {
    local admin_password deployment_name output_json vm_principal_id creds_dir creds_file
    admin_password="$(generate_password)"
    deployment_name="sql-scenario-$(date -u +%Y%m%dT%H%M%SZ)"

    info "Deploying infrastructure ($deployment_name)..."
    output_json="$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$deployment_name" \
        --template-file "$BICEP_FILE" \
        --parameters vmName="$VM_NAME" adminUsername="$ADMIN_USERNAME" adminPassword="$admin_password" \
                     vmSize="$VM_SIZE" sqlImageSku="$SQL_IMAGE_SKU" bootstrapScriptUrl="$BOOTSTRAP_SCRIPT_URL" \
                     deployBastion="$DEPLOY_BASTION" \
        --query "properties.outputs" -o json)" || fail "Bicep deployment failed. Re-run with 'az deployment group create' directly for full diagnostics."
    ok "Infrastructure deployed."

    # The generated admin password is otherwise unrecoverable, and this VM has no public IP,
    # so the only way to sign in over Bastion afterward is to persist it to the gitignored
    # local output/ directory. Never print it to stdout, which CI systems capture in logs.
    creds_dir="$OUTPUT_ROOT/$ENVIRONMENT"
    mkdir -p "$creds_dir"
    creds_file="$creds_dir/sql-vm-credentials.txt"
    {
        printf 'VM name:        %s\n' "$VM_NAME"
        printf 'Admin username: %s\n' "$ADMIN_USERNAME"
        printf 'Admin password: %s\n' "$admin_password"
        printf 'Generated:      %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'Connect through Azure Bastion in the portal; this VM has no public IP.\n'
    } > "$creds_file"
    chmod 600 "$creds_file" 2>/dev/null || true
    unset admin_password
    warn "Admin credentials saved to $creds_file — treat it as a secret and delete it once you finish the exercise."
    record_check "VM admin credentials saved locally" pass "Written to $creds_file (not committed; output/ is gitignored). Delete this file when the exercise ends."

    vm_principal_id="$(printf '%s' "$output_json" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).principalId.value)" 2>/dev/null || true)"
    if [[ -n "$vm_principal_id" ]]; then
        record_check "VM has a system-assigned managed identity" pass "principalId $vm_principal_id is available for future Key Vault or RBAC assignments."
    else
        record_check "VM has a system-assigned managed identity" unknown "Could not read the managed identity principal ID from deployment outputs."
    fi

    info "Activating Defender for Servers ($DEFENDER_SERVERS_SUBPLAN) — includes Defender for Endpoint onboarding..."
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
    local attempt=0 ext_state=""
    while ((attempt < 60)); do
        ext_state="$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name futon-manufacturing-bootstrap --query provisioningState -o tsv 2>/dev/null || true)"
        [[ "$ext_state" == Succeeded || "$ext_state" == Failed ]] && break
        sleep 15
        attempt=$((attempt + 1))
    done
    [[ "$ext_state" == Succeeded ]] && ok "Bootstrap extension finished: $ext_state" || warn "Bootstrap extension state: ${ext_state:-unknown} — check the VM's C:\\NinjaPawsDojo\\bootstrap.log over Bastion."
}

run_verification() {
    info "Running verification checks..."
    local vm_state defender_servers_tier defender_servers_subplan defender_sql_tier nic_public_ip bastion_state sqlvm_state ext_state

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
    if [[ -z "$nic_public_ip" ]]; then
        record_check "SQL Server VM has no public IP" pass "The VM NIC has no public IP address; management traffic goes through Azure Bastion only."
    else
        record_check "SQL Server VM has no public IP" fail "A public IP is attached to the VM NIC: $nic_public_ip."
    fi

    if [[ "$DEPLOY_BASTION" == true ]]; then
        bastion_state="$(az network bastion show --resource-group "$RESOURCE_GROUP" --name "${VM_NAME}-bastion" --query provisioningState -o tsv 2>/dev/null || true)"
        [[ "$bastion_state" == Succeeded ]] && record_check "Azure Bastion provisioned" pass "Bastion is available for browser-based RDP." \
            || record_check "Azure Bastion provisioned" unknown "Provisioning state: ${bastion_state:-unavailable}."
    else
        record_check "Azure Bastion provisioned" not_applicable "Bastion was disabled by configuration."
    fi

    ext_state="$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name futon-manufacturing-bootstrap --query provisioningState -o tsv 2>/dev/null || true)"
    [[ "$ext_state" == Succeeded ]] && record_check "Futon Manufacturing sample database restored" pass "Bootstrap Custom Script Extension finished successfully." \
        || record_check "Futon Manufacturing sample database restored" unknown "Bootstrap extension state: ${ext_state:-unavailable}."
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
            "$label" "$cls" "$text" "$detail"
    done
}

write_report() {
    local out_dir out_file pass_count fail_count unknown_count
    out_dir="$OUTPUT_ROOT/$ENVIRONMENT"
    mkdir -p "$out_dir"
    out_file="$out_dir/sql-deployment-$ENVIRONMENT.html"
    pass_count=0; fail_count=0; unknown_count=0
    for r in "${CHECK_RESULTS[@]}"; do
        case "$r" in
            pass) pass_count=$((pass_count + 1)) ;;
            fail) fail_count=$((fail_count + 1)) ;;
            unknown) unknown_count=$((unknown_count + 1)) ;;
        esac
    done

    cat > "$out_file" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ninja Paws Dojo — SQL Scenario Deployment ($ENVIRONMENT)</title>
<style>
  :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background:#0a1220; color:#d9e7f5; }
  body { margin:0; padding:24px 32px 48px; }
  h1 { color:#f2a24a; font-size:20px; letter-spacing:.03em; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:10px 18px; margin:18px 0 28px; }
  .item { border:1px solid #28415c; border-radius:10px; padding:10px 14px; background:#0d1a2b; }
  .label { color:#8fa6bc; font-size:11px; text-transform:uppercase; letter-spacing:.08em; }
  .value { font-size:14px; margin-top:4px; }
  table { border-collapse:collapse; width:100%; margin-top:8px; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid #28415c; font-size:13px; }
  th { color:#8fa6bc; text-transform:uppercase; font-size:11px; letter-spacing:.06em; }
  .pill { display:inline-block; padding:2px 8px; border-radius:999px; font-size:11px; font-weight:600; }
  .pill.ok { background:#123a25; color:#7be2a5; }
  .pill.bad { background:#3a1c1c; color:#f0b4b4; }
  .pill.warn { background:#3a2f14; color:#f2cf7c; }
  .pill.na { background:#1c2636; color:#8fa6bc; }
  .warn-strip { padding:10px 14px; border-radius:8px; background:#3a1c1c; border:1px solid #6d2b2b; color:#f0b4b4; font-size:12px; margin-bottom:20px; }
  .foot { margin-top:28px; color:#58718b; font-size:11px; }
  a { color:#7cc4f2; }
</style>
</head>
<body>
<h1>Ninja Paws Cloud Security Dojo — Scenario 2: SQL Server on Azure VM Protection</h1>
<div class="warn-strip"><strong>USE AT YOUR OWN RISK.</strong> This provisions a billable Azure VM and Log Analytics workspace. Keep it in an isolated subscription and delete it with the uninstall command when the exercise ends.</div>
<div class="grid">
  <div class="item"><div class="label">Scenario</div><div class="value">$SCENARIO_NAME</div></div>
  <div class="item"><div class="label">Environment</div><div class="value">$ENVIRONMENT</div></div>
  <div class="item"><div class="label">Resource group</div><div class="value">$RESOURCE_GROUP</div></div>
  <div class="item"><div class="label">Region</div><div class="value">$LOCATION</div></div>
  <div class="item"><div class="label">VM name / size</div><div class="value">$VM_NAME / $VM_SIZE</div></div>
  <div class="item"><div class="label">SQL image</div><div class="value">MicrosoftSQLServer:sql2022-ws2022:$SQL_IMAGE_SKU</div></div>
  <div class="item"><div class="label">Sample database</div><div class="value">Futon Manufacturing (<a href="https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/futon-manufacturing" target="_blank" rel="noopener">source</a>)</div></div>
  <div class="item"><div class="label">Defender for Servers</div><div class="value">$DEFENDER_SERVERS_PLAN / $DEFENDER_SERVERS_SUBPLAN</div></div>
  <div class="item"><div class="label">Defender for SQL</div><div class="value">$DEFENDER_SQL_PLAN</div></div>
  <div class="item"><div class="label">Checks passed</div><div class="value">$pass_count / ${#CHECK_RESULTS[@]}</div></div>
  <div class="item"><div class="label">Checks failed / not sure</div><div class="value">$fail_count / $unknown_count</div></div>
  <div class="item"><div class="label">Run started</div><div class="value">$RUN_STARTED_ISO</div></div>
</div>
<h2>Verification matrix</h2>
<table>
  <thead><tr><th>Check</th><th>Result</th><th>Detail</th></tr></thead>
  <tbody>
$(render_check_rows_html)
  </tbody>
</table>
<h2>Environment access</h2>
<div class="grid">
  <div class="item"><div class="label">Resource group (portal)</div><div class="value"><a href="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview" target="_blank" rel="noopener">$RESOURCE_GROUP</a></div></div>
  <div class="item"><div class="label">Connect (Azure Bastion)</div><div class="value">Portal &gt; $VM_NAME &gt; Connect &gt; Bastion. No public IP is exposed on this VM.</div></div>
  <div class="item"><div class="label">VM admin credentials</div><div class="value"><code>$OUTPUT_ROOT/$ENVIRONMENT/sql-vm-credentials.txt</code><br>Local file only, not committed. Delete it once you finish the exercise.</div></div>
  <div class="item"><div class="label">Defender recommendations</div><div class="value"><a href="https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade" target="_blank" rel="noopener">Security recommendations</a></div></div>
  <div class="item"><div class="label">Bootstrap log on the VM</div><div class="value"><code>C:\NinjaPawsDojo\bootstrap.log</code></div></div>
</div>
<div class="foot">Ninja Paws Cloud Security Dojo &middot; Independent community project &middot; Provided as-is, without warranty. Generated $(date -u +%Y-%m-%dT%H:%M:%SZ).</div>
</body>
</html>
HTML
    ok "Report written to $out_file"
}

cmd_deploy() {
    require_login
    print_plan
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Proceed with deployment? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || fail "Aborted."
    fi
    ensure_resource_group
    run_deployment
    run_verification
    write_report
    echo
    ok "Scenario 2 deployment complete. See the report above for verification results."
    echo -e "${YELLOW}Reminder:${NC} run '$0 uninstall --environment $ENVIRONMENT --yes' when finished to avoid ongoing VM charges."
}

cmd_uninstall() {
    require_login
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Delete resource group '$RESOURCE_GROUP' and everything in it? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || fail "Aborted."
    fi
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        info "Deleting resource group '$RESOURCE_GROUP'..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait --output none
        ok "Deletion requested. It will finish asynchronously in Azure."
    else
        warn "Resource group '$RESOURCE_GROUP' does not exist; nothing to delete."
    fi
}

case "$COMMAND" in
    plan) cmd_plan ;;
    doctor) cmd_doctor ;;
    deploy) cmd_deploy ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 1 ;;
esac

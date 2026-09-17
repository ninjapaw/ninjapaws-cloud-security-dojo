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
  --web-app-name <name>      Override the Pawton Manufacturing Web App name
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
        --web-app-name) WEB_APP_NAME="$2"; shift 2 ;;
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
VM_SIZE="$(config_setting vmSize Standard_D4s_v4)"
SQL_IMAGE_SKU="$(config_setting sqlImageSku sqldev-gen2)"
DEPLOY_BASTION="$(config_setting deployBastion true)"
DEFENDER_SERVERS_PLAN="$(config_lookup sqlScenario.defender.serversPlan)"
DEFENDER_SERVERS_PLAN="${DEFENDER_SERVERS_PLAN:-VirtualMachines}"
DEFENDER_SERVERS_SUBPLAN="$(config_lookup sqlScenario.defender.serversSubPlan)"
DEFENDER_SERVERS_SUBPLAN="${DEFENDER_SERVERS_SUBPLAN:-P2}"
DEFENDER_SQL_PLAN="$(config_lookup sqlScenario.defender.sqlPlan)"
DEFENDER_SQL_PLAN="${DEFENDER_SQL_PLAN:-SqlServerVirtualMachines}"
DEPLOY_WEB_APP="$(config_setting deployWebApp true)"
WEB_APP_NAME="${WEB_APP_NAME:-$(config_setting webAppName "ninjapaws-pawton-${ENVIRONMENT}")}"
WEB_APP_PLAN_SKU="$(config_setting webAppPlanSku B1)"
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
${BLUE}Pawton Manufacturing Web App:${NC} $WEB_APP_NAME ($WEB_APP_PLAN_SKU, deployWebApp=$DEPLOY_WEB_APP)
${BLUE}Web App network path:${NC} private regional VNet integration to the SQL VM subnet; no public database endpoint

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

# Reads one "properties.outputs" field out of a bicep deployment's JSON, without a jq dependency.
read_output() {
    printf '%s' "$1" | node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(0,'utf8')).$2.value)" 2>/dev/null || true
}

run_deployment() {
    local admin_password sql_app_login_password deployment_name output_json vm_principal_id creds_dir creds_file
    admin_password="$(generate_password)"
    sql_app_login_password="$(generate_password)"
    deployment_name="sql-scenario-$(date -u +%Y%m%dT%H%M%SZ)"

    info "Deploying infrastructure ($deployment_name)..."
    output_json="$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$deployment_name" \
        --template-file "$BICEP_FILE" \
        --parameters vmName="$VM_NAME" adminUsername="$ADMIN_USERNAME" adminPassword="$admin_password" \
                     vmSize="$VM_SIZE" sqlImageSku="$SQL_IMAGE_SKU" bootstrapScriptUrl="$BOOTSTRAP_SCRIPT_URL" \
                     deployBastion="$DEPLOY_BASTION" deployWebApp="$DEPLOY_WEB_APP" webAppName="$WEB_APP_NAME" \
                     webAppPlanSku="$WEB_APP_PLAN_SKU" sqlAppLoginPassword="$sql_app_login_password" \
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

    KEY_VAULT_NAME="$(read_output "$output_json" keyVaultName)"
    WEB_APP_HOSTNAME="$(read_output "$output_json" webAppHostName)"
    unset sql_app_login_password
    if [[ -n "$KEY_VAULT_NAME" ]]; then
        record_check "futon_app SQL login password stored in Key Vault" pass "Secret 'sql-app-login-password' in $KEY_VAULT_NAME; retrieve with 'az keyvault secret show --vault-name $KEY_VAULT_NAME --name sql-app-login-password'."
    fi

    vm_principal_id="$(read_output "$output_json" principalId)"
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
    if ! command -v zip >/dev/null 2>&1; then
        record_check "Pawton Manufacturing dashboard deployed" unknown "The 'zip' command is not available here; deploy manually with 'az webapp deploy --resource-group $RESOURCE_GROUP --name $WEB_APP_NAME --src-path <app.zip> --type zip'."
        return 0
    fi
    (cd "$app_dir" && zip -rq "$zip_path" . -x 'node_modules/*' -x 'dist/*' -x '.astro/*')

    info "Deploying to $WEB_APP_NAME (remote build via Oryx)..."
    if deploy_error="$(az webapp deploy --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --src-path "$zip_path" --type zip --async false --output none 2>&1)"; then
        ok "Pawton Manufacturing dashboard code deployed."
        record_check "Pawton Manufacturing dashboard deployed" pass "Zip-deployed $app_dir to $WEB_APP_NAME; Oryx runs the Astro build remotely."
    else
        warn "Web app code deployment failed: ${deploy_error:-no error detail returned}"
        record_check "Pawton Manufacturing dashboard deployed" fail "az webapp deploy failed: ${deploy_error:-no error detail returned}"
    fi
    rm -f "$zip_path"
}

run_verification() {
    info "Running verification checks..."
    local vm_state defender_servers_tier defender_servers_subplan defender_sql_tier nic_public_ip bastion_state sqlvm_state ext_state
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
            <div class="item"><div class="label">Connect (Azure Bastion)</div><div class="value">Portal &gt; $(html_escape "$VM_NAME") &gt; Connect &gt; Bastion. No public IP is exposed on this VM.</div></div>
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
    [[ -n "$WEB_APP_HOSTNAME" ]] && echo -e "${GREEN}Pawton Manufacturing dashboard:${NC} https://$WEB_APP_HOSTNAME/ (Oryx build can take a couple of minutes after this script finishes)"
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

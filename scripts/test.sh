#!/usr/bin/env bash

# Cross-platform repository checks for Linux, macOS, WSL, and Git Bash.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
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
SKIP_AZURE=false
SKIP_REPORT=false
NODE_COMMAND=""

usage() {
    cat <<'EOF'
Run cross-platform deployment and infrastructure checks.

Usage: scripts/test.sh [--skip-azure] [--skip-report]

Options:
  --skip-azure  Skip Azure CLI/Bicep checks when az is unavailable
    --skip-report Skip the generated HTML report smoke test
EOF
}

while (($# > 0)); do
    case "$1" in
        --skip-azure) SKIP_AZURE=true; shift ;;
        --skip-report) SKIP_REPORT=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for command_name in bash git; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "ERROR: '$command_name' is required." >&2; exit 1; }
done
command -v tee >/dev/null 2>&1 || { echo "ERROR: 'tee' is required." >&2; exit 1; }
if command -v node >/dev/null 2>&1; then
    NODE_COMMAND=node
elif command -v node.exe >/dev/null 2>&1; then
    NODE_COMMAND=node.exe
elif [[ -x /mnt/c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/mnt/c/Program Files/nodejs/node.exe'
elif [[ -x /c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/c/Program Files/nodejs/node.exe'
else
    echo "ERROR: Node.js is required for ARM JSON checks." >&2
    exit 1
fi

echo "Checking Bash syntax..."
bash -n "$REPO_ROOT/scripts/deploy.sh"
bash -n "$REPO_ROOT/scripts/setup-azure-github-oidc.sh"
bash -n "$REPO_ROOT/scripts/test.sh"
bash -n "$REPO_ROOT/scripts/determine-version-bump.sh"
bash -n "$REPO_ROOT/entrypoint.sh"
echo "Checking Node.js runtime syntax..."
(
    cd "$REPO_ROOT"
    "$NODE_COMMAND" --check app.js
)

contains_text() {
    local text="$1"
    local expected="$2"
    [[ "$text" == *"$expected"* ]]
}

file_contains() {
    local file="$1"
    local expected="$2"
    local content
    content="$(cat "$file")"
    contains_text "$content" "$expected"
}

echo "Checking ARM JSON..."
"$NODE_COMMAND" -e "for (const file of ['infra/main.json']) JSON.parse(require('fs').readFileSync(file, 'utf8'));" -- "$REPO_ROOT"

echo "Checking package release metadata..."
"$NODE_COMMAND" - <<'NODE'
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8')).packages[''];
if (pkg.name !== 'ninjapaws-cloud-security-dojo') throw new Error('package name drift');
if (!pkg.description || !pkg.repository || !pkg.repository.url.includes(pkg.name)) throw new Error('package repository metadata drift');
if (pkg.license !== 'MIT' || !pkg.author || !Array.isArray(pkg.keywords) || pkg.keywords.length === 0) throw new Error('package identity metadata drift');
if (!lock || lock.name !== pkg.name || lock.version !== pkg.version) throw new Error('package-lock drift');
NODE

echo "Checking managed environment configuration..."
test ! -e "$REPO_ROOT/.env.example"

# config/deploy.config.json's defaults are the single source of truth; local dev
# fallbacks in Dockerfile/docker-compose.yml/Bicep must track them, not repeat a
# second hardcoded literal that can silently drift.
cfg_value() {
    (cd "$REPO_ROOT" && "$NODE_COMMAND" -p "require('./config/deploy.config.json').defaults$1")
}
cfg_base_os_image="$(cfg_value .baseOsImage)"
cfg_base_os_version="$(cfg_value .baseOsVersion)"
cfg_nginx_version="$(cfg_value .nginxVersion)"
cfg_node_major_version="$(cfg_value .nodeMajorVersion)"
cfg_vulnerability_status="$(cfg_value .vulnerabilityStatus)"
cfg_port="$(cfg_value .port)"
cfg_npm_registry_url="$(cfg_value .npmRegistryUrl)"
cfg_npm_use_mirror="$(cfg_value .npmUseMirror)"
cfg_npm_network_mode="$(cfg_value .npmNetworkMode)"
cfg_image_name="$(cfg_value .imageName)"
cfg_container_registry_sku="$(cfg_value .containerRegistrySku)"
cfg_app_service_plan_sku="$(cfg_value .appServicePlanSku)"
cfg_app_service_plan_capacity="$(cfg_value .appServicePlanCapacity)"

file_contains "$REPO_ROOT/Dockerfile" "ARG BASE_OS_IMAGE=${cfg_base_os_image}"
file_contains "$REPO_ROOT/Dockerfile" "ARG BASE_OS_VERSION=${cfg_base_os_version}"
file_contains "$REPO_ROOT/Dockerfile" "ARG NGINX_VERSION=${cfg_nginx_version}"
file_contains "$REPO_ROOT/Dockerfile" "ARG NODE_MAJOR_VERSION=${cfg_node_major_version}"
file_contains "$REPO_ROOT/Dockerfile" "ARG PORT=${cfg_port}"
file_contains "$REPO_ROOT/Dockerfile" 'FROM ${BASE_OS_IMAGE}:${BASE_OS_VERSION}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV BASE_OS_IMAGE=${BASE_OS_IMAGE}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV NODE_MAJOR_VERSION=${NODE_MAJOR_VERSION}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV DEFENDER_ENABLED=${DEFENDER_ENABLED}'
file_contains "$REPO_ROOT/Dockerfile" "ARG NPM_REGISTRY_URL=${cfg_npm_registry_url}"
file_contains "$REPO_ROOT/Dockerfile" "ARG NPM_USE_MIRROR=${cfg_npm_use_mirror}"
file_contains "$REPO_ROOT/Dockerfile" 'NPM_USE_MIRROR'
file_contains "$REPO_ROOT/Dockerfile" "ARG NPM_NETWORK_MODE=${cfg_npm_network_mode}"
file_contains "$REPO_ROOT/Dockerfile" 'npm ci --offline --omit=dev --ignore-scripts'
file_contains "$REPO_ROOT/Dockerfile" 'npm ci --omit=dev --ignore-scripts'
file_contains "$REPO_ROOT/Dockerfile" 'COPY nginx.conf /etc/nginx/nginx.conf.template'
file_contains "$REPO_ROOT/docker-compose.yml" "BASE_OS_IMAGE:-${cfg_base_os_image}"
file_contains "$REPO_ROOT/docker-compose.yml" "BASE_OS_VERSION:-${cfg_base_os_version}"
file_contains "$REPO_ROOT/docker-compose.yml" "NGINX_VERSION:-${cfg_nginx_version}"
file_contains "$REPO_ROOT/docker-compose.yml" "NODE_MAJOR_VERSION:-${cfg_node_major_version}"
file_contains "$REPO_ROOT/docker-compose.yml" "VULNERABILITY_STATUS:-${cfg_vulnerability_status}"
file_contains "$REPO_ROOT/docker-compose.yml" "PORT:-${cfg_port}"
file_contains "$REPO_ROOT/infra/main.bicep" "param imageName string = '${cfg_image_name}'"
file_contains "$REPO_ROOT/infra/main.bicep" "param nginxVersion string = '${cfg_nginx_version}'"
file_contains "$REPO_ROOT/infra/main.bicep" "param vulnerabilityStatus string = '${cfg_vulnerability_status}'"
file_contains "$REPO_ROOT/infra/main.bicep" "param port int = ${cfg_port}"
file_contains "$REPO_ROOT/infra/main.bicep" "param containerRegistrySku string = '${cfg_container_registry_sku}'"
file_contains "$REPO_ROOT/infra/main.bicep" "param appServicePlanSku string = '${cfg_app_service_plan_sku}'"
file_contains "$REPO_ROOT/infra/main.bicep" "param appServicePlanCapacity int = ${cfg_app_service_plan_capacity}"
# Cheapest-by-default: Basic ACR and the smallest Linux-container-capable App Service Plan tier.
[[ "$cfg_container_registry_sku" == Basic ]] || { echo "config/deploy.config.json containerRegistrySku default should be the cheapest tier (Basic), found: $cfg_container_registry_sku" >&2; exit 1; }
[[ "$cfg_app_service_plan_sku" == B1 ]] || { echo "config/deploy.config.json appServicePlanSku default should be the cheapest Linux-container tier (B1), found: $cfg_app_service_plan_sku" >&2; exit 1; }
file_contains "$REPO_ROOT/scripts/deploy.sh" '--registry-sku'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--plan-sku'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--plan-capacity'
file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" 'gh variable set CONTAINER_REGISTRY_SKU'
file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" 'gh variable set APP_SERVICE_PLAN_SKU'
file_contains "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js" 'CONTAINER_REGISTRY_SKU'
file_contains "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js" 'APP_SERVICE_PLAN_SKU'
file_contains "$REPO_ROOT/.github/workflows/uninstall.yml" 'CONTAINER_REGISTRY_SKU'
file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" 'cfg()'
file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" "require('./config/deploy.config.json').defaults"
file_contains "$REPO_ROOT/entrypoint.sh" 'Base OS:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Node.js Major:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Generating NGINX upstream configuration'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_binary_version'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_package_version'
file_contains "$REPO_ROOT/app.js" 'runtime_verification'
file_contains "$REPO_ROOT/app.js" 'advisory_url: ADVISORY_URL'
file_contains "$REPO_ROOT/app.js" 'fixed_version: FIXED_VERSION'
file_contains "$REPO_ROOT/app.js" 'runtimeVerification.vulnerability_detected === true'
file_contains "$REPO_ROOT/app.js" "app.get('/health'"
file_contains "$REPO_ROOT/app.js" "app.get('/api/status'"
file_contains "$REPO_ROOT/app.js" 'runtime_verification.map_regex_enabled'
file_contains "$REPO_ROOT/entrypoint.sh" 'VULNERABILITY_DETECTED=false'
file_contains "$REPO_ROOT/entrypoint.sh" 'detection_reason'
file_contains "$REPO_ROOT/nginx.conf" '127.0.0.1:__APP_PORT__'
file_contains "$REPO_ROOT/nginx.conf" 'include /etc/nginx/scenario.conf'
file_contains "$REPO_ROOT/entrypoint.sh" 'scenario_config_state'
file_contains "$REPO_ROOT/entrypoint.sh" 'map_regex_enabled'
file_contains "$REPO_ROOT/README.md" 'map` is an internal NGINX configuration directive'
file_contains "$REPO_ROOT/DEMO.md" 'The CVE-relevant `map` is an internal NGINX directive'
file_contains "$REPO_ROOT/config/deploy.config.json" '"CloudPosture": "Standard"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"AgentlessServerlessPosture": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"ServerlessContainers": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"connectorEnabled": "true"'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'apply_plan_extensions'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'ensure_devops_connector'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'record_advanced_security_state'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'cspm-monitor-github'
file_contains "$REPO_ROOT/app.js" 'defender_monitoring'
file_contains "$REPO_ROOT/app.js" 'cspm_serverless_protection'
file_contains "$REPO_ROOT/app.js" 'container_registry_vulnerability_assessment'
# ARM renders string(bool) as "True", so the app must not compare case-sensitively.
file_contains "$REPO_ROOT/app.js" 'toLowerCase()'
file_contains "$REPO_ROOT/config/deploy.config.json" '"Arm": "Standard"'
file_contains "$REPO_ROOT/app.js" 'resource_manager_threat_detection'
file_contains "$REPO_ROOT/infra/main.bicep" 'defenderArmTier'
file_contains "$REPO_ROOT/infra/main.bicep" 'defenderCspmTier'
file_contains "$REPO_ROOT/infra/main.bicep" 'DEFENDER_SERVERLESS_PROTECTION'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Scenario 1 vulnerable map/regex configuration'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Select a region by number or name'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Azure subscriptions available to this account:'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'mask_identifier'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'defender-cloud-scenario-1'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--all-scenarios'
file_contains "$REPO_ROOT/config/shared.config.json" 'Defender for Cloud - Scenario 1: NGINX CVE Detection and Remediation'
file_contains "$REPO_ROOT/config/shared.config.json" 'DO NOT EDIT.'
file_contains "$REPO_ROOT/config/shared.config.json" '"configVersion"'
file_contains "$REPO_ROOT/config/shared.config.json" '"disclaimer"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"nameTag": "(Preview)"'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'SHARED_CONFIG_FILE'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'config_lookup_file'
file_contains "$REPO_ROOT/infra/main.bicep" 'APP_NAME_TAG'
file_contains "$REPO_ROOT/infra/main.json" 'APP_NAME_TAG'
file_contains "$REPO_ROOT/app.js" 'DISPLAY_NAME'
file_contains "$REPO_ROOT/DEMO.md" 'Defender for Cloud - Scenario 1'

echo "Checking automatic version-bump and release workflows..."
file_contains "$REPO_ROOT/scripts/determine-version-bump.sh" 'BREAKING'
file_contains "$REPO_ROOT/scripts/determine-version-bump.sh" 'models.github.ai'
file_contains "$REPO_ROOT/.github/workflows/request-release.yml" 'default: auto'
file_contains "$REPO_ROOT/.github/workflows/request-release.yml" 'determine-version-bump.sh'
file_contains "$REPO_ROOT/.github/workflows/request-release.yml" 'configVersion'
file_contains "$REPO_ROOT/.github/workflows/publish-release.yml" 'config_version'
file_contains "$REPO_ROOT/.github/workflows/publish-release.yml" '--latest=true'
file_contains "$REPO_ROOT/.github/workflows/publish-dev-prerelease.yml" '--prerelease'
file_contains "$REPO_ROOT/.github/workflows/publish-dev-prerelease.yml" '--latest=false'
file_contains "$REPO_ROOT/.github/workflows/publish-dev-prerelease.yml" 'determine-version-bump.sh'
bump_output="$(bash "$REPO_ROOT/scripts/determine-version-bump.sh" --no-ai)"
contains_text "$bump_output" 'bump=' || { echo "determine-version-bump.sh did not print a bump=... line." >&2; exit 1; }
file_contains "$REPO_ROOT/DEMO.md" 'real NGINX vulnerability'

echo "Checking shared runtime-defaults action is used instead of duplicated literals..."
"$NODE_COMMAND" --check "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js"
file_contains "$REPO_ROOT/.github/actions/resolve-defaults/action.yml" "using: composite"
file_contains "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js" "config/deploy.config.json"
for workflow_file in deploy.yml publish-release.yml request-release.yml publish-dev-prerelease.yml uninstall.yml; do
    file_contains "$REPO_ROOT/.github/workflows/$workflow_file" './.github/actions/resolve-defaults'
done
resolve_output="$(cd "$REPO_ROOT" && VARS_JSON='{}' "$NODE_COMMAND" .github/actions/resolve-defaults/resolve.js)"
contains_text "$resolve_output" 'NGINX_VERSION=' || { echo "resolve-defaults/resolve.js did not resolve NGINX_VERSION from config/deploy.config.json." >&2; exit 1; }
resolve_override="$(cd "$REPO_ROOT" && VARS_JSON='{"NGINX_VERSION":"9.9.9"}' "$NODE_COMMAND" .github/actions/resolve-defaults/resolve.js)"
contains_text "$resolve_override" 'NGINX_VERSION=9.9.9' || { echo "resolve-defaults/resolve.js did not let a GitHub Environment variable override the config default." >&2; exit 1; }
# Deploy/publish workflows must no longer re-hardcode these literal defaults.
for workflow_file in deploy.yml publish-release.yml; do
    ! grep -Eq "vars\.NGINX_VERSION \|\|" "$REPO_ROOT/.github/workflows/$workflow_file" || { echo "$workflow_file still hardcodes a literal NGINX_VERSION default." >&2; exit 1; }
done
file_contains "$REPO_ROOT/DEMO.md" 'Patched-State Demonstration'
if [[ "$SKIP_REPORT" == false ]]; then
    rendered_nginx="$(mktemp)"
    test_output="$(mktemp -d)"
    trap 'rm -f "$rendered_nginx"; rm -rf "$test_output"' EXIT
    sed 's/__APP_PORT__/31337/g' "$REPO_ROOT/nginx.conf" > "$rendered_nginx"
    file_contains "$rendered_nginx" 'server 127.0.0.1:31337;'
    status_html="$test_output/dev/deployment-dev.html"
    mkdir -p "$test_output/dev"
    printf 'stale' > "$test_output/dev/stale.marker"
    OUTPUT_ROOT="$test_output" bash "$REPO_ROOT/scripts/deploy.sh" plan --environment dev --defaults --image-tag test-html --no-open-status >/dev/null
    test ! -e "$test_output/dev/stale.marker"
    archive_count=$(find "$test_output/archive" -mindepth 1 -maxdepth 1 -type d -name '*-dev' 2>/dev/null | wc -l | tr -d ' ')
    test "$archive_count" -ge 1
    file_contains "$status_html" 'Executive progress report'
    file_contains "$status_html" 'window.npReport'
    file_contains "$status_html" "deployment-' + ENV + '.state.js"
    file_contains "$status_html" 'NINJA PAWS'
    file_contains "$status_html" 'Task list'
    file_contains "$status_html" 'Live console'
    file_contains "$test_output/dev/deployment-dev.console.html" 'NINJA PAWS DEPLOYMENT CONSOLE'
    file_contains "$test_output/dev/deployment-dev.console.html" 'line'
    file_contains "$status_html" 'Resolved deployment settings'
    file_contains "$status_html" 'deployment-dev.log'
    test ! -e "$REPO_ROOT/deployment-output.json"
    test ! -e "$REPO_ROOT/.azure/deployment-dev.json"
fi
# The guard must refuse whichever environment does not belong to the current branch.
case "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)" in
    dev) guard_environment=prod ;;
    main) guard_environment=dev ;;
    *) guard_environment='' ;;
esac
if [[ -n "$guard_environment" ]]; then
    echo "Checking branch environment guard..."
    guard_config="$(mktemp -d)"
    # An empty Azure config keeps a regressed guard from reaching a real subscription.
    guard_output="$(AZURE_CONFIG_DIR="$guard_config" bash "$REPO_ROOT/scripts/deploy.sh" provision --environment "$guard_environment" --defaults --yes --no-status-html --no-open-status 2>&1 || true)"
    rm -rf "$guard_config"
    if [[ "$guard_output" != *"can only target environment"* ]]; then
        echo "ERROR: the branch guard did not refuse environment '$guard_environment'." >&2
        printf '%s\n' "$guard_output" >&2
        exit 1
    fi
fi
for variable_name in BASE_OS_IMAGE BASE_OS_VERSION NGINX_VERSION NODE_MAJOR_VERSION VULNERABILITY_STATUS PORT NPM_REGISTRY_URL NPM_USE_MIRROR NPM_NETWORK_MODE DEFENDER_ENABLED DEFENDER_SCAN_ENABLED DEFENDER_MANAGE_PLANS DEFENDER_APPSERVICES_TIER DEFENDER_CONTAINERS_TIER DEFENDER_CSPM_TIER DEFENDER_ARM_TIER DEFENDER_MANAGE_EXTENSIONS DEFENDER_CSPM_SERVERLESS_PROTECTION DEFENDER_CSPM_SERVERLESS_CONTAINERS DEFENDER_CSPM_REGISTRY_ASSESSMENT DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT DEFENDER_DEVOPS_CONNECTOR_ENABLED GITHUB_ADVANCED_SECURITY_EXPECTED DEFENDER_DEVOPS_AGENTLESS_CODE_SCANNING_EXPECTED; do
    file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" "gh variable set $variable_name"
    # deploy.yml no longer hardcodes these names; the shared composite action resolves them once.
    file_contains "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js" "$variable_name"
done
# DEFENDER_TARGET_CVE has no config default (it must not duplicate the scenario's own CVE); it stays
# an optional override only, resolved but not seeded.
! grep -q "targetCve" "$REPO_ROOT/config/deploy.config.json" || { echo "config/deploy.config.json should not redeclare defender.targetCve; it duplicates the scenario's cve fact." >&2; exit 1; }
file_contains "$REPO_ROOT/.github/actions/resolve-defaults/resolve.js" "DEFENDER_TARGET_CVE"
! file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" "gh variable set DEFENDER_TARGET_CVE" || { echo "setup-azure-github-oidc.sh should not seed a default DEFENDER_TARGET_CVE." >&2; exit 1; }
file_contains "$REPO_ROOT/scripts/deploy.sh" 'DEFENDER_TARGET_CVE="${DEFENDER_TARGET_CVE:-$SCENARIO_CVE}"'

echo "Checking Microsoft Security DevOps GitHub Action workflow..."
file_contains "$REPO_ROOT/.github/workflows/msdevopssec.yml" 'microsoft/security-devops-action@latest'
file_contains "$REPO_ROOT/.github/workflows/msdevopssec.yml" 'pull_request:'
file_contains "$REPO_ROOT/.github/workflows/msdevopssec.yml" 'security-events: write'
file_contains "$REPO_ROOT/.github/workflows/msdevopssec.yml" 'github/codeql-action/upload-sarif'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'record_agentless_code_scanning_state'
file_contains "$REPO_ROOT/infra/main.bicep" 'agentlessCodeScanningExpected'
file_contains "$REPO_ROOT/infra/main.json" 'agentlessCodeScanningExpected'
file_contains "$REPO_ROOT/app.js" 'agentless_code_scanning_expected'

if [[ "$SKIP_AZURE" == false ]]; then
    command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' is required unless --skip-azure is used." >&2; exit 1; }
    echo "Compiling Bicep..."
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    azure_temp_dir="$temp_dir"
    if command -v wslpath >/dev/null 2>&1; then
        azure_temp_dir="$(wslpath -w "$temp_dir")"
    fi
    az bicep build --file "$AZURE_REPO_ROOT/infra/main.bicep" --outfile "$azure_temp_dir/main.json" >/dev/null
fi

echo "All cross-platform checks passed."
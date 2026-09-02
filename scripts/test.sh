#!/usr/bin/env bash

# Cross-platform repository checks for Linux, macOS, WSL, and Git Bash.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AZURE_REPO_ROOT="$REPO_ROOT"
AZURE_CLI_BIN="${AZURE_CLI_BIN:-az}"
if command -v wslpath >/dev/null 2>&1; then
    AZURE_REPO_ROOT="$(wslpath -w "$REPO_ROOT")"
fi
for azure_cli_dir in "/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" "/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"; do
    if [[ ! -x "$azure_cli_dir/az.cmd" && -f "$azure_cli_dir/az.cmd" ]]; then
        export PATH="$azure_cli_dir:$PATH"
        break
    fi
done
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
bash -n "$REPO_ROOT/scripts/manage.sh"
bash -n "$REPO_ROOT/scripts/setup-azure-github-oidc.sh"
bash -n "$REPO_ROOT/scripts/test.sh"
bash -n "$REPO_ROOT/scripts/verify.sh"
bash -n "$REPO_ROOT/entrypoint.sh"
echo "Checking Node.js runtime syntax..."
(
    cd "$REPO_ROOT"
    "$NODE_COMMAND" --check src/app.js
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
"$NODE_COMMAND" -e "for (const file of ['infra/main.json', 'azuredeploy.json']) JSON.parse(require('fs').readFileSync(file, 'utf8'));" -- "$REPO_ROOT"

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
file_contains "$REPO_ROOT/Dockerfile" 'ARG BASE_OS_IMAGE=ubuntu'
file_contains "$REPO_ROOT/Dockerfile" 'ARG BASE_OS_VERSION=24.04'
file_contains "$REPO_ROOT/Dockerfile" 'FROM ${BASE_OS_IMAGE}:${BASE_OS_VERSION}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV BASE_OS_IMAGE=${BASE_OS_IMAGE}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV NODE_MAJOR_VERSION=${NODE_MAJOR_VERSION}'
file_contains "$REPO_ROOT/Dockerfile" 'ENV DEFENDER_ENABLED=${DEFENDER_ENABLED}'
file_contains "$REPO_ROOT/Dockerfile" 'ARG NPM_REGISTRY_URL=https://registry.npmjs.org'
file_contains "$REPO_ROOT/Dockerfile" 'ARG NPM_USE_MIRROR=true'
file_contains "$REPO_ROOT/Dockerfile" 'NPM_USE_MIRROR'
file_contains "$REPO_ROOT/Dockerfile" 'ARG NPM_NETWORK_MODE=online'
file_contains "$REPO_ROOT/Dockerfile" 'npm ci --offline --omit=dev --ignore-scripts'
file_contains "$REPO_ROOT/Dockerfile" 'npm ci --omit=dev --ignore-scripts'
file_contains "$REPO_ROOT/Dockerfile" 'COPY src ./src'
file_contains "$REPO_ROOT/Dockerfile" 'COPY nginx.conf /etc/nginx/nginx.conf.template'
file_contains "$REPO_ROOT/Dockerfile" 'RUN nginx -v 2>&1 | tee /opt/nginx-version.txt'
file_contains "$REPO_ROOT/Dockerfile" 'RUN dpkg-query -W nginx | tee /opt/nginx-package-version.txt'
file_contains "$REPO_ROOT/Dockerfile" 'RUN dpkg -l | grep nginx | tee /opt/nginx-installed-packages.txt'
file_contains "$REPO_ROOT/Dockerfile" 'LABEL security.repro.cve="CVE-2026-42533"'
file_contains "$REPO_ROOT/Dockerfile" 'LABEL security.repro.version="1.30.3"'
file_contains "$REPO_ROOT/Dockerfile" 'COPY scripts/verify.sh /usr/local/bin/verify.sh'
file_contains "$REPO_ROOT/docker-compose.yml" 'BASE_OS_IMAGE:'
file_contains "$REPO_ROOT/docker-compose.yml" 'BASE_OS_VERSION:'
file_contains "$REPO_ROOT/docker-compose.yml" 'NODE_MAJOR_VERSION:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Base OS:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Node.js Major:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Generating NGINX upstream configuration'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_binary_version'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_package_version'
file_contains "$REPO_ROOT/entrypoint.sh" '===== CVE REPRO ====='
file_contains "$REPO_ROOT/entrypoint.sh" 'cat /opt/nginx-version.txt'
file_contains "$REPO_ROOT/src/app.js" 'runtime_verification'
file_contains "$REPO_ROOT/src/app.js" 'advisory_url: ADVISORY_URL'
file_contains "$REPO_ROOT/src/app.js" 'fixed_version: FIXED_VERSION'
file_contains "$REPO_ROOT/src/app.js" 'runtimeVerification.vulnerability_detected === true'
file_contains "$REPO_ROOT/src/app.js" 'app.get("/health"'
file_contains "$REPO_ROOT/src/app.js" 'app.get("/evidence"'
file_contains "$REPO_ROOT/src/app.js" 'app.get("/api/status"'
file_contains "$REPO_ROOT/src/app.js" '.readFileSync("/opt/nginx-version.txt"'
file_contains "$REPO_ROOT/src/app.js" '.readFileSync("/opt/nginx-package-version.txt"'
file_contains "$REPO_ROOT/src/app.js" '.readFileSync("/opt/nginx-installed-packages.txt"'
file_contains "$REPO_ROOT/scripts/verify.sh" 'expected_version="1.30.3"'
file_contains "$REPO_ROOT/scripts/verify.sh" 'dpkg-query -W nginx'
file_contains "$REPO_ROOT/scripts/verify.sh" 'dpkg -l | grep nginx'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'scripts/verify.sh'
file_contains "$REPO_ROOT/REPRO.md" 'Defender Inventory detects nginx 1.30.3'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'msedge.exe microsoft-edge microsoft-edge-dev edge'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'DEPLOY_BROWSER:-${BROWSER:-}'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Azure login was not completed. The read-only wizard stopped before inspecting Azure.'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'REPORT_LINK_PRINTED=false'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'STATUS_BROWSER_OPENED=false'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'code --open-url'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'account_info="$(az account show --query "[id,tenantId,name,user.name]" -o tsv)"'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'tee "$deployment_output"'
file_contains "$REPO_ROOT/src/app.js" 'runtime_verification.map_regex_enabled'
file_contains "$REPO_ROOT/entrypoint.sh" 'VULNERABILITY_DETECTED=false'
file_contains "$REPO_ROOT/entrypoint.sh" 'detection_reason'
file_contains "$REPO_ROOT/nginx.conf" '127.0.0.1:__APP_PORT__'
file_contains "$REPO_ROOT/nginx.conf" 'include /etc/nginx/scenario.conf'
file_contains "$REPO_ROOT/entrypoint.sh" 'scenario_config_state'
file_contains "$REPO_ROOT/entrypoint.sh" 'map_regex_enabled'
file_contains "$REPO_ROOT/README.md" 'map` is an internal NGINX configuration directive'
file_contains "$REPO_ROOT/README.md" 'Demo Walkthrough'
file_contains "$REPO_ROOT/README.md" 'The vulnerable baseline should show'
file_contains "$REPO_ROOT/config/deploy.config.json" '"CloudPosture": "Standard"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"AgentlessServerlessPosture": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"ServerlessContainers": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"ContainerRegistriesVulnerabilityAssessments": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"AgentlessVmScanning": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"ApiPosture": "true"'
file_contains "$REPO_ROOT/config/deploy.config.json" '"connectorEnabled": "true"'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'apply_plan_extensions'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Registry image security findings'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'CSPM agentless scanning for machines'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'CSPM API Security Posture'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Agentless scanning for machines'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Defender GitHub connector'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'GitHub Advanced Security'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'On — audited'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'ensure_devops_connector'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'record_advanced_security_state'
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" "DEFENDER_CSPM_VM_SCANNING: \${{ vars.DEFENDER_CSPM_VM_SCANNING || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" "DEFENDER_CSPM_API_POSTURE: \${{ vars.DEFENDER_CSPM_API_POSTURE || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" "DEFENDER_CONTAINERS_VM_SCANNING: \${{ vars.DEFENDER_CONTAINERS_VM_SCANNING || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/publish-release.yml" "DEFENDER_CSPM_VM_SCANNING: \${{ vars.DEFENDER_CSPM_VM_SCANNING || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/publish-release.yml" "DEFENDER_CSPM_API_POSTURE: \${{ vars.DEFENDER_CSPM_API_POSTURE || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/publish-release.yml" "DEFENDER_CONTAINERS_VM_SCANNING: \${{ vars.DEFENDER_CONTAINERS_VM_SCANNING || 'true' }}"
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" 'kit-defender-posture.yml@3e261301bb1a70bcd25f3891117c16ebd8065ca5'
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" 'defender-cspm-api-posture:'
file_contains "$REPO_ROOT/.github/workflows/deploy.yml" 'defender-containers-vm-scanning:'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'cspm-monitor-github'
file_contains "$REPO_ROOT/src/app.js" 'defender_monitoring'
file_contains "$REPO_ROOT/src/app.js" 'cspm_serverless_protection'
file_contains "$REPO_ROOT/src/app.js" 'container_registry_vulnerability_assessment'
# ARM renders string(bool) as "True", so the app must not compare case-sensitively.
file_contains "$REPO_ROOT/src/app.js" 'toLowerCase()'
file_contains "$REPO_ROOT/config/deploy.config.json" '"Arm": "Standard"'
file_contains "$REPO_ROOT/src/app.js" 'resource_manager_threat_detection'
file_contains "$REPO_ROOT/infra/main.bicep" 'defenderArmTier'
file_contains "$REPO_ROOT/infra/main.bicep" 'defenderCspmTier'
file_contains "$REPO_ROOT/infra/main.bicep" 'DEFENDER_SERVERLESS_PROTECTION'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Scenario 1 vulnerable map/regex configuration'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Select a region by number or name'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'current_subscription_id="$(az account show --query id -o tsv'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Ninja Paws management wizard'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Subscription read access'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Uninstall            Unavailable'
file_contains "$REPO_ROOT/scripts/manage.sh" 'deploy.sh" wizard'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Uninstall wizard'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Resource group to delete'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Wait for Azure to confirm the resource group is deleted'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--no-wait'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'mask_identifier'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'defender-cloud-scenario-1'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--all-scenarios'
file_contains "$REPO_ROOT/config/deploy.config.json" 'Defender for Cloud - Scenario 1: NGINX CVE Detection and Remediation'
file_contains "$REPO_ROOT/README.md" 'Defender for Cloud - Scenario 1'
file_contains "$REPO_ROOT/README.md" 'real F5 advisory'
file_contains "$REPO_ROOT/README.md" 'Patched-state demonstration'
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
    file_contains "$status_html" 'Executive report'
    file_contains "$status_html" 'window.npReport'
    file_contains "$status_html" "deployment-' + ENV + '.state.js"
    file_contains "$status_html" 'NINJA PAWS'
    file_contains "$status_html" 'Task list'
    file_contains "$status_html" 'Overall lifecycle'
    file_contains "$status_html" 'Current task'
    file_contains "$status_html" 'current-task-fill'
    file_contains "$status_html" 'Live console'
    file_contains "$test_output/dev/deployment-dev.console.html" 'NINJA PAWS DEPLOYMENT CONSOLE'
    file_contains "$test_output/dev/deployment-dev.console.html" 'line'
    file_contains "$status_html" 'Resolved deployment settings'
    file_contains "$test_output/dev/deployment-dev.state.js" 'currentTask'
    file_contains "$status_html" 'deployment-dev.log'
    test ! -e "$REPO_ROOT/deployment-output.json"
    test ! -e "$REPO_ROOT/.azure/deployment-dev.json"
    fake_browser_dir="$test_output/bin"
    browser_calls="$test_output/browser-calls"
    mkdir -p "$fake_browser_dir"
    cat > "$fake_browser_dir/msedge" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BROWSER_CALLS"
SH
    chmod +x "$fake_browser_dir/msedge"
    BROWSER_CALLS="$browser_calls" PATH="$fake_browser_dir:$PATH" DEPLOY_BROWSER=msedge OUTPUT_ROOT="$test_output" bash "$REPO_ROOT/scripts/deploy.sh" plan --environment dev --defaults --image-tag test-open-one >/dev/null
    BROWSER_CALLS="$browser_calls" PATH="$fake_browser_dir:$PATH" DEPLOY_BROWSER=msedge OUTPUT_ROOT="$test_output" bash "$REPO_ROOT/scripts/deploy.sh" plan --environment dev --defaults --image-tag test-open-two >/dev/null
    test "$(wc -l < "$browser_calls" | tr -d ' ')" -eq 1
    file_contains "$test_output/.deployment-dev.browser-opened" 'file://'
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
case "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)" in
    dev|dev/*|feature/*|feat/*|chore/*|fix/*|bugfix/*)
        echo "Checking automatic development branch environment detection..."
        auto_output_dir="$(mktemp -d)"
        auto_output="$(OUTPUT_ROOT="$auto_output_dir" bash "$REPO_ROOT/scripts/deploy.sh" plan --environment auto --defaults --no-open-status 2>&1)"
        rm -rf "$auto_output_dir"
        [[ "$auto_output" == *"Environment: dev"* ]] || {
            echo "ERROR: development branch environment detection did not complete." >&2
            printf '%s\n' "$auto_output" >&2
            exit 1
        }
        ;;
esac
for variable_name in BASE_OS_IMAGE BASE_OS_VERSION NGINX_VERSION NODE_MAJOR_VERSION VULNERABILITY_STATUS PORT NPM_REGISTRY_URL NPM_USE_MIRROR NPM_NETWORK_MODE DEFENDER_ENABLED DEFENDER_SCAN_ENABLED DEFENDER_MANAGE_PLANS DEFENDER_TARGET_CVE DEFENDER_APPSERVICES_TIER DEFENDER_CONTAINERS_TIER DEFENDER_CSPM_TIER DEFENDER_ARM_TIER DEFENDER_MANAGE_EXTENSIONS DEFENDER_CSPM_SERVERLESS_PROTECTION DEFENDER_CSPM_SERVERLESS_CONTAINERS DEFENDER_CSPM_REGISTRY_ASSESSMENT DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT DEFENDER_DEVOPS_CONNECTOR_ENABLED GITHUB_ADVANCED_SECURITY_EXPECTED; do
    file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" "gh variable set $variable_name"
    file_contains "$REPO_ROOT/.github/workflows/deploy.yml" "$variable_name"
done

if [[ "$SKIP_AZURE" == false ]]; then
    command -v "$AZURE_CLI_BIN" >/dev/null 2>&1 || { echo "ERROR: 'az' is required unless --skip-azure is used." >&2; exit 1; }
    echo "Checking Azure CLI Bicep host prerequisites..."
    bicep_version_output="$("$AZURE_CLI_BIN" bicep version 2>&1 || true)"
    if [[ -z "$bicep_version_output" || "$bicep_version_output" == *"ICU"* || "$bicep_version_output" == *"icu"* ]]; then
        echo "ERROR: Azure CLI could not start its Bicep compiler on this host." >&2
        printf '%s\n' "$bicep_version_output" >&2
        echo "Install libicu (or icu-libs) with the host package manager, then rerun scripts/test.sh." >&2
        exit 1
    fi
    echo "Compiling Bicep..."
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    azure_temp_dir="$temp_dir"
    if command -v wslpath >/dev/null 2>&1; then
        azure_temp_dir="$(wslpath -w "$temp_dir")"
    fi
    "$AZURE_CLI_BIN" bicep build --file "$AZURE_REPO_ROOT/infra/main.bicep" --outfile "$azure_temp_dir/main.json" >/dev/null
    "$AZURE_CLI_BIN" bicep build --file "$AZURE_REPO_ROOT/infra/parameters.bicep" --outfile "$azure_temp_dir/parameters.json" >/dev/null
fi

echo "All cross-platform checks passed."
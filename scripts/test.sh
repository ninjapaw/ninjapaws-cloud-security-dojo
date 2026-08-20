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
NODE_COMMAND=""

usage() {
    cat <<'EOF'
Run cross-platform deployment and infrastructure checks.

Usage: scripts/test.sh [--skip-azure]

Options:
  --skip-azure  Skip Azure CLI/Bicep checks when az is unavailable
EOF
}

while (($# > 0)); do
    case "$1" in
        --skip-azure) SKIP_AZURE=true; shift ;;
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
bash -n "$REPO_ROOT/entrypoint.sh"
echo "Checking Node.js runtime syntax..."
"$NODE_COMMAND" --check "$REPO_ROOT/app.js"

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
file_contains "$REPO_ROOT/Dockerfile" 'COPY nginx.conf /etc/nginx/nginx.conf.template'
file_contains "$REPO_ROOT/docker-compose.yml" 'BASE_OS_IMAGE:'
file_contains "$REPO_ROOT/docker-compose.yml" 'BASE_OS_VERSION:'
file_contains "$REPO_ROOT/docker-compose.yml" 'NODE_MAJOR_VERSION:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Base OS:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Node.js Major:'
file_contains "$REPO_ROOT/entrypoint.sh" 'Generating NGINX upstream configuration'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_binary_version'
file_contains "$REPO_ROOT/entrypoint.sh" 'nginx_package_version'
file_contains "$REPO_ROOT/app.js" 'runtime_verification'
file_contains "$REPO_ROOT/app.js" 'advisory_url: ADVISORY_URL'
file_contains "$REPO_ROOT/app.js" 'fixed_version: FIXED_VERSION'
file_contains "$REPO_ROOT/app.js" 'runtimeVerification.vulnerability_detected === true'
file_contains "$REPO_ROOT/entrypoint.sh" 'VULNERABILITY_DETECTED=false'
file_contains "$REPO_ROOT/entrypoint.sh" 'detection_reason'
file_contains "$REPO_ROOT/nginx.conf" '127.0.0.1:__APP_PORT__'
file_contains "$REPO_ROOT/nginx.conf" 'include /etc/nginx/scenario.conf'
file_contains "$REPO_ROOT/entrypoint.sh" 'scenario_config_state'
file_contains "$REPO_ROOT/entrypoint.sh" 'map_regex_enabled'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Scenario 1 vulnerable map/regex configuration'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Select a region by number or name'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'Azure subscriptions available to this account:'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'mask_identifier'
file_contains "$REPO_ROOT/scripts/deploy.sh" 'defender-cloud-scenario-1'
file_contains "$REPO_ROOT/scripts/deploy.sh" '--all-scenarios'
file_contains "$REPO_ROOT/config/deploy.config.json" 'Defender for Cloud - Scenario 1: NGINX CVE Detection and Remediation'
file_contains "$REPO_ROOT/DEMO.md" 'Customer Demo Walkthrough'
file_contains "$REPO_ROOT/DEMO.md" 'real NGINX vulnerability'
file_contains "$REPO_ROOT/DEMO.md" 'Patched-State Demonstration'
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
file_contains "$status_html" 'Live Console'
file_contains "$status_html" 'Live console'
file_contains "$test_output/dev/deployment-dev.console.html" 'NINJA PAWS DEPLOYMENT CONSOLE'
file_contains "$test_output/dev/deployment-dev.console.html" 'line'
file_contains "$status_html" 'Resolved deployment settings'
file_contains "$status_html" 'deployment-dev.log'
test ! -e "$REPO_ROOT/deployment-output.json"
test ! -e "$REPO_ROOT/.azure/deployment-dev.json"
if bash "$REPO_ROOT/scripts/deploy.sh" provision --environment prod --defaults --yes >/dev/null 2>&1; then
    echo "ERROR: dev branch was allowed to target prod." >&2
    exit 1
fi
for variable_name in BASE_OS_IMAGE BASE_OS_VERSION NGINX_VERSION NODE_MAJOR_VERSION VULNERABILITY_STATUS PORT NPM_REGISTRY_URL NPM_USE_MIRROR NPM_NETWORK_MODE DEFENDER_ENABLED DEFENDER_SCAN_ENABLED DEFENDER_MANAGE_PLANS DEFENDER_TARGET_CVE DEFENDER_APPSERVICES_TIER DEFENDER_CONTAINERS_TIER DEFENDER_CSPM_TIER; do
    file_contains "$REPO_ROOT/scripts/setup-azure-github-oidc.sh" "gh variable set $variable_name"
    file_contains "$REPO_ROOT/.github/workflows/deploy.yml" "$variable_name"
done

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
    az bicep build --file "$AZURE_REPO_ROOT/infra/parameters.bicep" --outfile "$azure_temp_dir/parameters.json" >/dev/null
fi

echo "All cross-platform checks passed."
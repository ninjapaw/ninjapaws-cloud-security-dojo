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

echo "Checking branch-aware plan output..."
dev_plan="$(bash "$REPO_ROOT/scripts/deploy.sh" plan --environment dev --defaults --image-tag test-dev)"
prod_plan="$(bash "$REPO_ROOT/scripts/deploy.sh" plan --environment prod --defaults --image-tag test-prod)"
grep -F 'Environment: dev' <<<"$dev_plan" >/dev/null
grep -F 'Resource group: NP-ninjapaws-dojo-Dev-CentralUS' <<<"$dev_plan" >/dev/null
grep -F 'Environment: prod' <<<"$prod_plan" >/dev/null
grep -F 'Resource group: NP-ninjapaws-dojo-CentralUS' <<<"$prod_plan" >/dev/null

echo "Checking ARM JSON..."
"$NODE_COMMAND" -e "for (const file of ['infra/main.json', 'azuredeploy.json']) JSON.parse(require('fs').readFileSync(file, 'utf8'));" -- "$REPO_ROOT"

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
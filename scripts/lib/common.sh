#!/usr/bin/env bash

# Callers set REPO_ROOT before sourcing and CONFIG_FILE before config lookups.

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

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

# Node isn't always on PATH in Git Bash/WSL even when it's installed for Windows.
if command -v node >/dev/null 2>&1; then
    NODE_COMMAND=node
elif command -v node.exe >/dev/null 2>&1; then
    NODE_COMMAND=node.exe
elif [[ -x /mnt/c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/mnt/c/Program Files/nodejs/node.exe'
elif [[ -x /c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/c/Program Files/nodejs/node.exe'
else
    NODE_COMMAND=node
fi

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

# Lists the scenario IDs registered directly under the top-level "scenarios" object,
# in file order, without requiring jq. Mirrors config_lookup's line-based assumptions.
config_scenario_ids() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk '
        BEGIN { depth = 0; in_scenarios = 0; scen_depth = -1 }
        {
            line = $0
            gsub(/\r/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line ~ /^"[^"]+"[ \t]*:[ \t]*\{/) {
                key = line; sub(/^"/, "", key); sub(/".*/, "", key)
                depth++
                if (depth == 1 && key == "scenarios") { in_scenarios = 1; scen_depth = depth }
                else if (in_scenarios && depth == scen_depth + 1) { print key }
                next
            }
            if (line ~ /^\}/) {
                if (in_scenarios && depth == scen_depth) { in_scenarios = 0 }
                if (depth > 0) depth--
                next
            }
        }
    ' "$CONFIG_FILE"
}

html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
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

project_meta() {
    local value
    value="$(config_lookup "project.$1")"
    printf '%s' "${value:-$2}"
}

# Interactive Azure region picker shared by deploy.sh and setup-azure-github-oidc.sh.
# Falls straight back to the default outside a TTY (CI, or non-interactive `--defaults`).
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

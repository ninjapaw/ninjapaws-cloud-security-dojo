#!/usr/bin/env bash

CONFIG_FILE="${CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.json}"

require_config_tools() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required to read $CONFIG_FILE. Install it with: sudo apt-get install -y jq" >&2
        return 1
    fi
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "Configuration file is missing or invalid JSON: $CONFIG_FILE" >&2
        return 1
    fi
}

config_value() {
    local value
    value=$(jq -r "$1" "$CONFIG_FILE") || return 1
    [[ "$value" != null ]] || return 1
    printf '%s\n' "$value"
}

load_deployment_config() {
    require_config_tools || return 1
    CONFIG_RESOURCE_GROUP=$(config_value '.deployment.resourceGroup')
    CONFIG_LOCATION=$(config_value '.deployment.location')
    CONFIG_REGISTRY_NAME=$(config_value '.deployment.containerRegistryName')
    CONFIG_APP_SERVICE_NAME=$(config_value '.deployment.appServiceName')
    CONFIG_APP_SERVICE_PLAN_NAME=$(config_value '.deployment.appServicePlanName')
    CONFIG_KEY_VAULT_NAME=$(config_value '.deployment.keyVaultName')
    CONFIG_IMAGE_NAME=$(config_value '.image.name')
    CONFIG_IMAGE_TAG=$(config_value '.image.tag')
    CONFIG_UBUNTU_VERSION=$(config_value '.image.ubuntuVersion')
    CONFIG_NODE_MAJOR_VERSION=$(config_value '.image.nodeMajorVersion')
    CONFIG_PORT=$(config_value '.runtime.port')
    CONFIG_NGINX_VERSION=$(config_value '.runtime.nginxVersion')
    CONFIG_VULNERABILITY_STATUS=$(config_value '.runtime.vulnerabilityStatus')
    CONFIG_DEFENDER_ENABLED=$(config_value '.runtime.defenderEnabled')
}

github_environment_for_branch() {
    local branch="$1"
    if [[ "$branch" == main ]]; then
        config_value '.github.environments.main'
    else
        config_value '.github.environments.default'
    fi
}
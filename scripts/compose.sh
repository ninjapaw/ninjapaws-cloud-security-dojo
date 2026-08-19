#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config.sh"
load_deployment_config

export UBUNTU_VERSION="$CONFIG_UBUNTU_VERSION"
export NODE_MAJOR_VERSION="$CONFIG_NODE_MAJOR_VERSION"
export NGINX_VERSION="$CONFIG_NGINX_VERSION"
export VULNERABILITY_STATUS="$CONFIG_VULNERABILITY_STATUS"
export PORT="$CONFIG_PORT"
export DEFENDER_ENABLED="$CONFIG_DEFENDER_ENABLED"

exec docker compose "$@"
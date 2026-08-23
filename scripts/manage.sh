#!/usr/bin/env bash

# Backward-compatible management entry point for the full Azure lifecycle.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (($# == 0)); then
    exec "$SCRIPT_DIR/deploy.sh" wizard
fi

if [[ "$1" == -* ]]; then
    exec "$SCRIPT_DIR/deploy.sh" wizard "$@"
fi

exec "$SCRIPT_DIR/deploy.sh" "$@"
#!/usr/bin/env bash
set -euo pipefail

npm ci

# Playwright browsers are not part of the base image.
npx playwright install --with-deps chromium

chmod +x scripts/*.sh entrypoint.sh 2>/dev/null || true

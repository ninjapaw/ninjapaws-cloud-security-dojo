#!/usr/bin/env bash
set -e

echo "🥷 Ninja Paws Cloud Security Dojo - Starting"
echo "🛡 NGINX Version: ${NGINX_VERSION:?NGINX_VERSION must be set}"
echo "⚔ CVE-2026-42533: HTTP/2 CONTINUATION Frames Memory Corruption"

nginx -g "daemon off;" &
NGINX_PID=$!

sleep 2

node src/app.js &
NODE_PID=$!

trap 'kill "$NGINX_PID" "$NODE_PID" 2>/dev/null' EXIT
wait -n "$NGINX_PID" "$NODE_PID"
exit $?
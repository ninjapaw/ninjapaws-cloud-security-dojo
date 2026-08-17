#!/bin/bash
set -e

echo "🥷 Ninja Paws Cloud Security Dojo - Starting"
echo "🛡 NGINX Version: ${NGINX_VERSION:-1.30.3}"
echo "⚔ CVE-2026-42533: HTTP/2 CONTINUATION Frames Memory Corruption"

# Start NGINX in the background
echo "Starting NGINX..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Give NGINX time to start
sleep 2

# Start Node.js application in the background so we can supervise both processes
echo "Starting Node.js application..."
node app.js &
NODE_PID=$!

# If either process dies, stop the other and exit with its status
trap 'kill "$NGINX_PID" "$NODE_PID" 2>/dev/null' EXIT
wait -n "$NGINX_PID" "$NODE_PID"
exit $?

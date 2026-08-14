#!/bin/bash
set -e

echo "🥷 Ninja Paws Cloud Security Dojo - Starting"
echo "🛡 NGINX Version: 1.30.3 (Intentionally Vulnerable for Training)"
echo "⚔ CVE-2026-42533: HTTP/2 CONTINUATION Frames Memory Corruption"

# Start NGINX in the background
echo "Starting NGINX..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Give NGINX time to start
sleep 2

# Start Node.js application
echo "Starting Node.js application..."
exec node app.js

# If Node.js exits, stop NGINX
trap "kill $NGINX_PID" EXIT

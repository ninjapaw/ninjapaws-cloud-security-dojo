#!/usr/bin/env bash
set -Eeuo pipefail

echo "🥷 Ninja Paws Cloud Security Dojo - Starting"
echo "🧱 Base OS: ${BASE_OS_IMAGE:-ubuntu}:${BASE_OS_VERSION:-24.04}"
echo "🛡 NGINX Version: ${NGINX_VERSION:-1.30.3}"
echo "🟢 Node.js Major: ${NODE_MAJOR_VERSION:-20}"
echo "🔌 Application Port: ${PORT:-3000}"
echo "🎓 Vulnerability Status: ${VULNERABILITY_STATUS:-vulnerable}"
echo "📊 Defender Monitoring: ${DEFENDER_ENABLED:-false}"
echo "⚔ CVE-2026-42533: HTTP/2 CONTINUATION Frames Memory Corruption"

APP_PORT="${PORT:-3000}"
case "$APP_PORT" in
	''|*[!0-9]*)
		echo "Invalid PORT: $APP_PORT" >&2
		exit 1
		;;
esac
if [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
	echo "Invalid PORT: $APP_PORT" >&2
	exit 1
fi

echo "Generating NGINX upstream configuration for port $APP_PORT..."
sed "s/__APP_PORT__/$APP_PORT/g" \
	/etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t -c /etc/nginx/nginx.conf

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

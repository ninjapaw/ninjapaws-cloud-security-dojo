#!/usr/bin/env bash
set -Eeuo pipefail

echo "🥷 Ninja Paws Cloud Security Dojo - Starting"
echo "🧱 Base OS: ${BASE_OS_IMAGE:-ubuntu}:${BASE_OS_VERSION:-24.04}"
echo "🛡 NGINX Version: ${NGINX_VERSION:-1.30.3}"
echo "🟢 Node.js Major: ${NODE_MAJOR_VERSION:-20}"
echo "🔌 Application Port: ${PORT:-3000}"
echo "🎓 Scenario intent: ${VULNERABILITY_STATUS:-vulnerable}"
echo "📊 Defender Monitoring: ${DEFENDER_ENABLED:-false}"
echo "⚔ CVE-2026-42533: NGINX map directive and regex matching heap buffer overflow"
echo "📚 F5 advisory: https://my.f5.com/manage/s/article/K000162097"

echo "===== CVE REPRO ====="
echo "Target CVE: CVE-2026-42533"
echo "NGINX Version:"
cat /opt/nginx-version.txt
echo "Installed Package:"
cat /opt/nginx-package-version.txt
echo "===================="

NGINX_BINARY_VERSION="$(nginx -v 2>&1 | sed -n 's|nginx version: nginx/||p')"
NGINX_PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || true)"
SCENARIO_CONFIG_STATE="remediated"
if [ "${VULNERABILITY_STATUS:-vulnerable}" = "vulnerable" ]; then
	SCENARIO_CONFIG_STATE="affected"
	cat > /etc/nginx/scenario.conf <<'NGINX_SCENARIO'
# Defender for Cloud - Scenario 1: affected map/regex configuration.
# This is intentionally enabled only for the vulnerable demo image.
map $http_x_ninja_probe $ninja_map_output {
    ~^(?<ninja_capture>.*)$ $ninja_capture;
    default "";
}
NGINX_SCENARIO
else
	printf '%s\n' '# Defender for Cloud - Scenario 1: remediated; affected map configuration removed.' > /etc/nginx/scenario.conf
fi
echo "🔎 NGINX binary: ${NGINX_BINARY_VERSION:-unknown}"
echo "📦 NGINX package: ${NGINX_PACKAGE_VERSION:-unknown}"

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

MAP_REGEX_ENABLED=false
if grep -Eq '^[[:space:]]*map[[:space:]]+.*\$.*\$' /etc/nginx/scenario.conf \
  && grep -Eq '^[[:space:]]*~\^\(' /etc/nginx/scenario.conf; then
	MAP_REGEX_ENABLED=true
fi
VULNERABILITY_DETECTED=false
DETECTION_REASON="NGINX version or affected map/regex configuration did not match the F5 advisory conditions."
case "$NGINX_BINARY_VERSION" in
	1.30.0|1.30.1|1.30.2|1.30.3|1.31.2)
		if [ "$MAP_REGEX_ENABLED" = true ]; then
			VULNERABILITY_DETECTED=true
			DETECTION_REASON="Detected affected NGINX version $NGINX_BINARY_VERSION with map directive regex matching enabled."
		fi
		;;
	*)
		DETECTION_REASON="NGINX binary version ${NGINX_BINARY_VERSION:-unknown} is not in the F5 affected-version list, or the affected map/regex configuration is absent."
		;;
esac
printf '{"nginx_binary_version":"%s","nginx_package_version":"%s","scenario_config_state":"%s","map_regex_enabled":%s,"vulnerability_detected":%s,"detection_reason":"%s"}\n' \
	"$NGINX_BINARY_VERSION" "$NGINX_PACKAGE_VERSION" "$SCENARIO_CONFIG_STATE" "$MAP_REGEX_ENABLED" "$VULNERABILITY_DETECTED" "$DETECTION_REASON" \
	> /run/ninja-paws-runtime.json
echo "🧭 CVE detection: $([ "$VULNERABILITY_DETECTED" = true ] && printf Vulnerable || printf NotDetected)"

# Start NGINX in the background
echo "Starting NGINX..."
nginx -g "daemon off;" &
NGINX_PID=$!

# Give NGINX time to start
sleep 2

# Start Node.js application in the background so we can supervise both processes
echo "Starting Node.js application..."
node src/app.js &
NODE_PID=$!

# If either process dies, stop the other and exit with its status
trap 'kill "$NGINX_PID" "$NODE_PID" 2>/dev/null' EXIT
wait -n "$NGINX_PID" "$NODE_PID"
exit $?

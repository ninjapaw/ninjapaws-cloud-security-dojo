#!/usr/bin/env bash
set -Eeuo pipefail

target_cve="CVE-2026-42533"
expected_version="1.30.3"

echo "Target CVE: $target_cve"
echo "nginx -v:"
nginx_version_output="$(nginx -v 2>&1)"
echo "$nginx_version_output"
echo "dpkg-query -W nginx:"
dpkg-query -W nginx
echo "dpkg -l | grep nginx:"
dpkg -l | grep nginx

installed_version="${nginx_version_output##*/}"
if [[ "$installed_version" != "$expected_version" ]]; then
    echo "ERROR: expected NGINX $expected_version, found ${installed_version:-unknown}." >&2
    exit 1
fi
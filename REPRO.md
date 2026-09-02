# Objective

Demonstrate Defender Inventory detects nginx 1.30.3 but may not associate CVE-2026-42533.

NGINX 1.30.3 is installed from the official NGINX package repository and preserved as build-time command output under `/opt`. The F5 advisory for CVE-2026-42533 identifies NGINX Open Source 1.30.0 through 1.30.3 as affected: <https://my.f5.com/manage/s/article/K000162097>.

# Validation Steps

1. Build image.
2. Run container.
3. Call `/evidence` endpoint.
4. Capture output from `verify.sh`.
5. Push image to ACR.
6. Wait for Defender inventory.
7. Verify nginx 1.30.3 appears in software inventory.
8. Verify vulnerabilities tab results.

# Expected Result

Defender inventory identifies nginx 1.30.3.

# Actual Result

Document findings during testing.

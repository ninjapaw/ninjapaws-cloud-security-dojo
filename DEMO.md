# Defender for Cloud - Scenario 1

## NGINX CVE Detection and Remediation

This walkthrough demonstrates a controlled cloud-security story:

1. Deploy an intentionally vulnerable training image.
2. Prove what is running through the live application and container provenance checks.
3. Prove the affected NGINX `map`/regex configuration is active in the vulnerable image.
4. Review Defender for Cloud plan coverage and assessment results.
5. Redeploy a patched training state.
6. Prove the affected configuration is removed and the fixed package is running.
7. Compare the before/after evidence and explain what Defender can and cannot prove.

## Safety And Truth In Demonstration

- Use an isolated Azure subscription and the `dev` environment.
- This repository is intentionally vulnerable and is provided as-is. Do not expose it to production users or sensitive data.
- `CVE-2026-42533` is a real NGINX vulnerability documented by F5 in [K000162097](https://my.f5.com/manage/s/article/K000162097). The default NGINX `1.30.3` image is intentionally in the affected range; NGINX `1.30.4` is the fixed version listed by the advisory.
- Defender for App Service can detect attacks against App Service traffic and platform surfaces. Defender for Containers can assess Azure Container Registry images for known CVEs. Neither plan turns this App Service deployment into an AKS workload.
- Defender findings are asynchronous. A missing finding is not proof that an image is clean until the assessment has completed.

## Prerequisites

- Azure CLI installed and authenticated with permission to read the subscription and manage the target resource group.
- A Git checkout on the `dev` branch.
- Defender plan activation permission (`Microsoft.Security/pricings/*`) if `defender.managePlans` is enabled.
- Agreement to possible Defender for Cloud charges. Plan tiers are subscription-scoped.

## 1. Baseline Deployment

From the repository root:

```bash
bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Open the `deployment-dev.html` report. Walk through these sections in order:

1. **Task list**: confirm the deployment and post-verification Defender task are visible.
2. **Verification matrix**: confirm the image digest, managed identity, endpoints, and NGINX provenance checks.
3. **Environment access**: open the live application, App Service Metrics, App Service diagnostics, and Defender for Cloud Recommendations.
4. **Audit trail**: capture the run ID, commit, operator, subscription, and timestamps.

The live application should expose:

```text
https://ninjapaws-dojo-app-dev.azurewebsites.net/
https://ninjapaws-dojo-app-dev.azurewebsites.net/api/status
https://ninjapaws-dojo-app-dev.azurewebsites.net/health
```

The CVE-relevant `map` is an internal NGINX directive in the rendered scenario configuration. Inspect `runtime_verification.map_regex_enabled` and `runtime_verification.scenario_config_state` in `/api/status`.

The status payload should show:

- `vulnerability.detected`: `true`
- `vulnerability.status`: `vulnerable` (derived from detection evidence)
- `vulnerability.advisory_url`: the F5 security advisory
- `vulnerability.affected_versions`: `NGINX Open Source 1.30.0-1.30.3`
- `vulnerability.fixed_version`: `1.30.4`
- `runtime_verification.nginx_binary_version`: the actual NGINX binary version
- `runtime_verification.nginx_package_version`: the installed Debian package version
- `runtime_verification.scenario_config_state`: `affected`
- `runtime_verification.map_regex_enabled`: `true`

The authoritative detection result is `vulnerability.detected`. It is `true` only when the actual NGINX binary version is in the F5 affected list and the rendered NGINX configuration contains the affected `map` directive with regex matching. `vulnerability.status` is derived from that result; `VULNERABILITY_STATUS` selects the demo image configuration but is not itself a detection result.

## 2. Explain Defender Coverage

The final report's Defender task records:

- **Defender for App Service**: expected `Standard` coverage for App Service attack detection.
- **Defender for Containers**: expected `Standard` coverage for Azure Container Registry image vulnerability assessment.
- **Defender CSPM**: expected `Free` foundational posture visibility.
- **Kubernetes runtime**: Not applicable because this demo deploys to App Service, not AKS.
- **Servers, SQL, Storage, Key Vault, DNS, and Resource Manager plans**: Not activated because those workloads are not deployed by this project.

Open **Defender for Cloud > Recommendations**, filter by the resource group and image, and explain that the assessment inventory may take several minutes to populate. The report records the target CVE as **Pass** only when it appears in the returned assessment payload; otherwise it records **Not sure** with the reason.

## 3. Patched-State Demonstration

The patched state changes the training signal and rebuilds the image with a new content fingerprint:

```bash
NGINX_VERSION=1.30.4 VULNERABILITY_STATUS=patched \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Then verify:

1. `/api/status` reports `vulnerability.detected` as `false` and `vulnerability.status` as `not_detected`.
2. `runtime_verification` still proves the actual NGINX binary and package.
3. `runtime_verification.scenario_config_state` is `remediated` and `map_regex_enabled` is `false`.
4. The new report has a different build fingerprint or a clearly recorded image reuse decision.
5. Defender Recommendations are rechecked after the new image assessment completes.
6. Explain that package and configuration evidence support the remediation claim, while the Defender finding must still be reviewed independently after its asynchronous rescan.

Return to the vulnerable lab state when the customer demo is over:

```bash
NGINX_VERSION=1.30.3 VULNERABILITY_STATUS=vulnerable \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

## 4. Evidence To Capture

For an audit-friendly demo, retain:

- `output/dev/deployment-dev.html`
- `output/dev/deployment-dev.json`
- `output/dev/deployment-dev.log`
- `output/dev/deployment-dev.console.html`
- The Defender Recommendations view or export showing the assessment state and timestamp
- The run ID and commit from the report's Audit trail

Do not present a **Not sure** result as a clean bill of health. It means Defender's asynchronous assessment evidence was not conclusive at the time of the run.

## 5. Cleanup

When the demo is complete, remove the isolated environment only after confirming the target resource group:

```bash
bash scripts/deploy.sh uninstall --environment dev --yes --wait
```

The lifecycle does not automatically deactivate subscription-wide Defender plans. Review and manage those plans explicitly in Defender for Cloud if the subscription is no longer used for this demo.

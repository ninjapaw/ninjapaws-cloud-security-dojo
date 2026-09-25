# Ninja Paws Cloud Security Dojo

> **Independent community project.** This repository is not a Microsoft product,
> assessment, endorsement, or official security guidance. Some contributors may be
> Microsoft employees acting in an individual or community capacity. Use at your
> own risk and validate all demo behavior before using it in any environment. See
> [DISCLAIMER.md](DISCLAIMER.md).

A defensive cloud-security training environment demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

Use only an isolated, authorized training environment. This repository intentionally includes vulnerable software and privileged SQL operations. Azure resources and Defender/Sentinel plans can incur charges. Never use real customer data or expose the lab to untrusted users.

## Contents

- [Quick start](#quick-start)
- [NGINX scenario](#defender-for-cloud---scenario-1)
- [Demo walkthrough](#demo-walkthrough)
- [Configuration](#configuration)
- [Azure deployment](#azure-deployment)
- [Validation and workflows](#workflows)
- [Contributing](CONTRIBUTING.md), [security reporting](SECURITY.md), and [disclaimer](DISCLAIMER.md)

## Defender for Cloud - Scenario 1

**NGINX CVE Detection and Remediation** is the default scenario. It deploys the intentionally affected NGINX `1.30.3` workload and advisory-relevant `map`/regex configuration to Azure App Service with Azure Container Registry, Defender for App Service, Defender for Containers, and Defender CSPM coverage. The demo proves the running package and configuration, reviews Defender findings, then swaps to fixed NGINX `1.30.4` with the affected configuration removed.

Scenarios are registered in `config/deploy.config.json`. Select this scenario with `--scenario defender-cloud-scenario-1`.

### Reproduction and evidence

The reproduction tests whether Defender inventory identifies NGINX `1.30.3` and separately whether it associates [CVE-2026-42533](https://my.f5.com/manage/s/article/K000162097). An inventory entry alone is not proof of a vulnerability finding.

1. Build and run the training container using the [demo walkthrough](#demo-walkthrough).
2. Capture `/evidence` and the output of `scripts/verify.sh`. Build-time package evidence is preserved under `/opt` in the image.
3. Deploy the image to ACR and allow Defender assessment to complete.
4. Check the software inventory for NGINX `1.30.3`, then inspect the vulnerability findings separately.
5. Record the image digest, assessment time, inventory version, and whether the CVE was reported. Repeat after remediation.

Expected inventory: NGINX `1.30.3`. Actual findings depend on the assessment and must be recorded during your run; this repository does not claim a guaranteed Defender alert or CVE association.

## Defender for Cloud - Scenario 2

SQL Server on Azure VM Protection (Defender for Servers Plan 2, Defender for SQL, and Microsoft Sentinel protecting SQL Server 2022 on an Azure VM, with the live Pawton Manufacturing dashboard) has moved to its own dedicated repository: [ninjapaw/pawton](https://github.com/ninjapaw/pawton). It is a separate Azure architecture and resource group from Scenario 1 (App Service + ACR), so it now lives in a self-contained repo with its own deploy wizard, Deploy to Azure button, and Sentinel content lifecycle.

## Quick Start

Prerequisites: Git, Node.js 24 (use the version in `.node-version` and npm version in `package.json`), Docker/Docker Compose, and Bash. Azure deployment additionally requires Azure CLI; GitHub OIDC bootstrap requires GitHub CLI.

```bash
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo
npm ci
npm test
npm start
```

The direct application listens on `http://localhost:3000`.

Common commands are exposed through `package.json` so the same entry points work from PowerShell, Git Bash, WSL, Linux, and CI hosts that have Bash available:

```bash
npm run dojo
npm run test:repo
npm run deploy:plan
npm run deploy:doctor
npm run deploy:dev
```

### Repository layout

| Path                                        | Contents                                                       |
| ------------------------------------------- | -------------------------------------------------------------- |
| `src/`                                      | Scenario 1 dashboard and runtime evidence API                  |
| `config/deploy.config.json`                 | Scenario and environment configuration                         |
| `scripts/`                                  | Local lifecycle commands, SQL bootstrap, and validation        |
| `infra/`                                    | Bicep templates, generated ARM templates, and Sentinel content |
| `Dockerfile`, `entrypoint.sh`, `nginx.conf` | Scenario 1 container build and runtime                         |

### Endpoint surface

| Route         | Purpose                                                                   | Exposure                                                         |
| ------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `/`           | Human-readable training dashboard                                         | Public application route                                         |
| `/health`     | Lightweight JSON health probe                                             | Public application route; used by App Service and rollout checks |
| `/api/status` | JSON CVE metadata, package/config evidence, image host, and runtime state | Public evidence route for the demo                               |

`/api/status` reports two different classes of truth, and the payload keeps them separate on purpose. `runtime_verification` is proven inside the container by reading the actual NGINX binary, Debian package, and rendered configuration. `defender_monitoring` reports the Defender coverage the deployment **requested**, because the container holds no Azure credentials and cannot query subscription plan state. Each monitoring flag is a plain `true`/`false`, and the block names Defender for Cloud as the authoritative source:

```json
{
  "defender_monitoring": {
    "source": "deployment-configuration",
    "plans": {
      "defender_for_app_service": "Standard",
      "defender_for_containers": "Standard",
      "defender_cspm": "Standard",
      "defender_for_resource_manager": "Standard"
    },
    "monitoring": {
      "app_service_threat_protection": true,
      "resource_manager_threat_detection": true,
      "container_registry_vulnerability_assessment": true,
      "cspm_serverless_protection": true,
      "cspm_serverless_containers": true,
      "devops_connector_requested": true,
      "github_advanced_security_expected": true
    }
  }
}
```

The deployment report's verification matrix is where those requests are checked against Azure, so a flag reading `true` here means "configured", while the matrix says whether Azure agrees.

`map` is an internal NGINX configuration directive rendered by `entrypoint.sh` into `/etc/nginx/scenario.conf`. In the affected image it combines regex matching and captures; the detector reports this as `runtime_verification.map_regex_enabled: true`. Inspect that evidence through `/api/status`.

Use the application URL printed by your deployment report. The repository does not provide a supported public hosted service.

Run the containerized stack:

```bash
docker compose up --build -d
curl http://localhost:8080/health
docker compose logs -f dojo
docker compose down
```

## Demo Walkthrough

This walkthrough demonstrates a controlled cloud-security story: deploy an intentionally vulnerable image, prove what is running, review Defender coverage, redeploy a patched state, then compare evidence before cleanup.

Use an isolated Azure subscription and the `dev` environment. The default NGINX `1.30.3` image is intentionally in the affected range for the real F5 advisory; do not expose it to production users or sensitive data. Defender findings are asynchronous, so a missing finding is not proof that an image is clean until assessment processing has completed.

Prerequisites for the Azure walkthrough:

- Azure CLI installed and authenticated with permission to read the subscription and manage the target resource group
- A Git checkout on the `dev` branch
- Defender plan activation permission (`Microsoft.Security/pricings/*`) at subscription scope when `defender.managePlans` is enabled. The OIDC setup script grants the built-in `Security Admin` role for this purpose.
- Agreement to possible Defender for Cloud charges, because plan tiers are subscription-scoped

Baseline deployment:

```bash
bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Open `output/dev/deployment-dev.html` and review the task list, verification matrix, environment access links, and audit trail. Use the report's application URL to inspect `/`, `/api/status`, and `/health`.

In `/api/status`, treat `runtime_verification` and `defender_monitoring` differently. Runtime evidence is proven inside the container; Defender monitoring reports what the deployment requested, while the deployment report compares those requests against Azure. The vulnerable baseline should show `vulnerability.detected: true`, `vulnerability.status: vulnerable`, `runtime_verification.scenario_config_state: affected`, and `runtime_verification.map_regex_enabled: true`.

For Defender coverage, use the final report and Defender for Cloud Recommendations together. The report should record expected `Standard` coverage for App Service, Containers, CSPM, and Resource Manager, while Kubernetes runtime and unrelated resource plans are marked not applicable. A target CVE result of **Not sure** means Defender assessment evidence was not conclusive yet; do not present it as clean.

Patched-state demonstration:

```bash
NGINX_VERSION=1.30.4 VULNERABILITY_STATUS=patched \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Then verify that `/api/status` reports `vulnerability.detected: false`, `vulnerability.status: not_detected`, `runtime_verification.scenario_config_state: remediated`, and `runtime_verification.map_regex_enabled: false`. The new report should show a changed build fingerprint or a clearly recorded image reuse decision. Defender Recommendations still need independent review after the asynchronous rescan.

Return to the vulnerable lab state when the demo is over:

```bash
NGINX_VERSION=1.30.3 VULNERABILITY_STATUS=vulnerable \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Evidence to retain for an audit-friendly demo:

- `output/dev/deployment-dev.html`
- `output/dev/deployment-dev.json`
- `output/dev/deployment-dev.log`
- `output/dev/deployment-dev.console.html`
- The Defender Recommendations view or export showing assessment state and timestamp
- The run ID and commit from the report's audit trail
- The audit-trail item **Registry image security findings: On — audited**, backed by the live `ContainerRegistriesVulnerabilityAssessments` state

Cleanup:

```bash
bash scripts/deploy.sh uninstall --environment dev --yes
```

The lifecycle does not automatically deactivate subscription-wide Defender plans. Review and manage those plans explicitly in Defender for Cloud if the subscription is no longer used for this demo.

## Configuration

All Docker build arguments are non-secret configuration. Defaults are safe fallbacks; GitHub Environment variables are the source of truth for `dev` and `prod` deployments.

Branch isolation is explicit: `dev` deploys to `NP-ninjapaws-dojo-Dev-CentralUS`, ACR `ninjapawsdojodev`, and App Service `ninjapaws-dojo-app-dev`; `main` deploys to `NP-ninjapaws-dojo-Prod-CentralUS`, ACR `ninjapawsdojoprod`, and App Service `ninjapaws-dojo-app-prod`.

| Variable               |                      Default | Purpose                                                                                                     |
| ---------------------- | ---------------------------: | ----------------------------------------------------------------------------------------------------------- |
| `BASE_OS_IMAGE`        |                     `ubuntu` | Base OS image repository                                                                                    |
| `BASE_OS_VERSION`      |                      `24.04` | Ubuntu image version                                                                                        |
| `NGINX_VERSION`        |                     `1.30.3` | Pinned NGINX package                                                                                        |
| `NODE_MAJOR_VERSION`   |                         `24` | NodeSource major version                                                                                    |
| `VULNERABILITY_STATUS` |                 `vulnerable` | Scenario configuration intent; the app derives the authoritative vulnerability result from runtime evidence |
| `PORT`                 |                       `3000` | Internal Node.js port behind NGINX                                                                          |
| `WEBSITES_PORT`        |                         `80` | Port exposed by the container to Azure App Service                                                          |
| `NPM_REGISTRY_URL`     | `https://registry.npmjs.org` | npm registry or approved enterprise mirror used during the image build                                      |
| `NPM_USE_MIRROR`       |                       `true` | Use `NPM_REGISTRY_URL` when true; use npm's direct default when false                                       |
| `NPM_NETWORK_MODE`     |                     `online` | `online` downloads dependencies; `offline` disables npm network access and requires a populated npm cache   |
| `DEFENDER_ENABLED`     |                       `true` | Training dashboard flag; this is separate from Defender for Cloud subscription plans                        |

Defender for Cloud settings live under the `defender` object in `config/deploy.config.json`. The checked-in defaults are intentionally suited to this vulnerable App Service container scenario:

| Setting                       | Default          | Purpose                                                                                                 |
| ----------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------- |
| `defender.scanAfterVerify`    | `true`           | Adds a post-verification Defender scan task to `deploy`, `rollout`, `repair`, and `verify`              |
| `defender.managePlans`        | `true`           | Allows the lifecycle to activate the configured Microsoft Security pricing tiers                        |
| `defender.targetCve`          | `CVE-2026-42533` | Real CVE from the F5 NGINX advisory searched for in the latest Defender assessment payload              |
| `defender.plans.AppServices`  | `Standard`       | Defender for App Service attack detection for the App Service workload                                  |
| `defender.plans.Containers`   | `Standard`       | Defender for Containers vulnerability assessment for Azure Container Registry images                    |
| `defender.plans.CloudPosture` | `Standard`       | Defender CSPM: attack paths, cloud security explorer, and the serverless/registry extensions below      |
| `defender.plans.Arm`          | `Standard`       | Defender for Resource Manager: threat detection on the control-plane operations this lifecycle performs |
| `defender.manageExtensions`   | `true`           | Allows the lifecycle to apply the plan extension sets below                                             |

Defender for Resource Manager is enabled because this project is unusually control-plane heavy: it creates and deletes resource groups, assigns RBAC roles, changes subscription-scoped Defender pricing, creates security connectors, and drives ACR builds — all through ARM. The GitHub OIDC identity it uses holds `Contributor` and `Role Based Access Control Administrator`, which is exactly the kind of identity an attacker would target for privilege escalation. This plan detects suspicious ARM operations, exploitation toolkits such as MicroBurst and PowerZure, and anomalous use of that automation. It bills at a flat subscription rate rather than per resource.

`CloudPosture` defaults to `Standard` rather than `Free` because the capabilities this scenario demonstrates — attack path analysis, serverless posture, and registry access for container image posture — are Defender CSPM features. Foundational CSPM (`Free`) provides recommendations and secure score only.

Defender CSPM extensions are applied as one set, because the API replaces the whole collection on every write:

| CSPM extension                                | Default | Why                                                                                                                                      |
| --------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentlessServerlessPosture`                  | `true`  | Serverless protection covers App Service and Functions, which is exactly the workload this project deploys                               |
| `ServerlessContainers`                        | `true`  | Serverless container posture for Container Apps, Container Instances, and ECS on Fargate; also supplies registry-aware container context |
| `ContainerRegistriesVulnerabilityAssessments` | `true`  | Registry access, required for full serverless container and image posture                                                                |
| `AgentlessDiscoveryForKubernetes`             | `false` | No AKS or Kubernetes workload is deployed                                                                                                |
| `AgentlessVmScanning`                         | `false` | Scenario 1 deploys no virtual machines                                                                                                   |
| `SensitiveDataDiscovery`                      | `false` | Scenario 1 stores no application data; discovery stays opt-in                                                                            |
| `EntraPermissionsManagement`                  | `false` | CIEM has tenant-wide scope beyond this scenario                                                                                          |
| `ApiPosture`                                  | `false` | Preview capability is outside the required App Service and ACR scenario                                                                  |

Defender for Containers extensions follow the same pattern:

| Containers extension                          | Default | Why                                                                           |
| --------------------------------------------- | ------- | ----------------------------------------------------------------------------- |
| `ContainerRegistriesVulnerabilityAssessments` | `true`  | On; generates and links findings artifacts for every new or updated ACR image |
| `AgentlessDiscoveryForKubernetes`             | `false` | Not applicable to App Service                                                 |
| `AgentlessVmScanning`                         | `false` | Scenario 1 deploys no virtual machines                                        |
| `ContainerSensor`                             | `false` | The runtime threat sensor is an AKS component                                 |

DevOps and code security settings:

| Setting                                    | Default            | Purpose                                                                      |
| ------------------------------------------ | ------------------ | ---------------------------------------------------------------------------- |
| `defender.devops.connectorEnabled`         | `true`             | Creates the Defender for Cloud GitHub connector if the subscription has none |
| `defender.devops.connectorName`            | `ninjapaws-github` | Name of the `Microsoft.Security/securityConnectors` resource                 |
| `defender.devops.githubOwner`              | `ninjapaw`         | GitHub organization reported in the connector guidance                       |
| `defender.devops.advancedSecurityExpected` | `true`             | Reports GitHub Advanced Security state in the verification matrix            |

The lifecycle creates the GitHub connector resource, but **it cannot finish onboarding non-interactively**. Authorizing the connector and installing the DevOps security GitHub application is an interactive consent flow, so the report records the connector as **Not sure** with the remaining manual step rather than claiming coverage it has not proven. Complete it under **Defender for Cloud > Environment settings > Add environment > GitHub**, following [Connect your GitHub environment](https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-github). Once authorized, DevOps resources can take up to 8 hours to appear.

GitHub Advanced Security is a GitHub product, not an Azure plan, so the lifecycle reports it rather than enabling it. Code scanning already runs in this repository through the checked-in CodeQL workflow, which is free for public repositories. When a GitHub connector is authorized, Defender for Cloud maps GHAS findings to the running workload and prioritizes them with runtime risk factors such as internet exposure. Private repositories require a GitHub Advanced Security licence.

These settings are configurable per environment and can also be overridden with `DEFENDER_SCAN_ENABLED`, `DEFENDER_MANAGE_PLANS`, `DEFENDER_MANAGE_EXTENSIONS`, `DEFENDER_TARGET_CVE`, `DEFENDER_APPSERVICES_TIER`, `DEFENDER_CONTAINERS_TIER`, `DEFENDER_CSPM_TIER`, `DEFENDER_CSPM_SERVERLESS_PROTECTION`, `DEFENDER_CSPM_SERVERLESS_CONTAINERS`, `DEFENDER_CSPM_REGISTRY_ASSESSMENT`, `DEFENDER_CSPM_KUBERNETES_DISCOVERY`, `DEFENDER_CSPM_VM_SCANNING`, `DEFENDER_CSPM_SENSITIVE_DATA`, `DEFENDER_CSPM_PERMISSIONS_MANAGEMENT`, `DEFENDER_CSPM_API_POSTURE`, `DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT`, `DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY`, `DEFENDER_CONTAINERS_VM_SCANNING`, `DEFENDER_CONTAINERS_SENSOR`, `DEFENDER_DEVOPS_CONNECTOR_ENABLED`, `DEFENDER_DEVOPS_CONNECTOR_NAME`, `DEFENDER_DEVOPS_GITHUB_OWNER`, and the GitHub Environment variable `ADVANCED_SECURITY_EXPECTED`. Set a plan tier to `disabled` to mark that workload as **Not applicable** without changing the subscription plan. Plan activation can incur Azure charges; review subscription pricing and permissions before enabling `defender.managePlans` in a shared or production subscription.

The lifecycle does **not** automatically deactivate an already-enabled Defender plan when a workload is set to `disabled`; pricing plans apply at subscription scope, so silently turning off protection from an application deployment would be unsafe. The report instead records unrequested plans as **Not applicable** and leaves subscription-wide deactivation to an explicit Defender for Cloud administrator action.

`entrypoint.sh` generates NGINX from `nginx.conf` at startup, replacing `__APP_PORT__` with `PORT`. This is a deliberate dual-port design: **WEBSITES_PORT=80** tells Azure App Service which container port accepts traffic, while **PORT=3000** is the Node.js upstream behind NGINX. Changing `PORT` changes the NGINX upstream automatically; changing `WEBSITES_PORT` requires changing the container listener and App Service configuration together. Startup also records the actual NGINX binary and Debian package versions, which `/api/status` exposes under `runtime_verification` and the deployment report verifies.

Never put credentials in these variables. Runtime secrets belong in Azure Key Vault with managed identity. GitHub Environment secrets are reserved for values GitHub itself must keep confidential when OIDC or Key Vault cannot provide them.

### Secrets

This scenario provisions no Key Vault: App Service pulls from ACR using managed identity, GitHub Actions uses OIDC, and the container has no database or API credentials. Its settings contain only non-secret configuration. The SQL Server on Azure VM scenario, which does provision Key Vault for SQL and administrator credentials, now lives in the separate [`ninjapaw/pawton`](https://github.com/ninjapaw/pawton) repository.

### Defender endpoint blocks during npm builds

On Windows hosts managed by Microsoft Defender Exploit Guard, the Docker build may be blocked before npm can download dependencies. The relevant host event is Windows Defender Operational Event `1126`, typically showing:

```text
Destination: https://registry.npmjs.org
Process Name: com.docker.backend.exe
```

That is a network-policy block on Docker Desktop, not a malicious npm path and not a reason to skip dependency installation. The preferred resolution is for the endpoint administrator to allow the approved registry, or to point `NPM_REGISTRY_URL` at the organization’s approved npm mirror/cache:

```powershell
$env:NPM_REGISTRY_URL = 'https://npm-mirror.contoso.example/repository/npm-group/'
docker build --build-arg NPM_REGISTRY_URL=$env:NPM_REGISTRY_URL -t ninja-paws-dojo .
```

To skip mirror configuration for a diagnostic comparison:

```powershell
$env:NPM_USE_MIRROR = 'false'
docker build --build-arg NPM_USE_MIRROR=$env:NPM_USE_MIRROR -t ninja-paws-dojo .
```

When `NPM_USE_MIRROR=false`, npm uses its direct default registry. This does not bypass Defender Exploit Guard; a host policy that blocks `registry.npmjs.org` will still block the build. The same variables can be stored as non-secret GitHub Environment variables. Do not put credentials in the URL. There is intentionally no `SKIP_NPM_INSTALL` option because it would create an incomplete image and bypass dependency integrity checks.

To disable npm network access entirely:

```powershell
$env:NPM_NETWORK_MODE = 'offline'
docker build --build-arg NPM_NETWORK_MODE=$env:NPM_NETWORK_MODE -t ninja-paws-dojo .
```

Offline mode still runs `npm ci --offline --ignore-scripts`; it does not skip dependency installation. It succeeds only when the required package tarballs are already in the npm cache or supplied by a prebuilt dependency image/build layer. On a clean Docker builder, offline mode will fail with a missing-cache error, which is intentional and safer than silently omitting dependencies.

### Subscription, tenant, and region setup

The lifecycle uses the Azure CLI's persisted current subscription from `az account show`, so a subscription selected with `az account set` or a previous `--subscription` selection is reused on later runs. Pass `--subscription <id>` when you want to switch it explicitly. If no region was supplied, it presents a numbered region list with **Central US (`centralus`)** as the default; pressing Enter accepts that default. `--defaults` uses the current Azure subscription and Central US without prompting. GitHub Actions is non-interactive and uses the GitHub Environment values.

The OIDC bootstrap command stores `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, and `AZURE_LOCATION` as GitHub **Environment variables**. Subscription and tenant IDs are identifiers, not credentials, so GitHub variables are the correct storage class; putting them in Key Vault would add complexity without protecting a secret. The bootstrap creates no client secret and deploys through short-lived GitHub OIDC tokens. Any actual client secret, API key, connection string, or runtime password belongs in an Azure Key Vault reference or GitHub Environment secret, never in this repository.

Deployment state and audit fields mask subscription and tenant IDs before writing them to JSON, HTML, or report text. Direct Azure portal links may still contain the full subscription ID because Azure requires it for a resource deep link. The full ID and tenant remain in process memory for Azure CLI operations and are never intentionally written as credential material.

Bootstrap or refresh the GitHub Environment configuration with:

```bash
bash scripts/setup-azure-github-oidc.sh --environment dev
```

Use `--defaults` for Central US and the current Azure subscription, or choose a numbered region during the interactive prompt. Pass `--subscription <id>` when you need to change subscriptions. Review the generated GitHub Environment variables before enabling `--provision`; Defender plan tiers can incur subscription charges.

## Azure Deployment

Use `scripts/manage.sh` as the management entry point. With no arguments, it runs a read-only wizard that detects `dev` or `main` from the current Git branch, validates the Azure connection, confirms subscription read access, inspects the configured environment, and offers only lifecycle actions supported by the detected state. `scripts/deploy.sh` remains available for direct automation and supports `plan`, `doctor`, `provision`, `build`, `deploy`, `verify`, `repair`, and guarded `uninstall` stages.

```bash
bash scripts/manage.sh
```

The wizard presents unavailable actions in the terminal instead of attempting them. For example, uninstall is unavailable until a matching resource group with the required ownership tags exists; verify and rollout require both the App Service and registry. Selecting an action hands off to the established lifecycle command, including its existing confirmations and branch guards.

Mutating stages are branch-locked: a `dev` checkout can only target the `dev` Environment, and a `main` checkout can only target `prod`. `plan`, `doctor`, and `verify` remain read-only diagnostic stages and may be pointed at either environment explicitly.

```bash
bash scripts/test.sh --skip-azure
bash scripts/deploy.sh plan
bash scripts/deploy.sh doctor
bash scripts/deploy.sh deploy
```

Run `scripts/test.sh` before deployment from a host shell. It checks the local Bash, Node.js, Azure CLI, Bicep, and repository prerequisites and reports host package requirements such as ICU before compiling infrastructure. `scripts/deploy.sh doctor` performs the authenticated Azure preflight and Bicep/what-if checks; neither command changes Azure resources.

Use `--defaults` to accept built-in values and `--yes` for non-interactive confirmation. The wizard shows Bicep progress, resource operations, and writes fresh per-run artifacts under `output/<environment>/`, relative to the directory where the script was launched.

`uninstall` uses a focused teardown wizard rather than deployment prompts: it shows the branch-locked environment, offers the configured resource group as the default, and defaults to waiting for Azure to confirm deletion. It then verifies the live Ninja Paws ownership tags before asking for the destructive confirmation. Use `--no-wait` only when an automation caller intentionally needs an asynchronous deletion request.

Each lifecycle run also writes an auto-refreshing HTML status dashboard to `output/<environment>/deployment-<environment>.html`. Open that local file in a browser while the command runs to see the latest stage, percentage, environment coordinates, image, and links to detailed logs/state. No web server is required; the terminal remains the authoritative live stream. Use `--no-status-html` when a file report is not wanted.

The report shows stage outcomes, durations, failure details, verification evidence, and next steps. Use **Generate PDF** to open the browser's print dialog and save a snapshot. Set `DEPLOY_BROWSER` or `BROWSER` to choose an opener, or use `--no-open-status` in headless terminals and CI.

The task list is built dynamically from the command you ran, so it always reflects the real work:

| Command                                  | Tasks after preflight and planning                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------- |
| `plan`                                   | dry run only; preflight is marked _Not applicable_                                    |
| `doctor`                                 | compile Bicep, what-if against the resource group                                     |
| `provision`                              | create and tag the resource group, deploy the Bicep infrastructure                    |
| `build`                                  | fingerprint the build context, build or reuse the image                               |
| `rollout`                                | configure App Service, restart and wait for health, verify                            |
| `verify`                                 | verify Azure resources, then run the Defender scan and workload-coverage task         |
| `deploy` / `setup` / `update` / `repair` | all stages end to end, followed by the Defender scan and workload-coverage task       |
| `uninstall`                              | locate the resource group, confirm ownership tags, request deletion, confirm teardown |

### Defender for Cloud scan and workload coverage

For deployment-shaped commands, the report runs a Defender task **after** App Service and endpoint verification. The task performs these actions and records each result in the verification matrix:

1. Activates or verifies the configured Defender for App Service, Defender for Containers, and Defender CSPM pricing tiers.
2. Reads the latest Defender for Cloud assessment inventory for the target resource group.
3. Searches the assessment payload for the configured target CVE.
4. Verifies that App Service attack detection and ACR image vulnerability assessment are covered.
5. Records Kubernetes runtime coverage and unrelated workload plans as **Not applicable** for this scenario; Resource Manager protection is configured separately at subscription scope.

The scan task is deliberately honest about timing. Defender vulnerability assessment is asynchronous and its engines continuously rescan or rescan on their service schedule; the Azure CLI does not provide a supported synchronous "scan this image now" operation for this deployment shape. The task therefore forces a fresh post-deployment assessment inventory read and reports **Not sure** when the target CVE is not yet present, rather than treating an empty or still-initializing result as proof that the image is clean.

**What the plans monitor here:**

- **Defender for App Service:** requests and responses to the app, App Service internal logs, the hosting sandbox, and the underlying platform VM/management surface for attack detection and security recommendations.
- **Defender for Containers:** the Azure Container Registry image supply chain and known image vulnerabilities, including CVE findings. It does not turn this App Service deployment into an AKS workload and does not provide Kubernetes sensor coverage here.
- **Defender CSPM:** foundational posture and recommendation visibility for the subscription and deployed Azure resources.

The report's Environment access panel links directly to App Service Metrics/diagnostics and the Defender for Cloud Recommendations blade. When the scan returns **Not sure**, open the linked Recommendations blade and filter by the target image or CVE after Defender has finished processing the image.

Official references: [What is Microsoft Defender for Cloud?](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction), [Defender for App Service](https://learn.microsoft.com/azure/defender-for-cloud/tutorial-enable-app-service-plan), [Defender for Containers](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction), and [view vulnerabilities for running containers](https://learn.microsoft.com/azure/defender-for-cloud/view-and-remediate-vulnerabilities-containers).

The final report stops refreshing and retains **Pass**, **Failure**, **Not sure**, and **Not applicable** outcomes alongside evidence and links to the application and Azure resources.

### Content-addressed builds

Every build first computes a **fingerprint**: a SHA-256 over each file the Dockerfile copies (`Dockerfile`, `package.json`, `package-lock.json`, `src/app.js`, `nginx.conf`, `entrypoint.sh`) plus every build argument. That fingerprint is pushed as an extra tag (`fp-<hash>`) alongside the immutable Git-SHA tag.

Use the Git-SHA tag or image digest for deployments. `latest`, `vulnerable`, and `remediated` are convenience aliases for demos and must not be used as production rollout selectors. Separate ACRs provide the dev/prod image boundary; separate image names are unnecessary.

On the next run the script looks up `fp-<hash>` in ACR:

- **Hash already present** — nothing changed. The build and upload are skipped entirely; the Git-SHA, `latest`, and training-status tags are aliased to the existing manifest digest server-side with `az acr import`, which transfers no layers.
- **App Service already configured for that exact image and passing `/health`** — the rollout and restart are skipped too, so a no-op deploy causes no downtime.
- **Hash absent** — the content genuinely changed, so a full `az acr build` runs.

The report shows the resolved manifest digest, the fingerprint, and whether the image was _Unchanged (rebuild and upload skipped)_ or _Changed (rebuilt and pushed)_. Verification asserts that the deployed tag and the current source fingerprint resolve to the same digest, so drift between the working tree and the running container is caught. Use `--force-rebuild` to bypass both skips.

Every run starts with a clean environment output directory. The previous run is archived under `output/archive/<timestamp>-<environment>/` by default, preserving troubleshooting history without allowing stale files to affect the current run. Use `--no-archive` only when automatic deletion of the previous output is explicitly preferred.

The **Live Console** artifact at `output/<environment>/deployment-<environment>.console.html` preserves deployment messages. Answer interactive prompts in the terminal, not the report.

Initial GitHub OIDC setup is separate and runs once per Environment:

```bash
az login
gh auth login
bash scripts/setup-azure-github-oidc.sh --environment dev --provision
bash scripts/setup-azure-github-oidc.sh --environment prod --provision
```

The bootstrap creates the Entra federated credential, assigns deployment roles, and writes non-secret identifiers/configuration to GitHub Environment variables. It does not create a client secret.

## Promotion and Releases

1. Develop on feature branches and merge into `dev` after validation.
2. Run **Deploy to Azure** manually from `dev` when the `dev` GitHub Environment is ready.
3. Run **Promote dev to main** from `dev` to open a promotion PR.
4. Review and merge that PR through protected `main`.
5. Run **Deploy to Azure** manually from `main` to promote the stable baseline to the `prod` GitHub Environment.

For releases, run **Request release from dev** and choose `patch`, `minor`, `major`, or `custom`. It creates a release PR that updates `package.json` and `package-lock.json`. After merge, **Publish main release** validates metadata, rejects duplicate/backward versions, creates `vX.Y.Z`, publishes the GitHub Release, and pushes the versioned and `latest` ACR images.

Package metadata must match the repository name and description, remain MIT licensed, retain the repository URL, and keep the lockfile synchronized. `NODE_MAJOR_VERSION` controls release validation and Docker builds.

## Workflows

Reusable Bicep validation and Defender posture checks come from [Pawprint](https://github.com/ninjapaw/pawprint). Workflow files contain the pinned revisions; scenario code and deployment configuration remain owned by this repository.

- `validate-infrastructure.yml`: installs dependencies, runs repository/runtime tests, and delegates Bicep compilation/drift checks to the shared Pawprint contract
- `validate-remediation.yml`: container remediation and endpoint validation
- `deploy.yml`: branch-aware staged Azure deployment (NGINX CVE / App Service + ACR)
- `promote-dev-to-main.yml`: opens the dev-to-main promotion PR
- `request-release.yml`: prepares a versioned release PR
- `publish-release.yml`: publishes tags, GitHub Releases, and ACR images
- `uninstall.yml`: protected, exact-name-confirmed Azure and Environment cleanup

Run the shared checks locally:

```bash
npm ci
npm test
bash scripts/test.sh --skip-azure
bash scripts/test.sh
```

`npm test` covers the container runtime. `scripts/test.sh --skip-azure` also runs container tests, shared-helper checks, and deployment-report smoke checks. It works from any current directory. The non-skipped Azure path compiles local Bicep but does not deploy resources.

## Security

Do not commit secrets, customer data, production credentials, or private infrastructure details. Report security issues privately according to [SECURITY.md](SECURITY.md). See [CONTRIBUTING.md](CONTRIBUTING.md) for review and promotion requirements.

## License and Ownership Notice

The source is provided under the [MIT License](LICENSE). The MIT license does not grant rights to Microsoft trademarks, names, logos, or third-party materials. Microsoft trademarks and product names remain the property of Microsoft Corporation. This repository is an unapproved, unofficial community demonstration and should not imply Microsoft sponsorship or authorization.

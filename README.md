# Ninja Paws Cloud Security Dojo

> **Independent community project.** This repository is maintained by Dr Bill Mcilhargey for Ninja Paw. It is not a Microsoft product and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation. Microsoft product names and trademarks remain the property of Microsoft Corporation. Use this public demo at your own risk.
>
> Microsoft, Azure, GitHub, Defender, and related names and marks are owned by their respective owners. This repository is not an approved or authorized Microsoft project unless separately stated by Microsoft in writing.

A defensive cloud-security training environment demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

## Defender for Cloud - Scenario 1

**NGINX CVE Detection and Remediation** is the default scenario. It deploys the intentionally affected NGINX `1.30.3` workload and advisory-relevant `map`/regex configuration to Azure App Service with Azure Container Registry, Defender for App Service, Defender for Containers, and Defender CSPM coverage. The demo proves the running package and configuration, reviews Defender findings, then swaps to fixed NGINX `1.30.4` with the affected configuration removed.

Scenarios are registered in `config/deploy.config.json`. Select the default explicitly with `--scenario defender-cloud-scenario-1`, or use `--all-scenarios` as the future expansion point when additional scenario definitions are registered. Each future scenario should declare its own advisory, affected/fixed versions, workloads, image/build inputs, and verification checks.

## What It Demonstrates

- Node.js and Express application with NGINX reverse proxy
- Docker and Docker Compose local execution
- GitHub Actions validation, promotion, release, and deployment
- Azure Container Registry and App Service for Linux containers
- Bicep infrastructure with managed identity and ACR pull access
- Microsoft Defender for Cloud integration points

The default training state intentionally uses NGINX `1.30.3`, which is in the affected NGINX Open Source range for the real [CVE-2026-42533 F5 advisory](https://my.f5.com/manage/s/article/K000162097). The advisory identifies NGINX Open Source `1.30.0-1.30.3` as vulnerable and `1.30.4` as fixed. The application reports `vulnerable` only when runtime evidence confirms both an affected NGINX version and the affected map/regex configuration; it does not use the scenario label as proof. Do not expose the training deployment to untrusted users or use it with real data.

For a customer-facing, self-guided run-through, start with [DEMO.md](DEMO.md). It walks through baseline deployment, evidence review, Defender coverage, patched-state redeployment, before/after interpretation, and cleanup.

## Quick Start

Prerequisites: Git, Node.js 20+, Docker/Docker Compose, and Bash. Azure deployment additionally requires Azure CLI; GitHub OIDC bootstrap requires GitHub CLI.

```bash
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo
npm ci
npm test
npm start
```

The direct application listens on `http://localhost:3000`.

### Endpoint surface

| Route | Purpose | Exposure |
| --- | ---: | --- |
| `/` | Human-readable training dashboard | Public application route |
| `/health` | Lightweight JSON health probe | Public application route; used by App Service and rollout checks |
| `/api/status` | JSON CVE metadata, package/config evidence, image host, and runtime state | Public evidence route for the demo |

There is no `/map` HTTP endpoint. `map` is an internal NGINX configuration directive rendered by `entrypoint.sh` into `/etc/nginx/scenario.conf`. In the affected image it combines regex matching and captures; the detector reports this as `runtime_verification.map_regex_enabled: true`. The `/api/status` response is the safe way to inspect that evidence without adding a route that exercises the vulnerable configuration.

The current production deployment is available at [ninjapaws-dojo-app-prod.azurewebsites.net](https://ninjapaws-dojo-app-prod.azurewebsites.net/). Its [health endpoint](https://ninjapaws-dojo-app-prod.azurewebsites.net/health) is suitable for probes; its [status endpoint](https://ninjapaws-dojo-app-prod.azurewebsites.net/api/status) is the authoritative demo evidence surface.

Run the containerized stack:

```bash
docker compose up --build -d
curl http://localhost:8080/health
docker compose logs -f dojo
docker compose down
```

## Configuration

All Docker build arguments are non-secret configuration. Defaults are safe fallbacks; GitHub Environment variables are the source of truth for `dev` and `prod` deployments.

Branch isolation is explicit: `dev` deploys to `NP-ninjapaws-dojo-Dev-CentralUS`, ACR `ninjapawsdojodev`, and App Service `ninjapaws-dojo-app-dev`; `main` deploys to `NP-ninjapaws-dojo-Prod-CentralUS`, ACR `ninjapawsdojoprod`, and App Service `ninjapaws-dojo-app-prod`.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `BASE_OS_IMAGE` | `ubuntu` | Base OS image repository |
| `BASE_OS_VERSION` | `24.04` | Ubuntu image version |
| `NGINX_VERSION` | `1.30.3` | Pinned NGINX package |
| `NODE_MAJOR_VERSION` | `20` | NodeSource major version |
| `VULNERABILITY_STATUS` | `vulnerable` | Scenario configuration intent; the app derives the authoritative vulnerability result from runtime evidence |
| `PORT` | `3000` | Internal Node.js port behind NGINX |
| `WEBSITES_PORT` | `80` | Port exposed by the container to Azure App Service |
| `NPM_REGISTRY_URL` | `https://registry.npmjs.org` | npm registry or approved enterprise mirror used during the image build |
| `NPM_USE_MIRROR` | `true` | Use `NPM_REGISTRY_URL` when true; use npm's direct default when false |
| `NPM_NETWORK_MODE` | `online` | `online` downloads dependencies; `offline` disables npm network access and requires a populated npm cache |
| `DEFENDER_ENABLED` | `true` | Training dashboard flag; this is separate from Defender for Cloud subscription plans |

Defender for Cloud settings live under the `defender` object in `config/deploy.config.json`. The checked-in defaults are intentionally suited to this vulnerable App Service container scenario:

| Setting | Default | Purpose |
| --- | --- | --- |
| `defender.scanAfterVerify` | `true` | Adds a post-verification Defender scan task to `deploy`, `rollout`, `repair`, and `verify` |
| `defender.managePlans` | `true` | Allows the lifecycle to activate the configured Microsoft Security pricing tiers |
| `defender.targetCve` | `CVE-2026-42533` | Real CVE from the F5 NGINX advisory searched for in the latest Defender assessment payload |
| `defender.plans.AppServices` | `Standard` | Defender for App Service attack detection for the App Service workload |
| `defender.plans.Containers` | `Standard` | Defender for Containers vulnerability assessment for Azure Container Registry images |
| `defender.plans.CloudPosture` | `Free` | Foundational Defender CSPM posture visibility |

These settings are configurable per environment and can also be overridden with `DEFENDER_SCAN_ENABLED`, `DEFENDER_MANAGE_PLANS`, `DEFENDER_TARGET_CVE`, `DEFENDER_APPSERVICES_TIER`, `DEFENDER_CONTAINERS_TIER`, and `DEFENDER_CSPM_TIER`. Set a plan tier to `disabled` to mark that workload as **Not applicable** without changing the subscription plan. Plan activation can incur Azure charges; review subscription pricing and permissions before enabling `defender.managePlans` in a shared or production subscription.

The lifecycle does **not** automatically deactivate an already-enabled Defender plan when a workload is set to `disabled`; pricing plans apply at subscription scope, so silently turning off protection from an application deployment would be unsafe. The report instead records unrequested plans as **Not applicable** and leaves subscription-wide deactivation to an explicit Defender for Cloud administrator action.

`entrypoint.sh` generates NGINX from `nginx.conf` at startup, replacing `__APP_PORT__` with `PORT`. This is a deliberate dual-port design: **WEBSITES_PORT=80** tells Azure App Service which container port accepts traffic, while **PORT=3000** is the Node.js upstream behind NGINX. Changing `PORT` changes the NGINX upstream automatically; changing `WEBSITES_PORT` requires changing the container listener and App Service configuration together. Startup also records the actual NGINX binary and Debian package versions, which `/api/status` exposes under `runtime_verification` and the deployment report verifies.

Never put credentials in these variables. Runtime secrets belong in Azure Key Vault with managed identity. GitHub Environment secrets are reserved for values GitHub itself must keep confidential when OIDC or Key Vault cannot provide them.

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

For enterprise builds, I recommend an **Azure Artifacts npm feed** configured with an npmjs.org upstream source. It provides organizational access control, retention, auditability, and caching while preserving package provenance. Set `NPM_REGISTRY_URL` to that feed URL and allow the endpoint to reach the approved feed.

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

On the first interactive deployment, the lifecycle obtains the current Azure context with `az account show`. If more than one enabled subscription is available and no `--subscription` was supplied, it presents a numbered list so you can choose the subscription by number or ID. If no region was supplied, it presents a numbered region list with **Central US (`centralus`)** as the default; pressing Enter accepts that default. `--defaults` uses the current Azure subscription and Central US without prompting. GitHub Actions is non-interactive and uses the GitHub Environment values.

The OIDC bootstrap command stores `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, and `AZURE_LOCATION` as GitHub **Environment variables**. Subscription and tenant IDs are identifiers, not credentials, so GitHub variables are the correct storage class; putting them in Key Vault would add complexity without protecting a secret. The bootstrap creates no client secret and deploys through short-lived GitHub OIDC tokens. Any actual client secret, API key, connection string, or runtime password belongs in an Azure Key Vault reference or GitHub Environment secret, never in this repository.

Deployment state and audit fields mask subscription and tenant IDs before writing them to JSON, HTML, or report text. Direct Azure portal links may still contain the full subscription ID because Azure requires it for a resource deep link. The full ID and tenant remain in process memory for Azure CLI operations and are never intentionally written as credential material.

Bootstrap or refresh the GitHub Environment configuration with:

```bash
bash scripts/setup-azure-github-oidc.sh --environment dev
```

Use `--defaults` for Central US and the current Azure subscription, or choose a numbered region and subscription during the interactive prompts. Review the generated GitHub Environment variables before enabling `--provision`; Defender plan tiers can incur subscription charges.

## Azure Deployment

The local lifecycle wizard detects `dev` or `main` from the current Git branch. It supports `plan`, `doctor`, `provision`, `build`, `deploy`, `verify`, `repair`, and guarded `uninstall` stages.

Mutating stages are branch-locked: a `dev` checkout can only target the `dev` Environment, and a `main` checkout can only target `prod`. `plan`, `doctor`, and `verify` remain read-only diagnostic stages and may be pointed at either environment explicitly.

```bash
bash scripts/test.sh --skip-azure
bash scripts/deploy.sh plan
bash scripts/deploy.sh doctor
bash scripts/deploy.sh deploy
```

Use `--defaults` to accept built-in values and `--yes` for non-interactive confirmation. The wizard shows Bicep progress, resource operations, and writes fresh per-run artifacts under `output/<environment>/`, relative to the directory where the script was launched.

Each lifecycle run also writes an auto-refreshing HTML status dashboard to `output/<environment>/deployment-<environment>.html`. Open that local file in a browser while the command runs to see the latest stage, percentage, environment coordinates, image, and links to detailed logs/state. No web server is required; the terminal remains the authoritative live stream. Use `--no-status-html` when a file report is not wanted.

While the run is active the dashboard is an **executive progress report**: a task list shows every lifecycle stage as *Not started*, *In progress* (animated spinner), *Success*, *Failure*, *Skipped*, or *Not applicable*, each with its own duration and a one-line detail. A failed stage shows the reason inline.

The page never reloads itself. It polls a small state feed (`deployment-<environment>.state.js`) every 2 seconds and patches the DOM in place, so the progress bar, task list, verification matrix, run facts, next steps, and live console all update without flicker and without losing your scroll position. `fetch()` is blocked on `file://` origins, so the feed is loaded by injecting a `<script>` tag, which `file://` does permit.

A **Generate PDF** button at the bottom renders the report through a dedicated print stylesheet (A4, page-break-safe sections and table rows, repeated table headers, preserved status colours) and opens the browser's print dialog — choose *Save as PDF*. It always reflects whatever is on screen at that moment, so you can take a snapshot mid-run or after completion. The raw console is excluded from the PDF to keep it to the executive content.

The task list is built dynamically from the command you ran, so it always reflects the real work:

| Command | Tasks after preflight and planning |
| --- | --- |
| `plan` | dry run only; preflight is marked *Not applicable* |
| `doctor` | compile Bicep, what-if against the resource group |
| `provision` | create and tag the resource group, deploy the Bicep infrastructure |
| `build` | fingerprint the build context, build or reuse the image |
| `rollout` | configure App Service, restart and wait for health, verify |
| `verify` | verify Azure resources, then run the Defender scan and workload-coverage task |
| `deploy` / `setup` / `update` / `repair` | all stages end to end, followed by the Defender scan and workload-coverage task |
| `uninstall` | locate the resource group, confirm ownership tags, request deletion, confirm teardown |

Overall progress is derived from that list rather than hardcoded, so the percentage is meaningful for every command. Each stage also contributes its own rows to the verification matrix and its own tailored **Next steps**, so `uninstall`, `doctor`, and `plan` produce a genuine executive report instead of a deployment-shaped one.

### Defender for Cloud scan and workload coverage

For deployment-shaped commands, the report runs a Defender task **after** App Service and endpoint verification. The task performs these actions and records each result in the verification matrix:

1. Activates or verifies the configured Defender for App Service, Defender for Containers, and Defender CSPM pricing tiers.
2. Reads the latest Defender for Cloud assessment inventory for the target resource group.
3. Searches the assessment payload for the configured target CVE.
4. Verifies that App Service attack detection and ACR image vulnerability assessment are covered.
5. Explicitly records Kubernetes runtime coverage and unrelated Defender plans as **Not applicable** because this project deploys a custom Linux container to Azure App Service, not AKS, SQL, Storage, Key Vault, DNS, or Resource Manager workloads.

The scan task is deliberately honest about timing. Defender vulnerability assessment is asynchronous and its engines continuously rescan or rescan on their service schedule; the Azure CLI does not provide a supported synchronous "scan this image now" operation for this deployment shape. The task therefore forces a fresh post-deployment assessment inventory read and reports **Not sure** when the target CVE is not yet present, rather than treating an empty or still-initializing result as proof that the image is clean.

**What the plans monitor here:**

- **Defender for App Service:** requests and responses to the app, App Service internal logs, the hosting sandbox, and the underlying platform VM/management surface for attack detection and security recommendations.
- **Defender for Containers:** the Azure Container Registry image supply chain and known image vulnerabilities, including CVE findings. It does not turn this App Service deployment into an AKS workload and does not provide Kubernetes sensor coverage here.
- **Defender CSPM:** foundational posture and recommendation visibility for the subscription and deployed Azure resources.

The report's Environment access panel links directly to App Service Metrics/diagnostics and the Defender for Cloud Recommendations blade. When the scan returns **Not sure**, open the linked Recommendations blade and filter by the target image or CVE after Defender has finished processing the image.

Official references: [What is Microsoft Defender for Cloud?](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction), [Defender for App Service](https://learn.microsoft.com/azure/defender-for-cloud/tutorial-enable-app-service-plan), [Defender for Containers](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction), and [view vulnerabilities for running containers](https://learn.microsoft.com/azure/defender-for-cloud/view-and-remediate-vulnerabilities-containers).

When the run reaches 100% the page rewrites itself as a **final executive report** with auto-refresh disabled. It adds a verification matrix where every check is recorded as **Pass**, **Failure**, **Not sure**, or **Not applicable** together with the evidence used to decide, an **Environment access** panel with clickable links to the live application, its `/api/status` and `/health` endpoints, App Service Metrics and diagnostics, Defender for Cloud Recommendations, and the Azure portal blades for the resource group, App Service, and container registry — annotated with whether the site actually responded — and a **Next steps** section tailored to whether the run succeeded or failed.

### Content-addressed builds

Every build first computes a **fingerprint**: a SHA-256 over each file the Dockerfile copies (`Dockerfile`, `package.json`, `package-lock.json`, `app.js`, `nginx.conf`, `entrypoint.sh`) plus every build argument. That fingerprint is pushed as an extra tag (`fp-<hash>`) alongside the immutable Git-SHA tag.

Use the Git-SHA tag or image digest for deployments. `latest`, `vulnerable`, and `remediated` are convenience aliases for demos and must not be used as production rollout selectors. Separate ACRs provide the dev/prod image boundary; separate image names are unnecessary.

On the next run the script looks up `fp-<hash>` in ACR:

- **Hash already present** — nothing changed. The build and upload are skipped entirely; the Git-SHA, `latest`, and training-status tags are aliased to the existing manifest digest server-side with `az acr import`, which transfers no layers.
- **App Service already configured for that exact image and passing `/health`** — the rollout and restart are skipped too, so a no-op deploy causes no downtime.
- **Hash absent** — the content genuinely changed, so a full `az acr build` runs.

The report shows the resolved manifest digest, the fingerprint, and whether the image was *Unchanged (rebuild and upload skipped)* or *Changed (rebuilt and pushed)*. Verification asserts that the deployed tag and the current source fingerprint resolve to the same digest, so drift between the working tree and the running container is caught. Use `--force-rebuild` to bypass both skips.

Every run starts with a clean environment output directory. The previous run is archived under `output/archive/<timestamp>-<environment>/` by default, preserving troubleshooting history without allowing stale files to affect the current run. Use `--no-archive` only when automatic deletion of the previous output is explicitly preferred.

The dashboard includes one **Live Console** artifact at `output/<environment>/deployment-<environment>.console.html`. During interactive setup it shows **Waiting for your input** while the terminal prompts for values; after each answer it updates with the resolved stage and deployment messages. Raw capture is kept only as hidden per-run staging data while the HTML is regenerated.

When possible, the wizard opens the dashboard in the default browser automatically and prints both the absolute path and a clickable `file://` link. Use `--no-open-status` in headless terminals or CI.

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

- `validate-infrastructure.yml`: Bash, package, ARM JSON, and Bicep checks
- `validate-remediation.yml`: container remediation and endpoint validation
- `deploy.yml`: branch-aware staged Azure deployment
- `promote-dev-to-main.yml`: opens the dev-to-main promotion PR
- `request-release.yml`: prepares a versioned release PR
- `publish-release.yml`: publishes tags, GitHub Releases, and ACR images
- `uninstall.yml`: protected, exact-name-confirmed Azure and Environment cleanup

Run the shared checks locally:

```bash
bash scripts/test.sh --skip-azure
bash scripts/test.sh
```

## Security

Do not commit secrets, customer data, production credentials, or private infrastructure details. Report security issues privately according to [SECURITY.md](SECURITY.md). See [CONTRIBUTING.md](CONTRIBUTING.md) for review and promotion requirements.

## License and Ownership Notice

The source is provided under the [MIT License](LICENSE). The MIT license does not grant rights to Microsoft trademarks, names, logos, or third-party materials. Microsoft trademarks and product names remain the property of Microsoft Corporation. This repository is an unapproved, unofficial community demonstration and should not imply Microsoft sponsorship or authorization.

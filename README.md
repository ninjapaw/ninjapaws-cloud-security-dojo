# Ninja Paws Cloud Security Dojo

> **Unofficial community helper.** Ninja Paws is a fictional demo organization used by this repository. This independent community project is not a Microsoft product and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation. Contributions from Microsoft employees, if any, are made in an individual capacity and do not imply Microsoft endorsement or sponsorship. Use this public demo at your own risk.
>
> Microsoft, Azure, GitHub, Defender, and related names and marks are owned by their respective owners. This repository is not an approved or authorized Microsoft project unless separately stated by Microsoft in writing.

A defensive cloud-security training environment demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

## What It Demonstrates

- Node.js and Express application with NGINX reverse proxy
- Docker and Docker Compose local execution
- GitHub Actions validation, promotion, release, and deployment
- Azure Container Registry and App Service for Linux containers
- Bicep infrastructure with managed identity and ACR pull access
- Microsoft Defender for Cloud integration points

The default training state intentionally uses NGINX `1.30.3` and reports `CVE-2026-42533` as vulnerable. Do not expose the training deployment to untrusted users or use it with real data.

## Quick Start

Prerequisites: Git, Node.js 20+, Docker/Docker Compose, and Bash. Azure deployment additionally requires Azure CLI; GitHub OIDC bootstrap requires GitHub CLI.

```bash
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo
npm ci
npm test
npm start
```

The direct application listens on `http://localhost:3000`. Health and status endpoints are `/health` and `/api/status`.

Run the containerized stack:

```bash
docker compose up --build -d
curl http://localhost:8080/health
docker compose logs -f dojo
docker compose down
```

## Configuration

All Docker build arguments are non-secret configuration. Defaults are safe fallbacks; GitHub Environment variables are the source of truth for `dev` and `prod` deployments.

| Variable | Default | Purpose |
|---|---:|---|
| `BASE_OS_IMAGE` | `ubuntu` | Base OS image repository |
| `BASE_OS_VERSION` | `24.04` | Ubuntu image version |
| `NGINX_VERSION` | `1.30.3` | Pinned NGINX package |
| `NODE_MAJOR_VERSION` | `20` | NodeSource major version |
| `VULNERABILITY_STATUS` | `vulnerable` | Training state reported by the app |
| `PORT` | `3000` | Internal Node.js port |
| `DEFENDER_ENABLED` | `false` | Training dashboard flag |

`entrypoint.sh` generates NGINX from `nginx.conf` at startup, replacing `__APP_PORT__` with `PORT`. NGINX continues to listen on port 80; `PORT` controls the internal Node.js upstream.

Never put credentials in these variables. Runtime secrets belong in Azure Key Vault with managed identity. GitHub Environment secrets are reserved for values GitHub itself must keep confidential when OIDC or Key Vault cannot provide them.

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
| `verify` | verify only |
| `deploy` / `setup` / `update` / `repair` | all seven stages end to end |
| `uninstall` | locate the resource group, confirm ownership tags, request deletion, confirm teardown |

Overall progress is derived from that list rather than hardcoded, so the percentage is meaningful for every command. Each stage also contributes its own rows to the verification matrix and its own tailored **Next steps**, so `uninstall`, `doctor`, and `plan` produce a genuine executive report instead of a deployment-shaped one.

When the run reaches 100% the page rewrites itself as a **final executive report** with auto-refresh disabled. It adds a verification matrix where every check is recorded as **Pass**, **Failure**, **Not sure**, or **Not applicable** together with the evidence used to decide, an **Environment access** panel with clickable links to the live application, its `/api/status` and `/health` endpoints, and the Azure portal blades for the resource group, App Service, and container registry — annotated with whether the site actually responded — and a **Next steps** section tailored to whether the run succeeded or failed.

### Content-addressed builds

Every build first computes a **fingerprint**: a SHA-256 over each file the Dockerfile copies (`Dockerfile`, `package.json`, `package-lock.json`, `app.js`, `nginx.conf`, `entrypoint.sh`) plus every build argument. That fingerprint is pushed as an extra tag (`fp-<hash>`) alongside the immutable Git-SHA tag.

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
2. `dev` deploys to the `dev` GitHub Environment.
3. Run **Promote dev to main** from `dev` to open a promotion PR.
4. Review and merge that PR through protected `main`.
5. `main` deploys to the `prod` GitHub Environment.

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

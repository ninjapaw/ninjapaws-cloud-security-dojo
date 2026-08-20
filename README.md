# Ninja Paws Cloud Security Dojo

This repository is a public educational cloud security training environment for demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

## Quicklinks

- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Pull request template](pull_request_template.md)
- [Azure deploy button](#azure-deploy-button)
- [GitHub issues](https://github.com/ninjapaw/ninjapaws-cloud-security-dojo/issues)

## Overview

The dojo demonstrates a defensive security workflow using:

- Node.js and Express for the application and status API
- NGINX as a reverse proxy
- Docker and Docker Compose for local training
- GitHub Actions for image scanning and remediation validation
- Azure Container Registry for image storage
- Azure App Service for container hosting
- Bicep and managed identity for Azure infrastructure
- Microsoft Defender for Cloud for container security monitoring

```text
GitHub Repository
  |
GitHub Actions
  |
Azure Container Registry
  |
Azure App Service Linux Container
  |
Microsoft Defender for Cloud
```

## Intentional training vulnerability

The default `main` branch intentionally pins NGINX `1.30.3` and reports `CVE-2026-42533` as vulnerable for authorized training and scanner demonstrations. This state is not suitable for production.

The remediation exercise updates the Docker build argument to NGINX `1.30.4` or newer, changes the training status to `remediated`, rebuilds the image, and verifies the actual package and runtime state. The remediation workflow does not inject fake version or status values.

## Getting started

### Prerequisites

- Docker and Docker Compose
- Node.js 18 or newer for direct local development
- Git
- Azure CLI for Azure deployment

### Local development

```bash
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo
npm install
npm start
```

Open `http://localhost:3000/`, or query the endpoints:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/api/status
```

### Docker Compose

```bash
docker compose up --build -d
curl http://localhost:8080/health
docker compose logs -f dojo
docker compose down
```

The default ports are `8080` for NGINX and `3000` for the direct Node.js endpoint.

### Docker image

```bash
docker build -t ninjapaws-dojo:vulnerable .
docker run --rm \
  -p 8080:80 \
  -p 3000:3000 \
  ninjapaws-dojo:vulnerable
```

The Docker build accepts these arguments:

| Argument | Default | Purpose |
|---|---:|---|
| `UBUNTU_VERSION` | `24.04` | Ubuntu base image tag |
| `NGINX_VERSION` | `1.30.3` | Pinned NGINX package version |
| `NODE_MAJOR_VERSION` | `20` | NodeSource major release stream |
| `VULNERABILITY_STATUS` | `vulnerable` | Training state reported by the app |
| `PORT` | `3000` | Node.js listening port |

Example override for a remediation build:

```bash
docker build \
  --build-arg NGINX_VERSION=1.30.4 \
  --build-arg VULNERABILITY_STATUS=remediated \
  -t ninjapaws-dojo:remediated .
```

For Compose overrides, copy `.env.example` to `.env.local` and adjust the values. Do not commit credentials or sensitive values.

## Application endpoints

- `/` displays the training dashboard.
- `/health` returns the health state used by container and App Service checks.
- `/api/status` returns the NGINX version, training state, CVE identifier, platform, and runtime details.

## Azure deployment

### Azure deploy button

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fninjapaw%2Fninjapaws-cloud-security-dojo%2Fmain%2Fazuredeploy.json)

The ARM template provisions an Azure Container Registry, Linux App Service Plan, App Service, user-assigned managed identity, and `AcrPull` role assignment. The App Service pulls from ACR through managed identity; registry admin credentials are disabled.

### Deployment script

The deployment wizard supports initial setup, repeat deployments, repair, preflight checks, safe uninstall, and verification. It discovers the repository root, selects the Azure subscription explicitly when requested, provisions [infra/main.bicep](infra/main.bicep), builds an immutable image tag, configures App Service to use that tag, records non-secret deployment state under `.azure/`, and verifies Azure configuration plus the public `/health` and `/api/status` endpoints.

```bash
chmod +x scripts/deploy.sh
scripts/deploy.sh setup
```

With no `--environment`, the wizard detects the current Git branch: `dev` selects the development environment and `main` selects production. Detached HEADs and other branches require an explicit `--environment dev` or `--environment prod`.

The lifecycle stages are independently resumable:

```bash
scripts/deploy.sh plan --environment prod
scripts/deploy.sh doctor --environment prod --subscription <subscription-id>
scripts/deploy.sh provision --environment prod --subscription <subscription-id>
scripts/deploy.sh build --environment prod --subscription <subscription-id> --image-tag <tag>
scripts/deploy.sh deploy --environment prod --subscription <subscription-id>
scripts/deploy.sh repair --environment prod --subscription <subscription-id>
scripts/deploy.sh verify --environment prod
scripts/deploy.sh uninstall --environment prod --subscription <subscription-id> --wait
```

Use `--yes` for automation and `--defaults` when you explicitly want all built-in values accepted without prompts. In an interactive terminal, setup displays each default and waits for Enter or an override. Uninstall also requires the resource group to carry the deployment ownership tags unless `--force` is deliberately supplied. Override `--location`, `--resource-group`, `--registry-name`, `--app-service-name`, `--image-name`, or `--image-tag` when needed. The default image tag is the current Git commit SHA; `latest` remains published as a convenience tag but is not used as the final App Service target.

### Configure GitHub OIDC and Azure roles

To create or reuse the Entra application, add the GitHub federated credential, assign the deployment roles, create the resource group, and deploy the infrastructure in one idempotent command:

Run this separately as a one-time bootstrap per GitHub Environment. It creates or reuses the Entra application, configures the environment-scoped federated credential, saves non-secret Azure identifiers and deployment settings as Environment variables, grants the deployment identity its Azure roles, and can optionally provision the resource group infrastructure.

```bash
chmod +x scripts/setup-azure-github-oidc.sh
scripts/setup-azure-github-oidc.sh --environment prod --provision
scripts/setup-azure-github-oidc.sh --environment dev --provision
```

The script uses named options such as `--resource-group`, `--location`, `--registry-name`, `--app-service-name`, `--repository`, and `--subscription`. It creates no client secret. The executing identity must be allowed to create app registrations, assign Azure roles, and deploy the resource group infrastructure. Routine deployments should use the deployment workflow or `scripts/deploy.sh`, not rerun OIDC bootstrap.

For first provision, run OIDC bootstrap, then run the deployment wizard:

```bash
az login
gh auth login
scripts/setup-azure-github-oidc.sh --environment prod --subscription <subscription-id> --provision
scripts/deploy.sh deploy --environment prod --subscription <subscription-id>
```

The bootstrap command automatically writes the Azure login identifiers and deployment variables to the selected GitHub Environment. Manually configure required reviewers and branch restrictions under **Repository Settings > Environments > dev/prod**. No application secret exists today, so no Key Vault secret is required for this repository.

### Manual Bicep deployment

```bash
az login
az group create --name NP-ninjapaws-dojo-CentralUS --location centralus
az deployment group create \
  --name ninjapaws-dojo-deployment \
  --resource-group NP-ninjapaws-dojo-CentralUS \
  --template-file infra/main.bicep \
  --parameters \
    containerRegistryName=ninjapawsdojo \
    appServiceName=ninjapaws-dojo-app \
    location=centralus
```

### Verify Azure deployment

```bash
APP_HOST=$(az webapp show \
  --resource-group NP-ninjapaws-dojo-CentralUS \
  --name ninjapaws-dojo-app \
  --query defaultHostName -o tsv)

curl "https://${APP_HOST}/health"
curl "https://${APP_HOST}/api/status"
az webapp log tail --resource-group NP-ninjapaws-dojo-CentralUS --name ninjapaws-dojo-app
```

The GitHub Actions deployment derives the target exclusively from the Git ref: `dev` always deploys to the `dev` GitHub Environment and `main` always deploys to `prod`. There is no environment override in the workflow, preventing an accidental cross-environment deployment. Workflow dispatch uses the branch selected in GitHub; other branches fail before Azure login. It requires the Azure identifier variables and deployment variables created by the OIDC setup script. It calls the same staged wizard used locally, so pushes update both Bicep-managed infrastructure and the application image. Manual dispatch supports `doctor`, `provision`, `build`, `deploy`, `verify`, and `repair`; the separate uninstall workflow requires exact resource-group confirmation and environment protection.

### Dev-to-main promotion

Use this promotion path for code and infrastructure changes:

1. Create a feature branch from `dev` and open a pull request into `dev`.
2. Merge only after validation, remediation tests, infrastructure checks, and the `dev` deployment pass.
3. Run **Actions > Promote dev to main > Run workflow** with the branch set to `dev`.
4. The workflow creates or reuses a `dev` to `main` pull request.
5. Review the promotion diff and merge it through the protected `main` branch.
6. The merge to `main` automatically deploys the exact `main` commit to the `prod` Environment.

The promotion workflow never merges or deploys production itself. Configure branch protection for `main` with required pull request review, required status checks (`Validate deployment assets` and applicable remediation checks), and required reviewers on the `prod` Environment. This keeps development deployment automatic while making production promotion deliberate and auditable.

### Configuration and secret placement

The OIDC setup script writes these non-secret values to each GitHub Environment as **variables** and owns their lifecycle. `AZURE_CLIENT_ID` is explicitly migrated out of any legacy Environment secret and is removed in both variable and secret form during uninstall.

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the Microsoft Entra application used by GitHub Actions |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID containing the dojo resources |
| `AZURE_LOCATION` | Azure region |
| `AZURE_RESOURCE_GROUP` | Environment resource group |
| `AZURE_CONTAINER_REGISTRY_NAME` | ACR name |
| `AZURE_APP_SERVICE_NAME` | App Service name |
| `AZURE_IMAGE_NAME` | Container image repository |
| `NGINX_VERSION` | Training image NGINX version |
| `VULNERABILITY_STATUS` | Training status reported by the app |

The federated credential subject is `repo:ninjapaw/ninjapaws-cloud-security-dojo:environment:<environment>`, matching the workflow's declared environment. The value in `AZURE_CLIENT_ID` must be the application (client) ID from the same tenant as `AZURE_TENANT_ID`; otherwise Azure Login fails with `AADSTS700016`. Do not create or store an Azure client secret for this workflow.

Use this placement policy:

- **GitHub Environment variables:** non-secret deployment coordinates and feature/configuration values that CI needs before Azure login, separated for `dev` and `prod`.
- **Azure Key Vault:** application/runtime secrets such as API keys, database passwords, signing keys, certificates, and connection strings. App Service should read them through managed-identity Key Vault references; secret values should never be written to Bicep parameters, GitHub variables, workflow logs, or committed files.
- **GitHub Environment secrets:** only values that GitHub itself must keep confidential and cannot obtain through OIDC or Key Vault. This repository currently requires none because OIDC uses identifiers, not a client secret.

Use **organization-level GitHub variables** only for truly shared, non-secret values that should be identical across repositories, such as a common image namespace, default Azure region, or organization-wide policy label. Environment variables take precedence when a repository needs a different `dev` or `prod` value. For shared values that legitimately differ by environment, keep them as Environment variables (`AZURE_LOCATION_DEV`, `AZURE_LOCATION_PROD`, for example) or, preferably, use the separate `dev` and `prod` Environments so workflow names stay stable. Do not put secrets in organization variables; use Key Vault or the narrowly scoped GitHub Environment secret fallback.

The uninstall workflow removes the Environment variables created by this repository. It does not delete organization-level variables because those may be shared by other repositories; organization-variable ownership and cleanup must remain an organization administrator's responsibility.

Key Vault is not a replacement for ordinary configuration: putting resource names and regions there would make bootstrap harder without improving confidentiality. When the application gains its first runtime secret, add a Key Vault resource and managed-identity `Key Vault Secrets User` assignment in Bicep, then reference the secret from App Service using a Key Vault reference.

The deployment identity needs permission to deploy the Bicep resources and create the managed-identity `AcrPull` assignment. Use a least-privilege custom role where possible; otherwise, the bootstrap identity needs Contributor plus permission to write role assignments at the deployment scope. The staged wizard uses server-side `az acr build`, so the GitHub Environment identity also receives `AcrPush` and `AcrBuild` on the registry.

There are currently no application secrets in this repository. Do not create a Key Vault merely to hold empty configuration. If a future runtime secret is introduced, store it in Azure Key Vault and reference it from App Service using managed identity; keep GitHub OIDC identifiers as GitHub Environment variables because they are not secret values.

On Windows, run the Bash scripts from WSL, Git Bash, or another Bash-compatible environment. The repository enforces LF line endings for shell scripts.

### Cross-platform tests

Run the shared Bash test wrapper from Linux, macOS, WSL, or Git Bash:

```bash
bash scripts/test.sh
```

When Azure CLI is unavailable, run the local-only checks with `bash scripts/test.sh --skip-azure`. CI runs the full wrapper and Bicep compilation on Ubuntu. PowerShell is not required for the deployment path; keep it only for Windows-specific administration outside this repository.

### Azure cleanup

Training resources incur charges while running. Use the guarded uninstall stage when finished:

```bash
scripts/deploy.sh uninstall \
  --environment prod \
  --subscription <subscription-id> \
  --resource-group NP-ninjapaws-dojo-CentralUS \
  --wait
```

The GitHub uninstall workflow is manual-only and should use a protected `prod` Environment with required reviewers. It requires typing the exact resource-group name before Azure deletion is attempted.

## Detection and remediation workflow

1. Build the default vulnerable image.
2. Let GitHub Advanced Security analyze source and Defender for Cloud scan trusted images after the deployment workflow pushes them to ACR.
3. Create a remediation branch.
4. Change `ARG NGINX_VERSION=1.30.3` to `ARG NGINX_VERSION=1.30.4` or newer.
5. Set `VULNERABILITY_STATUS=remediated` for the patched training image.
6. Build and test the patched image.
7. Open a pull request and review the remediation workflow results.
8. Merge only after the actual package version, runtime status, endpoints, and security scan pass.

The repository workflows are:

- `.github/workflows/validate-remediation.yml`: builds the PR image, checks the actual NGINX version, tests endpoints, and verifies remediated runtime state.
- `.github/workflows/deploy.yml`: provisions or updates Azure, pushes the image, and runs a health check.

### Security integrations

- **GitHub Advanced Security:** enable CodeQL default setup or an organization code-security configuration for this repository. GitHub then analyzes JavaScript source without a repository-owned CodeQL workflow.
- **Microsoft Defender for DevOps:** in the Azure Defender for Cloud environment settings, connect the GitHub organization/repository as a DevOps connector. Defender for DevOps then evaluates the connected repository and reports findings in Azure.
- **Microsoft Defender for Cloud:** enable the Defender plan for Container Registries. The deployment workflow publishes trusted images to ACR; Defender for Cloud scans the pushed image and reports container findings in Azure.

These integrations are configured in GitHub and Azure, not in application code. GitHub permissions, the Azure connector, Defender plans, and ACR scanning must be enabled in their respective services.

## Training exercises

### Detection

```bash
docker build -t ninjapaws-dojo:scan .
curl http://localhost:8080/api/status | jq '.vulnerability'
```

### Remediation

Create a branch, update the NGINX build argument and status, then rebuild:

```bash
git checkout -b fix/cve-2026-42533
docker build \
  --build-arg NGINX_VERSION=1.30.4 \
  --build-arg VULNERABILITY_STATUS=remediated \
  -t ninjapaws-dojo:remediated .
```

Run the image and verify `/health`, `/api/status`, and the NGINX package version before opening a pull request.

### Reporting

Record the image tag, scanner, timestamp, package version, vulnerability result, remediation change, and endpoint validation results in the pull request. Never include secrets, customer data, or private infrastructure details.

## Troubleshooting

- Port already in use: change the host side of the Compose mapping, such as `9999:80`.
- App does not respond: run `docker compose ps` and `docker compose logs dojo`.
- Image does not build: retry with `docker build --no-cache`, then check network access to Ubuntu, NGINX, NodeSource, and npm registries.
- Azure image pull failure: verify the App Service identity has `AcrPull`, the image exists in ACR, and `WEBSITES_PORT` is `80`.
- Azure health failure: inspect App Service logs and confirm NGINX forwards to Node.js on port `3000`.

## Security and legal information

This is an independent community project, not a Microsoft product, and is not affiliated with, sponsored by, endorsed by, or supported by Microsoft Corporation. Microsoft trademarks and product names remain the property of Microsoft Corporation.

The project is for authorized, non-production, defensive security training only. It intentionally contains a vulnerable training state and must not be exposed to untrusted users or used with real customer data, credentials, or production systems. See [SECURITY.md](SECURITY.md) for reporting guidance.

## License

This project is licensed under the [MIT License](LICENSE).

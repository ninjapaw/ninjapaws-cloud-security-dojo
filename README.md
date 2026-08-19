# Ninja Paws Cloud Security Dojo

This repository is a public educational cloud security training environment for demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

## Quicklinks

- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Deployment configuration](#deployment-configuration)
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
./scripts/compose.sh up --build -d
curl http://localhost:8080/health
./scripts/compose.sh logs -f dojo
./scripts/compose.sh down
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

For local Compose runs, use the shared configuration wrapper. Edit [config/deployment.json](config/deployment.json) for non-secret training settings, then run:

```bash
./scripts/compose.sh up --build -d
curl http://localhost:8080/health
./scripts/compose.sh down
```

`config/deployment.json` is committed because it contains no credentials. Do not add secrets to it.

## Repository layout

```text
src/                 Node.js application source
config/              Shared non-secret deployment and runtime configuration
container/           NGINX container configuration
scripts/             Deployment, Compose, configuration, and container runtime scripts
infra/               Bicep infrastructure
.github/workflows/   GitHub Actions workflows
```

`scripts/deploy.sh` writes Azure deployment results to a temporary file and removes it automatically. There is no repository-owned `deployment-output.json` because it is generated output, not source.

## Application endpoints

- `/` displays the training dashboard.
- `/health` returns the health state used by container and App Service checks.
- `/api/status` returns the NGINX version, training state, CVE identifier, platform, and runtime details.

## Azure deployment

### Deployment configuration

[config/deployment.json](config/deployment.json) is the canonical non-secret configuration for this repository. It contains Azure resource names, location, image defaults, training runtime values, and branch-to-environment mapping. [config/schema.json](config/schema.json) documents and validates its shape. [container/nginx.conf](container/nginx.conf) holds the NGINX reverse-proxy configuration.

All supported deployment paths load this file: [scripts/deploy.sh](scripts/deploy.sh), [infra/main.bicep](infra/main.bicep), [docker-compose.yml](docker-compose.yml) through [scripts/compose.sh](scripts/compose.sh), and [deploy.yml](.github/workflows/deploy.yml). This repository no longer maintains a parallel ARM JSON template or `.env.example` file.

The Bicep deployment provisions an Azure Container Registry, Linux App Service Plan, App Service, user-assigned managed identity, and an RBAC-enabled Azure Key Vault. The App Service pulls from ACR through managed identity; registry admin credentials are disabled. Key Vault has purge protection enabled and grants the application identity `Key Vault Secrets User` for future App Service Key Vault references.

### Deployment script

```bash
az login
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

Options are optional. Defaults come from [config/deployment.json](config/deployment.json):

```bash
./scripts/deploy.sh \
  --repository ninjapaw/ninjapaws-cloud-security-dojo \
  --app-display-name ninjapaws-cloud-security-dojo-github-actions
```

GitHub CLI is required only for the GitHub Actions setup portion. Install it automatically when needed with an interactive confirmation:

```bash
./scripts/deploy.sh --install-gh
```

For unattended use, accept the GitHub CLI package installation and other confirmations explicitly:

```bash
./scripts/deploy.sh --install-gh --yes
```

Infrastructure names are intentionally configured only in `config/deployment.json`; `deploy.sh` does not accept conflicting resource-name flags. It supplies the default location locally. In GitHub Actions, an `AZURE_LOCATION` organization or environment variable overrides that default and is passed to Bicep. `CONFIG_FILE` can select an alternate file for local Compose tooling only. `deploy.sh` and Bicep always use the committed `config/deployment.json` on the branch being deployed.

Each run checks whether the Entra app registration, service principal, GitHub OIDC federated credential, Azure role assignments (`Contributor`, `Role Based Access Control Administrator` on the resource group, `AcrPush` on the registry), and GitHub Actions workflow configuration already exist and match the expected configuration. Existing Azure resources are skipped; a federated credential whose subject has drifted is repaired in place. Nothing is duplicated or recreated by default. The script then creates the resource group if missing, deploys [infra/main.bicep](infra/main.bicep), builds the image in ACR, restarts App Service, and verifies the public `/health` endpoint.

When `--branch` is omitted, the wizard uses the current Git branch; it falls back to the repository default branch when that is available and to `main` only when it cannot detect either. The selected branch becomes the OIDC federated-credential subject. `main` uses the `prod` GitHub environment; every other branch, including `dev`, uses `dev`.

The wizard uses GitHub CLI (`gh`) to verify that the remote `deploy.yml` workflow is enabled and creates the `dev` and `prod` GitHub environments when missing. It first configures the three required OIDC bootstrap identifiers (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`) as organization secrets with selected-repository access; if organization policy or permissions prevent that, it falls back to repository secrets. These identifiers let GitHub obtain an Azure OIDC token before it can access Azure services. They are the only GitHub-held configuration required by this deployment and are never displayed. GitHub does not disclose secret values, so the script safely synchronizes them on each run to repair unknown drift without creating duplicate secrets. It pauses with a command to run manually only when GitHub CLI is unavailable, authentication/repository access is missing, an Azure permission is missing, or an automated action fails. No client secret is created or required.

After the first successful run, `deploy.yml` is configured to work going forward. Re-running `./scripts/deploy.sh` remains safe: it checks and repairs configuration, redeploys the Bicep infrastructure, and refreshes the training image without duplicating resources.

No other GitHub organization secrets or variables are required by the workflows in this repository.

#### Recreate or delete everything

```bash
# Delete and recreate the Entra app, federated credential, and resource group, then redeploy
./scripts/deploy.sh --recreate

# Permanently delete the resource group and Entra app registration, then exit
./scripts/deploy.sh --delete
```

Both `--recreate` and `--delete` are destructive and prompt for confirmation. Add `--yes` to skip the prompt for unattended/CI use. A recreation automatically synchronizes the repository Actions secrets with the new `AZURE_CLIENT_ID`.

### Manual Bicep deployment

```bash
az login
az deployment group create \
  --name ninjapaws-dojo-deployment \
  --resource-group "$(jq -r '.deployment.resourceGroup' config/deployment.json)" \
  --template-file infra/main.bicep
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

The GitHub Actions deployment is manual-only and requires the OIDC bootstrap identifiers `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. The wizard prefers organization secrets restricted to this repository, then falls back to repository secrets when organization sharing is not available. `deploy.yml` selects `prod` for `main` and `dev` for all other branches, then reads non-secret deployment configuration from [config/deployment.json](config/deployment.json). It builds and pushes through Azure CLI authentication and configures the App Service to use managed identity for ACR pulls. Automatic deployment is intentionally disabled so a bad configuration cannot fail every push.

### GitHub Actions bootstrap and environments

The wizard manages these organization secrets with selected-repository access when allowed, or repository secrets otherwise. It verifies names but never prints values:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the Microsoft Entra application used by GitHub Actions |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID containing the dojo resources |

Configure a federated credential on the Entra application for each branch that runs `deploy.yml`. The wizard creates the credential for its detected or explicitly supplied `--branch`. The value in `AZURE_CLIENT_ID` must be the application (client) ID from the same tenant as `AZURE_TENANT_ID`; otherwise Azure Login fails with `AADSTS700016`. Do not create or store an Azure client secret for this workflow. GitHub has no branch-scoped repository secrets; `dev` and `prod` environments provide the deployment boundary and can enforce approval rules.

The deployment identity needs permission to deploy the Bicep resources and create the managed-identity `AcrPull` assignment. Use a least-privilege custom role where possible; otherwise, the deployment identity needs Contributor plus permission to write role assignments at the deployment scope. The optional detection-workflow ACR publication also requires `AcrPush` on `ninjapawsdojo`.

### Azure cleanup

Training resources incur charges while running. Delete the resource group when finished:

```bash
az group delete --name NP-ninjapaws-dojo-CentralUS --yes --no-wait
```

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

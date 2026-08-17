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

```bash
az login
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

Optional arguments are resource group, location, registry name, and App Service name:

```bash
./scripts/deploy.sh ninjapaws-dojo eastus ninjapawsdojo ninjapaws-dojo-app
```

The script deploys [infra/main.bicep](infra/main.bicep), builds the image in ACR, restarts App Service, and fails if the public `/health` endpoint does not become healthy.

### Manual Bicep deployment

```bash
az login
az group create --name ninjapaws-dojo --location eastus
az deployment group create \
  --name ninjapaws-dojo-deployment \
  --resource-group ninjapaws-dojo \
  --template-file infra/main.bicep \
  --parameters \
    containerRegistryName=ninjapawsdojo \
    appServiceName=ninjapaws-dojo-app \
    location=eastus
```

### Verify Azure deployment

```bash
APP_HOST=$(az webapp show \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app \
  --query defaultHostName -o tsv)

curl "https://${APP_HOST}/health"
curl "https://${APP_HOST}/api/status"
az webapp log tail --resource-group ninjapaws-dojo --name ninjapaws-dojo-app
```

The GitHub Actions deployment requires `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` repository secrets for OIDC login. It builds and pushes through Azure CLI authentication and configures the App Service to use managed identity for ACR pulls.

### GitHub organization secrets

Add these organization secrets and allow the `ninjapaws-cloud-security-dojo` repository to use them:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the Microsoft Entra application used by GitHub Actions |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID containing the dojo resources |

Configure federated credentials on the Entra application for this GitHub repository and each deployment branch: `main` and `fix/cve-2026-42533`. Do not create or store an Azure client secret for this workflow.

The deployment identity needs permission to deploy the Bicep resources and create the managed-identity `AcrPull` assignment. Use a least-privilege custom role where possible; otherwise, the deployment identity needs Contributor plus permission to write role assignments at the deployment scope. The optional detection-workflow ACR publication also requires `AcrPush` on `ninjapawsdojo`.

### Azure cleanup

Training resources incur charges while running. Delete the resource group when finished:

```bash
az group delete --name ninjapaws-dojo --yes --no-wait
```

## Detection and remediation workflow

1. Build the default vulnerable image.
2. Analyze source with GitHub Advanced Security and scan trusted images with Defender for Cloud after pushing to ACR.
3. Create a remediation branch.
4. Change `ARG NGINX_VERSION=1.30.3` to `ARG NGINX_VERSION=1.30.4` or newer.
5. Set `VULNERABILITY_STATUS=remediated` for the patched training image.
6. Build and test the patched image.
7. Open a pull request and review the remediation workflow results.
8. Merge only after the actual package version, runtime status, endpoints, and security scan pass.

The relevant workflows are:

- `.github/workflows/detect-vulnerability.yml`: builds and scans the default image.
- `.github/workflows/validate-remediation.yml`: scans the PR image, checks the actual NGINX version, tests endpoints, and verifies remediated runtime state.
- `.github/workflows/deploy.yml`: provisions or updates Azure, pushes the image, and runs a health check.

### Security integrations

- **GitHub Advanced Security:** enable code scanning for the repository. The detection workflow runs CodeQL for JavaScript source analysis.
- **Microsoft Defender for DevOps:** in the Azure Defender for Cloud environment settings, connect the GitHub organization/repository as a DevOps connector. Defender for DevOps then evaluates the connected repository and reports findings in Azure.
- **Microsoft Defender for Cloud:** configure the Azure OIDC secrets listed above and grant the federated identity `AcrPush` on the registry. On trusted pushes, the detection workflow publishes the image to ACR; Defender for Cloud scans the pushed image and reports container findings in Azure.

The GitHub workflow does not attempt to replace Azure onboarding. GitHub permissions, the Azure connector, Defender plans, and ACR scanning must be enabled in their respective services.

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

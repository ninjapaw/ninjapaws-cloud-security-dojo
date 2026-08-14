# 🏗️ Azure Infrastructure Deployment

This guide explains how to deploy the Ninja Paws Cloud Security Dojo to Azure.

## 📋 Prerequisites

- Azure Subscription (free tier works)
- Azure CLI installed: [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Docker (for local testing)
- Git

## 🚀 Quick Deploy

### Option 1: Using the Deployment Script (Recommended)

```bash
# Make script executable
chmod +x scripts/deploy.sh

# Run the deployment script
./scripts/deploy.sh

# Or with custom parameters
./scripts/deploy.sh ninjapaws-dojo eastus ninjapawsdojo ninjapaws-dojo-app
```

### Option 2: Manual Deployment with Azure CLI

```bash
# 1. Login to Azure
az login

# 2. Create resource group
az group create \
  --name ninjapaws-dojo \
  --location eastus

# 3. Deploy Bicep template
az deployment group create \
  --name ninjapaws-dojo-deployment \
  --resource-group ninjapaws-dojo \
  --template-file infra/main.bicep \
  --parameters \
    containerRegistryName=ninjapawsdojo \
    appServiceName=ninjapaws-dojo-app \
    location=eastus
```

## 🏗️ Infrastructure Components

### 1. Azure Container Registry (ACR)

- **SKU:** Basic
- **Purpose:** Store Docker images for deployment
- **Cost:** ~$5/month
- **Enabled Features:**
  - Admin user disabled (Managed Identity authentication)
  - Image vulnerability scanning (Microsoft Defender for Cloud)

### 2. Azure App Service Plan

- **OS:** Linux
- **Type:** Container
- **SKU:** B1 (Basic) - 1 core, 1.75 GB RAM
- **Cost:** ~$15/month
- **Scaling:** Can be upgraded to higher tiers

### 3. Azure App Service

- **Runtime:** Docker Container
- **Health Check:** `/health` endpoint
- **Port:** 3000 (Node.js) + 80 (NGINX)
- **Monitoring:** Application Insights integration available
- **Managed Identity:** User-assigned for ACR access

### 4. Managed Identity

- **Type:** User-assigned
- **Purpose:** Authenticate App Service to ACR
- **Permissions:** AcrPull role on Container Registry

## 📊 Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│              GitHub Repository                      │
│  (Code + GitHub Actions Workflows)                 │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│         GitHub Actions Workflows                    │
│  - detect-vulnerability.yml                        │
│  - deploy.yml                                      │
│  - validate-remediation.yml                        │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│    Azure Container Registry (ninjapawsdojo)        │
│  - Stores Docker images                            │
│  - Microsoft Defender scans images                 │
│  - Managed by GitHub Actions                       │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│         Azure App Service                           │
│  (ninjapaws-dojo-app)                              │
│  - Runs Docker container                           │
│  - Managed Identity authentication                 │
│  - Public HTTPS endpoint                           │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│       Microsoft Defender for Cloud                  │
│  - Monitors container registry                     │
│  - Tracks deployed images                          │
│  - Generates security alerts                       │
└─────────────────────────────────────────────────────┘
```

## 🔐 Security Configuration

### Authentication

- ✅ No container registry admin account
- ✅ Managed Identity for App Service
- ✅ Role-Based Access Control (RBAC)
- ✅ AcrPull role assigned to App Service

### Network

- ✅ HTTPS only enforced
- ✅ TLS 1.2 minimum
- ✅ Public endpoint for training (not production)

### Monitoring

- ✅ Application Insights available
- ✅ Microsoft Defender for Cloud scanning
- ✅ App Service diagnostics enabled
- ✅ Health checks configured

## 📝 Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| location | eastus | Azure region |
| containerRegistryName | ninjapawsdojo | ACR name (must be globally unique) |
| appServiceName | ninjapaws-dojo-app | App Service name |
| appServicePlanName | ninjapaws-dojo-plan | App Service Plan name |
| environment | training | Environment name |

## 🐳 Build and Push Docker Image

### After deployment, push your image to ACR:

```bash
# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show \
  --resource-group ninjapaws-dojo \
  --name ninjapawsdojo \
  --query loginServer \
  --output tsv)

# Login to ACR
az acr login --name ninjapawsdojo

# Build image in ACR
az acr build \
  --registry ninjapawsdojo \
  --image ninjapaws-dojo:1.30.3 \
  --image ninjapaws-dojo:vulnerable \
  --image ninjapaws-dojo:latest \
  .

# Or build locally and push
docker build -t $ACR_LOGIN_SERVER/ninjapaws-dojo:latest .
docker push $ACR_LOGIN_SERVER/ninjapaws-dojo:latest
```

## 🧪 Verify Deployment

### Check App Service Status

```bash
# Get App Service URL
APP_URL=$(az webapp show \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app \
  --query defaultHostName \
  --output tsv)

echo "App Service URL: https://$APP_URL"

# Test endpoints
curl https://$APP_URL/
curl https://$APP_URL/health
curl https://$APP_URL/api/status
```

### View Logs

```bash
# Stream App Service logs
az webapp log tail \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app

# Or view in portal
az webapp browse \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app
```

## 🛡️ Microsoft Defender for Cloud

### Enable Image Scanning

1. Go to Azure Portal
2. Search for "Defender for Cloud"
3. Select "Container registries"
4. Ensure your ACR is listed and scanning is enabled
5. View vulnerability reports

### Interpret Findings

When a vulnerable image is pushed:

- **Severity:** Critical, High, Medium, Low
- **CVE ID:** e.g., CVE-2026-42533
- **Component:** e.g., NGINX 1.30.3
- **Recommendation:** Update to patched version

## 💰 Cost Optimization

### Estimated Monthly Costs

| Service | SKU | Cost |
|---------|-----|------|
| ACR | Basic | ~$5 |
| App Service Plan | B1 | ~$15 |
| **Total** | | **~$20** |

### Ways to Reduce Costs

- Use Azure Free Trial ($200 credit for 30 days)
- Delete resources when not using
- Auto-scale based on traffic
- Use B1 plan (smallest for containers)

### Delete Resources

```bash
# Delete entire resource group
az group delete \
  --name ninjapaws-dojo \
  --yes --no-wait

# Or delete individual resources
az acr delete --resource-group ninjapaws-dojo --name ninjapawsdojo
az webapp delete --resource-group ninjapaws-dojo --name ninjapaws-dojo-app
az appservice plan delete --resource-group ninjapaws-dojo --name ninjapaws-dojo-plan
```

## 🔄 GitHub Actions Integration

### Configure GitHub Secrets

For automatic deployment from GitHub Actions:

```bash
# Get subscription info
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# Create service principal for GitHub
az ad sp create-for-rbac \
  --name github-ninjapaws-dojo \
  --role Contributor \
  --scopes /subscriptions/$SUBSCRIPTION_ID

# Add to GitHub Secrets:
# - AZURE_SUBSCRIPTION_ID
# - AZURE_TENANT_ID
# - AZURE_CLIENT_ID
```

### Update Workflow Variables

In `.github/workflows/deploy.yml`:

```yaml
env:
  REGISTRY: ninjapawsdojo.azurecr.io
  IMAGE_NAME: ninjapaws-dojo
  RESOURCE_GROUP: ninjapaws-dojo
  APP_SERVICE_NAME: ninjapaws-dojo-app
```

## 🚨 Troubleshooting

### App Service Won't Start

```bash
# Check container logs
az webapp log tail \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app

# Restart app service
az webapp restart \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app
```

### Image Won't Pull

```bash
# Verify ACR authentication
az acr login --name ninjapawsdojo

# Check if image exists
az acr repository list --name ninjapawsdojo

# View ACR build history
az acr build-task list --registry ninjapawsdojo
```

### Health Check Failing

```bash
# SSH into container
az webapp create-remote-connection \
  --resource-group ninjapaws-dojo \
  --name ninjapaws-dojo-app

# Or check application inside container
docker exec <container-id> curl localhost:3000/health
```

## 📚 Additional Resources

- [Azure CLI Documentation](https://learn.microsoft.com/en-us/cli/azure/)
- [Bicep Language Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Container Registry Documentation](https://learn.microsoft.com/en-us/azure/container-registry/)
- [Azure App Service Documentation](https://learn.microsoft.com/en-us/azure/app-service/)
- [Microsoft Defender for Cloud](https://learn.microsoft.com/en-us/azure/defender-for-cloud/)

## 🐾 Need Help?

- Check deployment logs: `az deployment group list --resource-group ninjapaws-dojo`
- View Azure Portal for detailed error messages
- Review GitHub Actions workflow logs
- Check Microsoft Defender for Cloud alerts

---

**Happy deploying! 🚀**

#!/bin/bash

# Ninja Paws Cloud Security Dojo - Azure Deployment Script
# Deploys the complete training environment to Azure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESOURCE_GROUP=${1:-ninjapaws-dojo}
LOCATION=${2:-eastus}
REGISTRY_NAME=${3:-ninjapawsdojo}
ACR_NAME=${REGISTRY_NAME//-/}
APP_SERVICE_NAME=${4:-ninjapaws-dojo-app}

echo -e "${BLUE}🥷 Ninja Paws Cloud Security Dojo - Azure Deployment${NC}"
echo -e "${BLUE}🏗️  Infrastructure as Code Deployment${NC}"
echo ""

if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI is not installed${NC}"
    echo "Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠️  jq is not installed; falling back to grep-based output parsing${NC}"
fi

if ! az account show >/dev/null 2>&1; then
    echo -e "${YELLOW}Authenticating to Azure...${NC}"
    az login --use-device-code
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo -e "${GREEN}✅ Authenticated to subscription: $SUBSCRIPTION_ID${NC}"
echo ""

echo -e "${YELLOW}Creating resource group: $RESOURCE_GROUP${NC}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

echo -e "${GREEN}✅ Resource group ready${NC}"
echo ""

echo -e "${YELLOW}Deploying infrastructure with Bicep...${NC}"
echo "  - Container Registry: $REGISTRY_NAME"
echo "  - App Service: $APP_SERVICE_NAME"
echo "  - Location: $LOCATION"
echo "  - Resource Group: $RESOURCE_GROUP"
echo ""

DEPLOYMENT_NAME="ninjapaws-dojo-$(date +%s)"

az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file infra/main.bicep \
    --parameters \
        containerRegistryName="$ACR_NAME" \
        appServiceName="$APP_SERVICE_NAME" \
        location="$LOCATION" \
    --output json > deployment-output.json

echo -e "${GREEN}✅ Infrastructure deployed successfully${NC}"
echo ""

echo -e "${YELLOW}Deployment Outputs:${NC}"
if command -v jq &> /dev/null; then
    REGISTRY_LOGIN=$(jq -r '.properties.outputs.containerRegistryLoginServer.value // empty' deployment-output.json)
    APP_URL=$(jq -r '.properties.outputs.appServiceUrl.value // empty' deployment-output.json)
else
    REGISTRY_LOGIN=$(grep -oP '"containerRegistryLoginServer"\s*:\s*{\s*"value"\s*:\s*"\K[^"]+' deployment-output.json || true)
    APP_URL=$(grep -oP '"appServiceUrl"\s*:\s*{\s*"value"\s*:\s*"\K[^"]+' deployment-output.json || true)
fi

echo -e "  ${BLUE}Container Registry:${NC} ${REGISTRY_LOGIN:-$ACR_NAME.azurecr.io}"
echo -e "  ${BLUE}App Service URL:${NC} ${APP_URL:-https://${APP_SERVICE_NAME}.azurewebsites.net}"
echo ""

echo -e "${YELLOW}Building Docker image...${NC}"
IMAGE_TAG="1.30.3"
IMAGE_REPO="ninjapaws-dojo"

az acr build \
    --registry "$ACR_NAME" \
    --image "${IMAGE_REPO}:${IMAGE_TAG}" \
    --image "${IMAGE_REPO}:vulnerable" \
    --image "${IMAGE_REPO}:latest" \
    .

echo -e "${GREEN}✅ Image built and pushed to ACR${NC}"
echo ""

APP_URL=${APP_URL:-https://${APP_SERVICE_NAME}.azurewebsites.net}

az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" >/dev/null

echo -e "${YELLOW}Waiting for App Service to update...${NC}"
HEALTHY=false
for i in $(seq 1 12); do
    if curl -fsS "$APP_URL/health" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Application is healthy${NC}"
        HEALTHY=true
        break
    fi
    echo "  Attempt $i/12 - Waiting for application to start..."
    sleep 10
done

if [[ "$HEALTHY" != true ]]; then
    echo -e "${RED}❌ Application health check failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo ""
echo -e "${BLUE}🎯 Next Steps:${NC}"
echo "  1. Visit your application: $APP_URL"
echo "  2. Check container registry: az acr repository list --name $ACR_NAME"
echo "  3. Monitor in Azure Portal: Defender for Cloud > Container registries"
echo "  4. Create remediation PR: Update Dockerfile NGINX 1.30.3 → 1.30.4"
echo ""
echo -e "${BLUE}📚 Resources:${NC}"
echo "  - GitHub: https://github.com/ninjapaw/ninjapaws-cloud-security-dojo"
echo "  - Azure Portal: https://portal.azure.com"
echo "  - Defender for Cloud: https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityCentermenu"
echo ""
echo -e "${BLUE}🐾 Ninja Paws | Cloud Security Training${NC}"

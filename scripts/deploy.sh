#!/bin/bash

# Ninja Paws Cloud Security Dojo - Azure Deployment Script
# Deploys the complete training environment to Azure

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_GROUP=${1:-ninjapaws-dojo}
LOCATION=${2:-eastus}
REGISTRY_NAME=${3:-ninjapawsdojo}
APP_SERVICE_NAME=${4:-ninjapaws-dojo-app}

echo -e "${BLUE}🥷 Ninja Paws Cloud Security Dojo - Azure Deployment${NC}"
echo -e "${BLUE}🏗️  Infrastructure as Code Deployment${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI is not installed${NC}"
    echo "Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠️  jq is not installed (optional for formatted output)${NC}"
fi

echo -e "${GREEN}✅ Prerequisites met${NC}"
echo ""

# Login to Azure
echo -e "${YELLOW}Authenticating to Azure...${NC}"
az login --use-device-code

# Get current subscription
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo -e "${GREEN}✅ Authenticated to subscription: $SUBSCRIPTION_ID${NC}"
echo ""

# Create resource group
echo -e "${YELLOW}Creating resource group: $RESOURCE_GROUP${NC}"
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    || true

echo -e "${GREEN}✅ Resource group ready${NC}"
echo ""

# Deploy infrastructure
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
        containerRegistryName="$REGISTRY_NAME" \
        appServiceName="$APP_SERVICE_NAME" \
        location="$LOCATION" \
    --output json > deployment-output.json

echo -e "${GREEN}✅ Infrastructure deployed successfully${NC}"
echo ""

# Extract outputs
echo -e "${YELLOW}Deployment Outputs:${NC}"

if command -v jq &> /dev/null; then
    REGISTRY_LOGIN=$(jq -r '.properties.outputs.containerRegistryLoginServer.value' deployment-output.json)
    APP_URL=$(jq -r '.properties.outputs.appServiceUrl.value' deployment-output.json)
else
    REGISTRY_LOGIN=$(grep -oP '"containerRegistryLoginServer":\s*{\s*"value":\s*"\K[^"]+' deployment-output.json)
    APP_URL=$(grep -oP '"appServiceUrl":\s*{\s*"value":\s*"\K[^"]+' deployment-output.json)
fi

echo -e "  ${BLUE}Container Registry:${NC} $REGISTRY_LOGIN"
echo -e "  ${BLUE}App Service URL:${NC} $APP_URL"
echo ""

# Build and push initial image
echo -e "${YELLOW}Building Docker image...${NC}"

# Login to ACR
az acr login --name "$REGISTRY_NAME"

# Build image in ACR
echo -e "${YELLOW}Building image in Azure Container Registry...${NC}"
az acr build \
    --registry "$REGISTRY_NAME" \
    --image "$REGISTRY_NAME.azurecr.io/ninjapaws-dojo:1.30.3" \
    --image "$REGISTRY_NAME.azurecr.io/ninjapaws-dojo:vulnerable" \
    --image "$REGISTRY_NAME.azurecr.io/ninjapaws-dojo:latest" \
    .

echo -e "${GREEN}✅ Image built and pushed to ACR${NC}"
echo ""

# Wait for App Service to update
echo -e "${YELLOW}Waiting for App Service to update...${NC}"
sleep 30

# Test health endpoint
echo -e "${YELLOW}Testing application health...${NC}"
for i in {1..10}; do
    if curl -sf "$APP_URL/health" > /dev/null; then
        echo -e "${GREEN}✅ Application is healthy${NC}"
        break
    else
        echo "  Attempt $i/10 - Waiting for application to start..."
        sleep 10
    fi
done

echo ""
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo ""
echo -e "${BLUE}🎯 Next Steps:${NC}"
echo "  1. Visit your application: $APP_URL"
echo "  2. Check container registry: az acr repository list --name $REGISTRY_NAME"
echo "  3. Monitor in Azure Portal: Defender for Cloud > Container registries"
echo "  4. Create remediation PR: Update Dockerfile NGINX 1.30.3 → 1.30.4"
echo ""
echo -e "${BLUE}📚 Resources:${NC}"
echo "  - GitHub: https://github.com/ninjapaw/ninjapaws-cloud-security-dojo"
echo "  - Azure Portal: https://portal.azure.com"
echo "  - Defender for Cloud: https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityCentermenu"
echo ""
echo -e "${BLUE}🐾 Ninja Paws Consulting | Cloud Security Training${NC}"

#!/usr/bin/env bash

# Configure Azure and GitHub OIDC prerequisites for the Ninja Paws dojo.
# This script does not create client secrets or modify GitHub organization secrets.

set -euo pipefail

RESOURCE_GROUP=${1:-NP-ninjapaws-dojo-CentralUS}
LOCATION=${2:-centralus}
REGISTRY_NAME=${3:-ninjapawsdojo}
APP_SERVICE_NAME=${4:-ninjapaws-dojo-app}
REPOSITORY=${5:-ninjapaw/ninjapaws-cloud-security-dojo}
APP_DISPLAY_NAME=${6:-ninjapaws-cloud-security-dojo-github-actions}
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is required." >&2
    exit 1
  }
}

require_command az

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi
az account set --subscription "$SUBSCRIPTION_ID"

TENANT_ID=$(az account show --query tenantId -o tsv)
DEPLOYMENT_OBJECT_ID=$(az ad sp list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].id' -o tsv)

if [[ -z "$DEPLOYMENT_OBJECT_ID" ]]; then
  APP_CLIENT_ID=$(az ad app create \
    --display-name "$APP_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  DEPLOYMENT_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query id -o tsv)
  az ad sp create --id "$APP_CLIENT_ID" >/dev/null
else
  APP_CLIENT_ID=$(az ad sp show --id "$DEPLOYMENT_OBJECT_ID" --query appId -o tsv)
fi

SERVICE_PRINCIPAL_OBJECT_ID=$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv)
APP_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query id -o tsv)

FEDERATED_CREDENTIAL_NAME=github-main
if ! az ad app federated-credential list --id "$APP_OBJECT_ID" --query "[?name=='$FEDERATED_CREDENTIAL_NAME'] | length(@)" -o tsv | grep -q '^1$'; then
  az ad app federated-credential create \
    --id "$APP_OBJECT_ID" \
    --parameters "{\"name\":\"$FEDERATED_CREDENTIAL_NAME\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"repo:$REPOSITORY:ref:refs/heads/main\",\"audiences\":[\"api://AzureADTokenExchange\"],\"description\":\"GitHub Actions OIDC for main\"}" \
    >/dev/null
fi

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

RESOURCE_GROUP_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
ACR_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$REGISTRY_NAME"

ensure_role() {
  local role="$1"
  local scope="$2"
  if ! az role assignment list \
    --assignee-object-id "$SERVICE_PRINCIPAL_OBJECT_ID" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role'] | length(@)" -o tsv | grep -q '^1$'; then
    az role assignment create \
      --assignee-object-id "$SERVICE_PRINCIPAL_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" \
      >/dev/null
  fi
}

# Required before infrastructure deployment so Bicep can create the App Service
# managed identity's AcrPull role assignment.
ensure_role Contributor "$RESOURCE_GROUP_SCOPE"
ensure_role "Role Based Access Control Administrator" "$RESOURCE_GROUP_SCOPE"

az deployment group create \
  --name "ninjapaws-oidc-$(date +%s)" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters \
    location="$LOCATION" \
    containerRegistryName="$REGISTRY_NAME" \
    appServiceName="$APP_SERVICE_NAME" \
  --output table

# The registry exists after Bicep completes, so assign image-push access now.
ensure_role AcrPush "$ACR_SCOPE"

echo
echo "Azure setup complete. Add these organization secrets in GitHub:"
echo "AZURE_CLIENT_ID=$APP_CLIENT_ID"
echo "AZURE_TENANT_ID=$TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo
echo "OIDC subject configured: repo:$REPOSITORY:ref:refs/heads/main"
echo "Azure resource group: $RESOURCE_GROUP"
echo "Azure location: $LOCATION"
echo "No client secret was created."

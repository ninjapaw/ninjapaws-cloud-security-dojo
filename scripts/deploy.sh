#!/bin/bash

# Ninja Paws Cloud Security Dojo - Azure Deployment Script
#
# Idempotent by default: checks every resource (Entra app registration,
# service principal, GitHub OIDC federated credential, Azure role
# assignments, resource group, infrastructure, container image) and only
# creates or repairs what is missing or drifted. Never duplicates existing
# resources unless --recreate is passed.
#
# Usage:
#   ./scripts/deploy.sh [options]
#
# Options:
#   --repository OWNER/REPO     GitHub repository (default: ninjapaw/ninjapaws-cloud-security-dojo)
#   --app-display-name NAME     Entra app registration display name
#   --branch NAME                GitHub branch for OIDC federation (default: current branch)
#   --recreate                   Delete and recreate the Entra app, service principal,
#                                 federated credential, and resource group before deploying
#   --delete                     Delete all resources created by this script and exit
#   --yes                        Skip confirmation prompts (required for --recreate/--delete in CI)
#   -h, --help                   Show this help and exit

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/config.sh"
if [[ "$CONFIG_FILE" != "$REPOSITORY_ROOT/config.json" ]]; then
    echo "deploy.sh requires the committed repository config: $REPOSITORY_ROOT/config.json" >&2
    exit 2
fi
load_deployment_config

RESOURCE_GROUP=$CONFIG_RESOURCE_GROUP
LOCATION=$CONFIG_LOCATION
REGISTRY_NAME=$CONFIG_REGISTRY_NAME
APP_SERVICE_NAME=$CONFIG_APP_SERVICE_NAME
KEY_VAULT_NAME=$CONFIG_KEY_VAULT_NAME
IMAGE_REPO=$CONFIG_IMAGE_NAME
IMAGE_TAG=$CONFIG_IMAGE_TAG
REPOSITORY=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)
REPOSITORY=${REPOSITORY:-ninjapaw/ninjapaws-cloud-security-dojo}
APP_DISPLAY_NAME=ninjapaws-cloud-security-dojo-github-actions
BRANCH=
RECREATE=false
DELETE=false
ASSUME_YES=false

print_help() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | grep '^#' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repository) REPOSITORY="$2"; shift 2 ;;
        --app-display-name) APP_DISPLAY_NAME="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --recreate) RECREATE=true; shift ;;
        --delete) DELETE=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; print_help; exit 2 ;;
    esac
done

ACR_NAME=${REGISTRY_NAME//-/}

detect_branch() {
    local detected_branch
    detected_branch=$(git branch --show-current 2>/dev/null || true)
    if [[ -z "$detected_branch" ]]; then
        detected_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    fi
    if [[ -z "$detected_branch" ]]; then
        detected_branch=main
        echo -e "${YELLOW}⚠️  Could not detect a Git branch; using main. Pass --branch to override.${NC}"
    fi
    BRANCH="$detected_branch"
}

if [[ -z "$BRANCH" ]]; then
    detect_branch
fi

GITHUB_ENVIRONMENT=$(github_environment_for_branch "$BRANCH")

confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Ensures a resource exists: checks first, creates if missing. If creation
# fails (e.g. insufficient permissions), pauses with the manual command and
# re-checks after each keypress until it exists or the user quits.
ensure_resource() {
    local description="$1"
    local manual_command="$2"
    local check_fn="$3"
    local create_fn="$4"

    if "$check_fn"; then
        echo "  Already exists, skipping creation."
        return 0
    fi

    echo "  Not found, creating..."
    while true; do
        if "$create_fn"; then
            return 0
        fi
        echo ""
        echo -e "${RED}⚠️  Manual action required: $description${NC}"
        echo -e "${YELLOW}Run this yourself, or ask an admin to, then continue:${NC}"
        echo ""
        echo "  $manual_command"
        echo ""
        read -n 1 -r -s -p "Press any key to re-check, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
            exit 1
        fi
        if "$check_fn"; then
            echo -e "${GREEN}✅ Found, continuing...${NC}"
            return 0
        fi
        echo -e "${YELLOW}Still not found, retrying...${NC}"
    done
}

# Retries a one-shot action (e.g. a deployment or build) that has no
# separate existence check. On failure, pauses with the manual command and
# retries after each keypress until it succeeds or the user quits.
run_or_pause() {
    local description="$1"
    local manual_command="$2"
    local action_fn="$3"

    while ! "$action_fn"; do
        echo ""
        echo -e "${RED}⚠️  Automatic step failed: $description${NC}"
        echo -e "${YELLOW}Run this yourself, or ask an admin to, then retry:${NC}"
        echo ""
        echo "  $manual_command"
        echo ""
        read -n 1 -r -s -p "Press any key to retry, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
            exit 1
        fi
    done
}

# Waits for a prerequisite that cannot be repaired safely by this script.
wait_for_prerequisite() {
    local description="$1"
    local manual_command="$2"
    local check_fn="$3"

    while ! "$check_fn"; do
        echo ""
        echo -e "${RED}⚠️  Manual action required: $description${NC}"
        echo -e "${YELLOW}Run this yourself, or ask an administrator to, then continue:${NC}"
        echo ""
        echo "  $manual_command"
        echo ""
        read -n 1 -r -s -p "Press any key to re-check, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
            exit 1
        fi
    done
}

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
TENANT_ID=$(az account show --query tenantId -o tsv)
echo -e "${GREEN}✅ Authenticated to subscription: $SUBSCRIPTION_ID${NC}"
echo "  Shared configuration: $CONFIG_FILE"
echo "  Branch: $BRANCH | GitHub environment: $GITHUB_ENVIRONMENT"
echo ""

RESOURCE_GROUP_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"
ACR_SCOPE="$RESOURCE_GROUP_SCOPE/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
FEDERATED_CREDENTIAL_NAME="github-${BRANCH//[^[:alnum:]_-]/-}"

# --- Delete mode: tear down everything this script manages, then exit ---
if [[ "$DELETE" == true ]]; then
    echo -e "${RED}⚠️  This will permanently delete:${NC}"
    echo "  - Resource group: $RESOURCE_GROUP (and every resource inside it)"
    echo "  - Entra app registration: $APP_DISPLAY_NAME (and its service principal)"
    echo ""
    if ! confirm "Type y to confirm deletion of the above"; then
        echo "Aborted. Nothing was deleted."
        exit 1
    fi

    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        echo -e "${YELLOW}Deleting resource group: $RESOURCE_GROUP${NC}"
        az group delete --name "$RESOURCE_GROUP" --yes
        echo -e "${GREEN}✅ Resource group deleted${NC}"
    else
        echo "Resource group '$RESOURCE_GROUP' does not exist, skipping."
    fi

    EXISTING_APP_ID=$(az ad app list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].appId' -o tsv)
    if [[ -n "$EXISTING_APP_ID" ]]; then
        echo -e "${YELLOW}Deleting Entra app registration: $APP_DISPLAY_NAME${NC}"
        az ad app delete --id "$EXISTING_APP_ID"
        echo -e "${GREEN}✅ App registration deleted (service principal removed with it)${NC}"
    else
        echo "App registration '$APP_DISPLAY_NAME' does not exist, skipping."
    fi

    echo ""
    echo -e "${GREEN}✅ Delete complete.${NC}"
    exit 0
fi

# --- Recreate mode: remove existing app registration, credential, and resource group first ---
if [[ "$RECREATE" == true ]]; then
    echo -e "${RED}⚠️  --recreate will delete and recreate:${NC}"
    echo "  - Entra app registration: $APP_DISPLAY_NAME"
    echo "  - Resource group: $RESOURCE_GROUP (and every resource inside it)"
    echo ""
    if ! confirm "Type y to confirm recreation"; then
        echo "Aborted. Nothing was changed."
        exit 1
    fi

    EXISTING_APP_ID=$(az ad app list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].appId' -o tsv)
    if [[ -n "$EXISTING_APP_ID" ]]; then
        echo -e "${YELLOW}Deleting existing app registration for recreation...${NC}"
        az ad app delete --id "$EXISTING_APP_ID"
    fi

    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        echo -e "${YELLOW}Deleting existing resource group for recreation...${NC}"
        az group delete --name "$RESOURCE_GROUP" --yes
    fi
    echo -e "${GREEN}✅ Ready to recreate${NC}"
    echo ""
fi

# --- Entra app registration: check, skip if present, create only if missing ---
check_app_registration() {
    APP_CLIENT_ID=$(az ad app list --filter "displayName eq '$APP_DISPLAY_NAME'" --query '[0].appId' -o tsv)
    [[ -n "$APP_CLIENT_ID" ]]
}
create_app_registration() {
    local output
    if output=$(az ad app create \
            --display-name "$APP_DISPLAY_NAME" \
            --sign-in-audience AzureADMyOrg \
            --query appId -o tsv 2>/tmp/ninjapaws-app.err); then
        APP_CLIENT_ID="$output"
        return 0
    fi
    cat /tmp/ninjapaws-app.err >&2
    return 1
}

echo -e "${YELLOW}Checking Entra app registration: $APP_DISPLAY_NAME${NC}"
ensure_resource \
    "Create the Entra app registration '$APP_DISPLAY_NAME' (requires the Application Developer role or higher in Entra ID)" \
    "az ad app create --display-name \"$APP_DISPLAY_NAME\" --sign-in-audience AzureADMyOrg" \
    check_app_registration \
    create_app_registration
APP_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query id -o tsv)

check_service_principal() {
    az ad sp show --id "$APP_CLIENT_ID" >/dev/null 2>&1
}
create_service_principal() {
    az ad sp create --id "$APP_CLIENT_ID" >/dev/null 2>/tmp/ninjapaws-sp.err && return 0
    cat /tmp/ninjapaws-sp.err >&2
    return 1
}
ensure_resource \
    "Create the service principal for app '$APP_CLIENT_ID' (requires Application Administrator or Cloud Application Administrator)" \
    "az ad sp create --id $APP_CLIENT_ID" \
    check_service_principal \
    create_service_principal
SERVICE_PRINCIPAL_OBJECT_ID=$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv)
echo -e "${GREEN}✅ App registration ready${NC}"
echo ""

# --- GitHub OIDC federated credential: check subject, repair if drifted, create if missing ---
echo -e "${YELLOW}Checking GitHub OIDC federated credential for branch: $BRANCH${NC}"
EXPECTED_SUBJECT="repo:$REPOSITORY:ref:refs/heads/$BRANCH"
FEDERATED_CREDENTIAL_PARAMS="{\"name\":\"$FEDERATED_CREDENTIAL_NAME\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$EXPECTED_SUBJECT\",\"audiences\":[\"api://AzureADTokenExchange\"],\"description\":\"GitHub Actions OIDC for $BRANCH\"}"

while true; do
    EXISTING_SUBJECT=$(az ad app federated-credential list --id "$APP_OBJECT_ID" \
        --query "[?name=='$FEDERATED_CREDENTIAL_NAME'].subject | [0]" -o tsv 2>/dev/null)

    if [[ "$EXISTING_SUBJECT" == "$EXPECTED_SUBJECT" ]]; then
        echo "  Already exists with correct subject, skipping."
        break
    fi

    if [[ -z "$EXISTING_SUBJECT" ]]; then
        echo "  Not found, creating..."
        if az ad app federated-credential create --id "$APP_OBJECT_ID" \
                --parameters "$FEDERATED_CREDENTIAL_PARAMS" >/dev/null 2>/tmp/ninjapaws-fc.err; then
            break
        fi
        MANUAL_FC_CMD="az ad app federated-credential create --id $APP_OBJECT_ID --parameters '$FEDERATED_CREDENTIAL_PARAMS'"
    else
        echo "  Found with drifted subject ('$EXISTING_SUBJECT'), repairing..."
        if az ad app federated-credential update --id "$APP_OBJECT_ID" \
                --federated-credential-id "$FEDERATED_CREDENTIAL_NAME" \
                --parameters "$FEDERATED_CREDENTIAL_PARAMS" >/dev/null 2>/tmp/ninjapaws-fc.err; then
            break
        fi
        MANUAL_FC_CMD="az ad app federated-credential update --id $APP_OBJECT_ID --federated-credential-id $FEDERATED_CREDENTIAL_NAME --parameters '$FEDERATED_CREDENTIAL_PARAMS'"
    fi

    cat /tmp/ninjapaws-fc.err >&2
    echo ""
    echo -e "${RED}⚠️  Manual action required: configure the GitHub OIDC federated credential (requires Application Developer role or higher)${NC}"
    echo -e "${YELLOW}Run this yourself, or ask an Azure AD admin to, then continue:${NC}"
    echo ""
    echo "  $MANUAL_FC_CMD"
    echo ""
    read -n 1 -r -s -p "Press any key to re-check, or 'q' to quit: " key
    echo ""
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
        echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
        exit 1
    fi
done
echo -e "${GREEN}✅ GitHub OIDC federation ready${NC}"
echo ""

# --- Resource group: check, create only if missing ---
check_resource_group() {
    az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1
}
create_resource_group() {
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null 2>/tmp/ninjapaws-rg.err && return 0
    cat /tmp/ninjapaws-rg.err >&2
    return 1
}
echo -e "${YELLOW}Checking resource group: $RESOURCE_GROUP${NC}"
ensure_resource \
    "Create the resource group '$RESOURCE_GROUP' in '$LOCATION' (may be blocked by Azure Policy or missing permissions)" \
    "az group create --name $RESOURCE_GROUP --location $LOCATION" \
    check_resource_group \
    create_resource_group
echo -e "${GREEN}✅ Resource group ready${NC}"
echo ""

# --- Azure role assignments: check, skip if present, create only if missing ---
ensure_role() {
    local role="$1"
    local scope="$2"
    while true; do
        if az role assignment list \
                --assignee-object-id "$SERVICE_PRINCIPAL_OBJECT_ID" \
                --scope "$scope" \
                --query "[?roleDefinitionName=='$role'] | length(@)" -o tsv 2>/dev/null | grep -q '^1$'; then
            echo "  Role '$role' already assigned, skipping."
            return 0
        fi
        echo "  Assigning role '$role'..."
        if az role assignment create \
                --assignee-object-id "$SERVICE_PRINCIPAL_OBJECT_ID" \
                --assignee-principal-type ServicePrincipal \
                --role "$role" \
                --scope "$scope" \
                >/dev/null 2>/tmp/ninjapaws-role.err; then
            return 0
        fi
        cat /tmp/ninjapaws-role.err >&2
        echo ""
        echo -e "${RED}⚠️  Manual action required: assign role '$role' (requires Owner or User Access Administrator)${NC}"
        echo -e "${YELLOW}Run this yourself, or ask an admin to, then continue:${NC}"
        echo ""
        echo "  az role assignment create --assignee-object-id $SERVICE_PRINCIPAL_OBJECT_ID --assignee-principal-type ServicePrincipal --role \"$role\" --scope $scope"
        echo ""
        read -n 1 -r -s -p "Press any key to re-check, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
            exit 1
        fi
    done
}

echo -e "${YELLOW}Checking Azure role assignments for GitHub Actions...${NC}"
ensure_role Contributor "$RESOURCE_GROUP_SCOPE"
ensure_role "Role Based Access Control Administrator" "$RESOURCE_GROUP_SCOPE"
echo -e "${GREEN}✅ Deployment roles ready${NC}"
echo ""

echo -e "${YELLOW}Deploying infrastructure with Bicep...${NC}"
echo "  - Container Registry: $REGISTRY_NAME"
echo "  - App Service: $APP_SERVICE_NAME"
echo "  - Location: $LOCATION"
echo "  - Resource Group: $RESOURCE_GROUP"
echo ""

DEPLOYMENT_NAME="ninjapaws-dojo-$(date +%s)"

deploy_infrastructure() {
    az deployment group create \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --template-file infra/main.bicep \
        --parameters location="$LOCATION" \
        --output json > deployment-output.json
}
run_or_pause \
    "Deploy infra/main.bicep to resource group '$RESOURCE_GROUP' (may be blocked by Azure Policy or missing permissions)" \
    "az deployment group create --name $DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --template-file infra/main.bicep --parameters location=$LOCATION" \
    deploy_infrastructure

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

# The registry now exists, so the GitHub Actions identity can be granted push access.
echo -e "${YELLOW}Checking AcrPush role for GitHub Actions...${NC}"
ensure_role AcrPush "$ACR_SCOPE"
echo ""

# --- GitHub Actions: make deploy.yml runnable with the OIDC identity above ---
check_github_cli() {
    command -v gh >/dev/null 2>&1
}
check_github_auth() {
    gh auth status --hostname github.com >/dev/null 2>&1
}
check_github_repository() {
    [[ "$(gh repo view "$REPOSITORY" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" == "$REPOSITORY" ]]
}
check_deploy_workflow() {
    [[ "$(gh workflow view deploy.yml --repo "$REPOSITORY" --json state --jq .state 2>/dev/null)" == "active" ]]
}
enable_deploy_workflow() {
    gh workflow enable deploy.yml --repo "$REPOSITORY"
}
sync_github_actions_secrets() {
    local repository_name="${REPOSITORY#*/}"
    if gh secret set AZURE_CLIENT_ID --org "$GITHUB_ORGANIZATION" --visibility selected --repos "$repository_name" --body "$APP_CLIENT_ID" &&
        gh secret set AZURE_TENANT_ID --org "$GITHUB_ORGANIZATION" --visibility selected --repos "$repository_name" --body "$TENANT_ID" &&
        gh secret set AZURE_SUBSCRIPTION_ID --org "$GITHUB_ORGANIZATION" --visibility selected --repos "$repository_name" --body "$SUBSCRIPTION_ID"; then
        GITHUB_SECRET_SCOPE="organization ($GITHUB_ORGANIZATION; selected repository access)"
        return 0
    fi

    echo "  Organization secret configuration is unavailable; falling back to repository-scoped OIDC identifiers."
    gh secret set AZURE_CLIENT_ID --repo "$REPOSITORY" --body "$APP_CLIENT_ID" &&
        gh secret set AZURE_TENANT_ID --repo "$REPOSITORY" --body "$TENANT_ID" &&
        gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPOSITORY" --body "$SUBSCRIPTION_ID" &&
        GITHUB_SECRET_SCOPE="repository ($REPOSITORY)"
}
check_github_actions_secrets() {
    local secret_names
    secret_names=$(gh secret list --repo "$REPOSITORY" --json name --jq '.[].name' 2>/dev/null) || return 1
    grep -qx AZURE_CLIENT_ID <<<"$secret_names" &&
        grep -qx AZURE_TENANT_ID <<<"$secret_names" &&
        grep -qx AZURE_SUBSCRIPTION_ID <<<"$secret_names"
}
check_github_environment() {
    gh api "repos/$REPOSITORY/environments/$1" >/dev/null 2>&1
}
create_github_environment() {
    gh api --method PUT "repos/$REPOSITORY/environments/$1" >/dev/null
}
ensure_github_environment() {
    local environment_name="$1"
    while ! check_github_environment "$environment_name"; do
        echo "  Environment '$environment_name' not found, creating..."
        if create_github_environment "$environment_name"; then
            break
        fi
        echo ""
        echo -e "${RED}⚠️  Manual action required: create GitHub environment '$environment_name'${NC}"
        echo "  gh api --method PUT repos/$REPOSITORY/environments/$environment_name"
        read -n 1 -r -s -p "Press any key to re-check, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved."
            exit 1
        fi
    done
}

echo -e "${YELLOW}Checking GitHub Actions deployment access...${NC}"
wait_for_prerequisite \
    "Install GitHub CLI (gh) so this script can configure repository Actions secrets" \
    "sudo apt-get update && sudo apt-get install -y gh" \
    check_github_cli
wait_for_prerequisite \
    "Sign in to GitHub CLI with write access to '$REPOSITORY'" \
    "gh auth login --hostname github.com --web --scopes repo" \
    check_github_auth
wait_for_prerequisite \
    "Grant the authenticated GitHub account access to '$REPOSITORY'" \
    "gh repo view $REPOSITORY" \
    check_github_repository
ensure_resource \
    "Enable the deploy.yml GitHub Actions workflow on '$REPOSITORY'" \
    "gh workflow enable deploy.yml --repo $REPOSITORY" \
    check_deploy_workflow \
    enable_deploy_workflow
echo "  Branch '$BRANCH' uses GitHub environment '$GITHUB_ENVIRONMENT'."
ensure_github_environment dev
ensure_github_environment prod
# Secret values cannot be read from GitHub. Synchronizing them repairs unknown
# drift without revealing values or creating duplicate secrets.
GITHUB_ORGANIZATION=${REPOSITORY%%/*}
run_or_pause \
    "Configure shared GitHub Actions OIDC bootstrap identifiers for '$REPOSITORY'" \
    "gh secret set AZURE_CLIENT_ID --org $GITHUB_ORGANIZATION --visibility selected --repos ${REPOSITORY#*/} --body <application-client-id>" \
    sync_github_actions_secrets
echo -e "${GREEN}✅ GitHub Actions deploy.yml is ready for '$GITHUB_ENVIRONMENT'${NC}"
echo ""

echo -e "${YELLOW}Building Docker image...${NC}"
build_and_push_image() {
    az acr build \
        --registry "$ACR_NAME" \
        --image "${IMAGE_REPO}:${IMAGE_TAG}" \
        --image "${IMAGE_REPO}:vulnerable" \
        --image "${IMAGE_REPO}:latest" \
        --build-arg "UBUNTU_VERSION=$CONFIG_UBUNTU_VERSION" \
        --build-arg "NODE_MAJOR_VERSION=$CONFIG_NODE_MAJOR_VERSION" \
        --build-arg "NGINX_VERSION=$CONFIG_NGINX_VERSION" \
        --build-arg "VULNERABILITY_STATUS=$CONFIG_VULNERABILITY_STATUS" \
        --build-arg "PORT=$CONFIG_PORT" \
        .
}
run_or_pause \
    "Build and push the training image to ACR '$ACR_NAME'" \
    "az acr build --registry $ACR_NAME --image ${IMAGE_REPO}:${IMAGE_TAG} --image ${IMAGE_REPO}:vulnerable --image ${IMAGE_REPO}:latest ." \
    build_and_push_image

echo -e "${GREEN}✅ Image built and pushed to ACR${NC}"
echo ""

APP_URL=${APP_URL:-https://${APP_SERVICE_NAME}.azurewebsites.net}

restart_app_service() {
    az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" >/dev/null
}
run_or_pause \
    "Restart App Service '$APP_SERVICE_NAME'" \
    "az webapp restart --resource-group $RESOURCE_GROUP --name $APP_SERVICE_NAME" \
    restart_app_service

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
    while true; do
        echo -e "${RED}❌ Application health check failed${NC}"
        echo -e "${YELLOW}Investigate with:${NC}"
        echo ""
        echo "  az webapp log tail --resource-group $RESOURCE_GROUP --name $APP_SERVICE_NAME"
        echo ""
        read -n 1 -r -s -p "Press any key to re-check health, or 'q' to quit: " key
        echo ""
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo "Exiting. Re-run ./scripts/deploy.sh once resolved, or check the App Service logs."
            exit 1
        fi
        if curl -fsS "$APP_URL/health" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Application is healthy${NC}"
            break
        fi
        echo -e "${RED}Still not healthy.${NC}"
    done
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
echo -e "${BLUE}🔑 GitHub Actions configuration:${NC}"
echo "  Environment: $GITHUB_ENVIRONMENT (branch: $BRANCH)"
echo "  OIDC secret names verified without displaying values"
echo "  OIDC bootstrap identifier scope: ${GITHUB_SECRET_SCOPE:-unknown}"
echo "  Non-secret deployment settings: config.json"
echo ""
echo -e "${BLUE}📚 Resources:${NC}"
echo "  - GitHub: https://github.com/$REPOSITORY"
echo "  - Azure Portal: https://portal.azure.com"
echo "  - Defender for Cloud: https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityCentermenu"
echo ""
echo -e "${BLUE}🐾 Ninja Paws | Cloud Security Training${NC}"

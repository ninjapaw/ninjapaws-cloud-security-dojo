#!/usr/bin/env bash

# Staged Azure lifecycle for the Ninja Paws Cloud Security Dojo.

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
AZURE_REPO_ROOT="$REPO_ROOT"
if command -v wslpath >/dev/null 2>&1; then
    AZURE_REPO_ROOT="$(wslpath -w "$REPO_ROOT")"
fi
for azure_cli_dir in "/mnt/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" "/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"; do
    if [[ ! -x "$azure_cli_dir/az.cmd" && -f "$azure_cli_dir/az.cmd" ]]; then
        export PATH="$azure_cli_dir:$PATH"
        break
    fi
done

# Windows az.cmd emits CRLF output when called from WSL/Git Bash.
az() {
    command az "$@" | tr -d '\r'
}

COMMAND="deploy"
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-auto}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOCATION="${AZURE_LOCATION:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
REGISTRY_NAME="${AZURE_CONTAINER_REGISTRY_NAME:-}"
APP_SERVICE_NAME="${AZURE_APP_SERVICE_NAME:-}"
IMAGE_NAME="${IMAGE_NAME:-ninjapaws-dojo}"
IMAGE_TAG="${IMAGE_TAG:-}"
NGINX_VERSION="${NGINX_VERSION:-1.30.3}"
VULNERABILITY_STATUS="${VULNERABILITY_STATUS:-vulnerable}"
ASSUME_YES=false
FORCE=false
WAIT_FOR_DELETE=false
STATE_FILE=""
IMAGE_TAG_EXPLICIT=false
USE_DEFAULTS=false

usage() {
    cat <<'EOF'
Manage the Ninja Paws Cloud Security Dojo Azure lifecycle.

Usage: scripts/deploy.sh <command> [options]

Commands:
  setup                    Provision, build, deploy, and verify
  provision                Create or update the resource group and Bicep resources
  build                    Build and push the selected image to ACR
  deploy|update            Provision, build, deploy the image, and verify
  verify                   Validate Azure resources, image, identity, and endpoints
  repair                   Re-provision, rebuild, redeploy, and verify
  doctor                   Run local and Azure preflight checks and Bicep what-if
  plan                     Print the resolved deployment plan without changing Azure
  uninstall                Delete the owned resource group (requires --yes or confirmation)

Options:
    --environment <dev|prod|auto> Deployment environment (default: detected from Git branch)
  --subscription <id>      Azure subscription ID (default: current subscription)
  --location <region>      Azure region (default: centralus)
  --resource-group <name>  Azure resource group
  --registry-name <name>   Azure Container Registry name
  --app-service-name <name> App Service name
  --image-name <name>      Container image repository (default: ninjapaws-dojo)
  --image-tag <tag>        Image tag (default: current Git SHA)
    --yes                    Skip confirmation; required for non-interactive uninstall
    --defaults               Accept built-in defaults without interactive prompts
  --force                  Allow uninstall of an untagged resource group
  --wait                   Wait for resource-group deletion to finish
  --help                   Show this help

OIDC bootstrap is separate and should be run once per GitHub Environment:
  scripts/setup-azure-github-oidc.sh --environment <dev|prod> --provision
EOF
}

fail() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

prompt_default() {
    local prompt="$1"
    local default_value="$2"
    local answer
    if [[ -t 0 ]]; then
        read -r -p "$prompt [$default_value]: " answer
        printf '%s' "${answer:-$default_value}"
    else
        printf '%s' "$default_value"
    fi
}

confirm() {
    local message="$1"
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    [[ -t 0 ]] || fail "Confirmation is required in non-interactive mode. Re-run with --yes."
    local answer
    read -r -p "$message [y/N] " answer
    --yes                    Skip confirmation; required for non-interactive uninstall
}

write_state() {
    local phase="$1"
    local status="$2"
    local message="${3:-}"
    mkdir -p "$REPO_ROOT/.azure"
    cat > "$STATE_FILE" <<EOF
{
  "environment": "$ENVIRONMENT",
  "subscriptionId": "$SUBSCRIPTION_ID",
  "resourceGroup": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "registryName": "$ACR_NAME",
  "appServiceName": "$APP_SERVICE_NAME",
  "imageName": "$IMAGE_NAME",
  "imageTag": "$IMAGE_TAG",
  "phase": "$phase",
  "status": "$status",
  "message": "$message",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

resolve_settings() {
    if [[ "$ENVIRONMENT" == auto ]]; then
        local branch_name
        branch_name="$(git branch --show-current 2>/dev/null || true)"
        case "$branch_name" in
            dev) ENVIRONMENT=dev ;;
            main) ENVIRONMENT=prod ;;
            *) fail "Cannot detect deployment environment from Git branch '$branch_name'. Use --environment dev or --environment prod." ;;
        esac
    fi

    case "$ENVIRONMENT" in
        dev)
            LOCATION="${LOCATION:-centralus}"
            RESOURCE_GROUP="${RESOURCE_GROUP:-NP-ninjapaws-dojo-Dev-CentralUS}"
            REGISTRY_NAME="${REGISTRY_NAME:-ninjapawsdojodev}"
            APP_SERVICE_NAME="${APP_SERVICE_NAME:-ninjapaws-dojo-app-dev}"
            ;;
        prod)
            LOCATION="${LOCATION:-centralus}"
            RESOURCE_GROUP="${RESOURCE_GROUP:-NP-ninjapaws-dojo-CentralUS}"
            REGISTRY_NAME="${REGISTRY_NAME:-ninjapawsdojo}"
            APP_SERVICE_NAME="${APP_SERVICE_NAME:-ninjapaws-dojo-app}"
            ;;
        *)
            fail "--environment must be dev, prod, or auto."
            ;;
    esac

    if [[ -t 0 && "$USE_DEFAULTS" == false && "$COMMAND" != doctor && "$COMMAND" != verify && "$COMMAND" != plan ]]; then
        LOCATION="$(prompt_default 'Azure region' "$LOCATION")"
        RESOURCE_GROUP="$(prompt_default 'Resource group' "$RESOURCE_GROUP")"
        REGISTRY_NAME="$(prompt_default 'Container Registry' "$REGISTRY_NAME")"
        APP_SERVICE_NAME="$(prompt_default 'App Service' "$APP_SERVICE_NAME")"
    fi

    ACR_NAME="${REGISTRY_NAME//-/}"
    [[ "$ACR_NAME" =~ ^[a-z0-9]{5,50}$ ]] || fail "ACR name must be 5-50 lowercase letters or numbers after hyphen removal."
    STATE_FILE="$REPO_ROOT/.azure/deployment-$ENVIRONMENT.json"
    if [[ "$COMMAND" == verify && "$IMAGE_TAG_EXPLICIT" == false && -f "$STATE_FILE" ]]; then
        IMAGE_TAG="$(sed -n 's/.*"imageTag": "\([^"]*\)".*/\1/p' "$STATE_FILE")"
    fi
    IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
}

require_commands() {
    local command_name
    for command_name in az curl git tr; do
        command -v "$command_name" >/dev/null 2>&1 || fail "'$command_name' is required."
    done
}

authenticate() {
    if ! az account show >/dev/null 2>&1; then
        echo -e "${YELLOW}Azure CLI is not authenticated. Starting device-code login.${NC}"
        az login --use-device-code >/dev/null
    fi
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        az account set --subscription "$SUBSCRIPTION_ID" || fail "Unable to select subscription '$SUBSCRIPTION_ID'."
    fi
    SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
}

print_plan() {
    echo -e "${BLUE}Deployment plan${NC}"
    echo "Environment: $ENVIRONMENT"
    echo "Subscription: ${SUBSCRIPTION_ID:-current Azure subscription}"
    echo "Resource group: $RESOURCE_GROUP"
    echo "Location: $LOCATION"
    echo "Registry: $ACR_NAME"
    echo "App Service: $APP_SERVICE_NAME"
    echo "Image: $IMAGE_NAME:$IMAGE_TAG"
    echo "Bicep: $REPO_ROOT/infra/main.bicep"
    echo "State: $STATE_FILE"
}

provision() {
    echo -e "${YELLOW}Provisioning resource group and Bicep infrastructure...${NC}"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    az tag update \
        --resource-id "$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)" \
        --operation Merge \
        --tags ninjapaws-managed=true ninjapaws-environment="$ENVIRONMENT" \
        --output none

    az deployment group create \
        --name "ninjapaws-dojo-$(date +%s)" \
        --resource-group "$RESOURCE_GROUP" \
        --mode Incremental \
        --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
        --parameters \
            containerRegistryName="$ACR_NAME" \
            appServiceName="$APP_SERVICE_NAME" \
            location="$LOCATION" \
            imageName="$IMAGE_NAME" \
            imageTag=latest \
            nginxVersion="$NGINX_VERSION" \
            vulnerabilityStatus="$VULNERABILITY_STATUS" \
        --output json > "$REPO_ROOT/deployment-output.json"
    write_state provisioned success "Bicep infrastructure applied"
}

build_image() {
    local registry_login
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)" || fail "ACR '$ACR_NAME' was not found. Run provision first."
    echo -e "${YELLOW}Building and pushing $registry_login/$IMAGE_NAME:$IMAGE_TAG...${NC}"
    az acr build \
        --registry "$ACR_NAME" \
        --image "$IMAGE_NAME:$IMAGE_TAG" \
        --image "$IMAGE_NAME:latest" \
        --image "$IMAGE_NAME:$VULNERABILITY_STATUS" \
        "$AZURE_REPO_ROOT"
    write_state image-built success "Image pushed to ACR"
}

rollout_image() {
    local registry_login
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none || fail "Image '$IMAGE_NAME:$IMAGE_TAG' is not present in ACR."
    echo -e "${YELLOW}Configuring App Service for immutable image $IMAGE_TAG...${NC}"
    az webapp config container set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_SERVICE_NAME" \
        --docker-custom-image-name "$registry_login/$IMAGE_NAME:$IMAGE_TAG" \
        --docker-registry-server-url "https://$registry_login" \
        --output none
    az webapp restart --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --output none
    write_state rolled-out success "App Service configured for immutable image"
}

verify() {
    local app_host registry_login configured_image identity_name identity_principal role_count status_json
    app_host="$(az webapp show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query defaultHostName -o tsv)" || fail "App Service was not found."
    registry_login="$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)" || fail "ACR was not found."
    az acr repository show --name "$ACR_NAME" --image "$IMAGE_NAME:$IMAGE_TAG" --output none || fail "Expected image tag is missing from ACR."
    configured_image="$(az webapp config container show --resource-group "$RESOURCE_GROUP" --name "$APP_SERVICE_NAME" --query dockerCustomImageName -o tsv)"
    [[ "$configured_image" == "$registry_login/$IMAGE_NAME:$IMAGE_TAG" ]] || fail "App Service image drifted: expected '$registry_login/$IMAGE_NAME:$IMAGE_TAG', found '$configured_image'."

    identity_name="${APP_SERVICE_NAME}-identity"
    identity_principal="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$identity_name" --query principalId -o tsv)"
    role_count="$(az role assignment list --assignee-object-id "$identity_principal" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME" --query "[?roleDefinitionName=='AcrPull'] | length(@)" -o tsv)"
    [[ "$role_count" -gt 0 ]] || fail "App Service managed identity does not have AcrPull on the registry."

    status_json="$(curl -fsS "https://$app_host/api/status")" || fail "The application status endpoint is unavailable."
    curl -fsS "https://$app_host/health" >/dev/null || fail "The application health endpoint is unavailable."
    echo "$status_json"
    if [[ "$status_json" != *"\"${NGINX_VERSION}\""* ]]; then
        echo -e "${YELLOW}Warning: runtime status does not contain expected NGINX version $NGINX_VERSION.${NC}"
    fi
    if [[ "$status_json" != *"\"${VULNERABILITY_STATUS}\""* ]]; then
        echo -e "${YELLOW}Warning: runtime status does not contain expected training status $VULNERABILITY_STATUS.${NC}"
    fi
    write_state verified success "Runtime and Azure configuration verified"
    echo -e "${GREEN}Verification passed: https://$app_host${NC}"
}

doctor() {
    require_commands
    authenticate
    echo -e "${YELLOW}Compiling Bicep...${NC}"
    local bicep_output="$AZURE_REPO_ROOT/.azure/doctor-main.bicep.json"
    mkdir -p "$REPO_ROOT/.azure"
    az bicep build --file "$AZURE_REPO_ROOT/infra/main.bicep" --outfile "$bicep_output" >/dev/null
    rm -f "$bicep_output"
    if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
        az deployment group what-if \
            --resource-group "$RESOURCE_GROUP" \
            --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
            --parameters containerRegistryName="$ACR_NAME" appServiceName="$APP_SERVICE_NAME" location="$LOCATION" \
            --result-format ResourceIdOnly
    else
        echo "Resource group does not exist yet; provision will create it."
    fi
    echo -e "${GREEN}Preflight checks passed.${NC}"
}

uninstall() {
    local managed environment_tag
    [[ -n "$RESOURCE_GROUP" ]] || fail "Resource group is required for uninstall."
    az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null || { echo "Resource group '$RESOURCE_GROUP' does not exist."; exit 0; }
    managed="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-managed']" -o tsv)"
    environment_tag="$(az group show --name "$RESOURCE_GROUP" --query "tags['ninjapaws-environment']" -o tsv)"
    if [[ "$managed" != true || "$environment_tag" != "$ENVIRONMENT" ]]; then
        [[ "$FORCE" == true ]] || fail "Resource group is not tagged as a Ninja Paws '$ENVIRONMENT' deployment. Use --force only after checking its contents."
    fi
    confirm "Delete resource group '$RESOURCE_GROUP' in environment '$ENVIRONMENT' from subscription '$SUBSCRIPTION_ID'? This is destructive."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    write_state uninstall requested "Resource group deletion requested"
    if [[ "$WAIT_FOR_DELETE" == true ]]; then
        while az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; do
            echo "Waiting for resource group deletion..."
            sleep 15
        done
        write_state uninstall complete "Resource group deletion confirmed"
    fi
    echo -e "${GREEN}Uninstall requested for '$RESOURCE_GROUP'.${NC}"
}

while (($# > 0)); do
    case "$1" in
        setup|provision|build|deploy|update|verify|repair|doctor|plan|uninstall)
            COMMAND="$1"
            shift
            ;;
        --environment|--subscription|--location|--resource-group|--registry-name|--app-service-name|--image-name|--image-tag)
            (($# >= 2)) || fail "$1 requires a value."
            case "$1" in
                --environment) ENVIRONMENT="$2" ;;
                --subscription) SUBSCRIPTION_ID="$2" ;;
                --location) LOCATION="$2" ;;
                --resource-group) RESOURCE_GROUP="$2" ;;
                --registry-name) REGISTRY_NAME="$2" ;;
                --app-service-name) APP_SERVICE_NAME="$2" ;;
                --image-name) IMAGE_NAME="$2" ;;
                --image-tag) IMAGE_TAG="$2"; IMAGE_TAG_EXPLICIT=true ;;
            esac
            shift 2
            ;;
        --yes) ASSUME_YES=true; shift ;;
        --defaults) USE_DEFAULTS=true; shift ;;
        --force) FORCE=true; shift ;;
        --wait) WAIT_FOR_DELETE=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

resolve_settings
if [[ "$COMMAND" == plan ]]; then
    print_plan
    exit 0
fi

require_commands
authenticate
print_plan

case "$COMMAND" in
    doctor)
        doctor
        ;;
    provision)
        confirm "Provision or update Azure infrastructure?"
        provision
        ;;
    build)
        build_image
        ;;
    setup|deploy|update)
        confirm "Provision, build, deploy, and verify Azure resources?"
        provision
        build_image
        rollout_image
        verify
        ;;
    repair)
        confirm "Repair Azure infrastructure and redeploy the selected image?"
        provision
        build_image
        rollout_image
        verify
        ;;
    verify)
        verify
        ;;
    uninstall)
        uninstall
        ;;
esac

#!/usr/bin/env bash

# Configure Azure and GitHub OIDC prerequisites for the Ninja Paws dojo.
# Creates one Entra application per GitHub Environment. No client secrets are created.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
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
if ! command -v az >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  windows_az_path="$(cmd.exe /c where az 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  if [[ -n "$windows_az_path" ]]; then
    azure_cli_dir="$(dirname "$(wslpath -u "$windows_az_path")")"
    export PATH="$azure_cli_dir:$PATH"
  fi
fi

# Windows az.cmd emits CRLF output when called from WSL/Git Bash.
az() {
  command az "$@" | tr -d '\r'
}

environment_name=dev
resource_group=""
location=centralus
registry_name=""
app_service_name=""
repository=""
subscription_id="${AZURE_SUBSCRIPTION_ID:-}"
provision=false
use_defaults=false

usage() {
  cat <<'EOF'
Configure Azure and GitHub OIDC for the Ninja Paws dojo.

Usage: scripts/setup-azure-github-oidc.sh --environment <dev|prod> [options]

Options:
  --environment <name>       GitHub Environment: dev or prod (default: dev)
  --resource-group <name>    Azure resource group
  --registry-name <name>     Azure Container Registry name
  --app-service-name <name>  App Service name
  --location <region>        Azure region (default: centralus)
  --subscription <id>        Azure subscription (default: current az account)
  --repository <owner/name>  GitHub repository (default: current repository)
  --provision                Also deploy infra/main.bicep and grant ACR build/push roles
  --defaults                 Accept built-in environment defaults without prompts
  --help                     Show this help

Defaults for --environment prod match the existing production resources.
EOF
}

prompt_region() {
  local default_region="$1" answer index region
  local regions=(centralus eastus eastus2 westus2 westus3 southcentralus westcentralus northeurope westeurope uksouth southeastasia australiaeast)
  printf '\nAzure region (default: %s)\n' "$default_region"
  for index in "${!regions[@]}"; do
    printf '  %2d) %s\n' "$((index + 1))" "${regions[$index]}"
  done
  while true; do
    read -r -p "Select a region by number or name [$default_region]: " answer
    answer="${answer:-$default_region}"
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      index=$((answer - 1))
      if ((index >= 0 && index < ${#regions[@]})); then
        printf '%s' "${regions[$index]}"
        return 0
      fi
    else
      for region in "${regions[@]}"; do
        if [[ "$answer" == "$region" ]]; then
          printf '%s' "$region"
          return 0
        fi
      done
    fi
    printf 'Please choose one of the listed region numbers or names.\n' >&2
  done
}

while (($# > 0)); do
  case "$1" in
    --environment) environment_name="$2"; shift 2 ;;
    --resource-group) resource_group="$2"; shift 2 ;;
    --registry-name) registry_name="$2"; shift 2 ;;
    --app-service-name) app_service_name="$2"; shift 2 ;;
    --location) location="$2"; shift 2 ;;
    --subscription) subscription_id="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --provision) provision=true; shift ;;
    --defaults) use_defaults=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

for command_name in az gh tr; do
  command -v "$command_name" >/dev/null || { printf "ERROR: '%s' is required.\n" "$command_name" >&2; exit 1; }
done

# config/deploy.config.json is the single source of truth for these defaults;
# do not duplicate literal values here.
NODE_COMMAND=node
if ! command -v node >/dev/null 2>&1; then
  if command -v node.exe >/dev/null 2>&1; then
    NODE_COMMAND=node.exe
  elif [[ -x /mnt/c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/mnt/c/Program Files/nodejs/node.exe'
  elif [[ -x /c/Program\ Files/nodejs/node.exe ]]; then
    NODE_COMMAND='/c/Program Files/nodejs/node.exe'
  else
    printf 'ERROR: Node.js is required to read config/deploy.config.json defaults.\n' >&2
    exit 1
  fi
fi
cfg() {
  (cd "$REPO_ROOT" && "$NODE_COMMAND" -p "require('./config/deploy.config.json').defaults$1")
}

case "$environment_name" in
  dev)
    deployment_branch=dev
    resource_group="${resource_group:-NP-ninjapaws-dojo-Dev-CentralUS}"
    registry_name="${registry_name:-ninjapawsdojodev}"
    app_service_name="${app_service_name:-ninjapaws-dojo-app-dev}"
    ;;
  prod)
    deployment_branch=main
    resource_group="${resource_group:-NP-ninjapaws-dojo-Prod-CentralUS}"
    registry_name="${registry_name:-ninjapawsdojoprod}"
    app_service_name="${app_service_name:-ninjapaws-dojo-app-prod}"
    ;;
  *)
    printf '%s\n' '--environment must be dev or prod.' >&2
    exit 1
    ;;
esac

acr_name="${registry_name//-/}"

if [[ -t 0 && "$use_defaults" == false ]]; then
  location="$(prompt_region "$location")"
  read -r -p "Resource group [$resource_group]: " answer
  resource_group="${answer:-$resource_group}"
  read -r -p "Container Registry [$registry_name]: " answer
  registry_name="${answer:-$registry_name}"
  acr_name="${registry_name//-/}"
  read -r -p "App Service [$app_service_name]: " answer
  app_service_name="${answer:-$app_service_name}"
fi

az account show >/dev/null 2>&1 || { printf "%s\n" "Azure CLI is not authenticated. Run 'az login' and retry." >&2; exit 1; }
if [[ -n "$subscription_id" ]]; then
  az account set --subscription "$subscription_id"
fi
subscription_id="$(az account show --query id -o tsv)"
tenant_id="$(az account show --query tenantId -o tsv)"

gh auth status >/dev/null 2>&1 || { printf "%s\n" "GitHub CLI is not authenticated. Run 'gh auth login' and retry." >&2; exit 1; }
repository="${repository:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

app_display_name="ninjapaws-cloud-security-dojo-${environment_name}-github"

app_client_id="$(az ad app list --display-name "$app_display_name" --query "[?displayName=='$app_display_name'].appId | [0]" -o tsv)"
if [[ -z "$app_client_id" ]]; then
  app_client_id="$(az ad app create --display-name "$app_display_name" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi
app_object_id="$(az ad app show --id "$app_client_id" --query id -o tsv)"

service_principal_object_id="$(az ad sp show --id "$app_client_id" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$service_principal_object_id" ]]; then
  service_principal_object_id="$(az ad sp create --id "$app_client_id" --query id -o tsv)"
fi

# Jobs that declare an environment present the environment subject, not the ref subject.
credential_name="github-${environment_name}"
credential_subject="repo:${repository}:environment:${environment_name}"
existing_credential="$(az ad app federated-credential list --id "$app_object_id" \
  --query "[?name=='$credential_name'] | [0].id" -o tsv)"
if [[ -n "$existing_credential" ]]; then
  az ad app federated-credential delete --id "$app_object_id" --federated-credential-id "$existing_credential"
fi
az ad app federated-credential create --id "$app_object_id" --parameters "$(
  printf '{"name":"%s","issuer":"https://token.actions.githubusercontent.com","subject":"%s","audiences":["api://AzureADTokenExchange"],"description":"GitHub Actions environment OIDC trust"}' \
    "$credential_name" "$credential_subject"
)" >/dev/null

az group create --name "$resource_group" --location "$location" >/dev/null

resource_group_scope="/subscriptions/$subscription_id/resourceGroups/$resource_group"
acr_scope="$resource_group_scope/providers/Microsoft.ContainerRegistry/registries/$acr_name"

ensure_role() {
  local role="$1"
  local scope="$2"
  local count
  count="$(az role assignment list \
    --assignee-object-id "$service_principal_object_id" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='$role'] | length(@)" -o tsv)"
  if [[ "$count" == 0 ]]; then
    az role assignment create \
      --assignee-object-id "$service_principal_object_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" \
      >/dev/null
  fi
}

# Required before infrastructure deployment so Bicep can create the App Service
# managed identity's AcrPull role assignment.
ensure_role Contributor "$resource_group_scope"
ensure_role "Role Based Access Control Administrator" "$resource_group_scope"

if [[ "$provision" == true ]]; then
  az deployment group create \
    --name "ninjapaws-oidc-$(date +%s)" \
    --resource-group "$resource_group" \
    --template-file "$AZURE_REPO_ROOT/infra/main.bicep" \
    --parameters \
      location="$location" \
      containerRegistryName="$acr_name" \
      appServiceName="$app_service_name" \
    --output table

  # The registry exists after Bicep completes, so assign image-push access now.
  ensure_role AcrPush "$acr_scope"
  ensure_role AcrBuild "$acr_scope"
elif az acr show --name "$acr_name" --resource-group "$resource_group" --output none 2>/dev/null; then
  ensure_role AcrPush "$acr_scope"
  ensure_role AcrBuild "$acr_scope"
fi

gh api --method PUT "repos/${repository}/environments/${environment_name}" --input - --silent <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON

branch_policy_count="$(gh api "repos/${repository}/environments/${environment_name}/deployment-branch-policies" \
  --jq "[.branch_policies[] | select(.name == \"$deployment_branch\")] | length")"
if [[ "$branch_policy_count" == 0 ]]; then
  gh api --method POST "repos/${repository}/environments/${environment_name}/deployment-branch-policies" \
    --field name="$deployment_branch" --silent
fi

gh variable set AZURE_CLIENT_ID --env "$environment_name" --repo "$repository" --body "$app_client_id"
gh variable set AZURE_TENANT_ID --env "$environment_name" --repo "$repository" --body "$tenant_id"
gh variable set AZURE_SUBSCRIPTION_ID --env "$environment_name" --repo "$repository" --body "$subscription_id"
gh variable set AZURE_LOCATION --env "$environment_name" --repo "$repository" --body "$location"
gh variable set AZURE_RESOURCE_GROUP --env "$environment_name" --repo "$repository" --body "$resource_group"
gh variable set AZURE_CONTAINER_REGISTRY_NAME --env "$environment_name" --repo "$repository" --body "$acr_name"
gh variable set AZURE_APP_SERVICE_NAME --env "$environment_name" --repo "$repository" --body "$app_service_name"
gh variable set AZURE_IMAGE_NAME --env "$environment_name" --repo "$repository" --body "$(cfg .imageName)"
gh variable set CONTAINER_REGISTRY_SKU --env "$environment_name" --repo "$repository" --body "$(cfg .containerRegistrySku)"
gh variable set APP_SERVICE_PLAN_SKU --env "$environment_name" --repo "$repository" --body "$(cfg .appServicePlanSku)"
gh variable set APP_SERVICE_PLAN_CAPACITY --env "$environment_name" --repo "$repository" --body "$(cfg .appServicePlanCapacity)"
gh variable set BASE_OS_IMAGE --env "$environment_name" --repo "$repository" --body "$(cfg .baseOsImage)"
gh variable set BASE_OS_VERSION --env "$environment_name" --repo "$repository" --body "$(cfg .baseOsVersion)"
gh variable set NGINX_VERSION --env "$environment_name" --repo "$repository" --body "$(cfg .nginxVersion)"
gh variable set VULNERABILITY_STATUS --env "$environment_name" --repo "$repository" --body "$(cfg .vulnerabilityStatus)"
gh variable set NODE_MAJOR_VERSION --env "$environment_name" --repo "$repository" --body "$(cfg .nodeMajorVersion)"
gh variable set PORT --env "$environment_name" --repo "$repository" --body "$(cfg .port)"
gh variable set NPM_REGISTRY_URL --env "$environment_name" --repo "$repository" --body "$(cfg .npmRegistryUrl)"
gh variable set NPM_USE_MIRROR --env "$environment_name" --repo "$repository" --body "$(cfg .npmUseMirror)"
gh variable set NPM_NETWORK_MODE --env "$environment_name" --repo "$repository" --body "$(cfg .npmNetworkMode)"
gh variable set DEFENDER_ENABLED --env "$environment_name" --repo "$repository" --body "$(cfg .defenderEnabled)"
gh variable set DEFENDER_SCAN_ENABLED --env "$environment_name" --repo "$repository" --body "$(cfg .defender.scanAfterVerify)"
gh variable set DEFENDER_MANAGE_PLANS --env "$environment_name" --repo "$repository" --body "$(cfg .defender.managePlans)"
# DEFENDER_TARGET_CVE is intentionally not seeded here: scripts/deploy.sh already falls back to the
# active scenario's own CVE. Only set this Environment variable manually to search for a different CVE.
gh variable set DEFENDER_APPSERVICES_TIER --env "$environment_name" --repo "$repository" --body "$(cfg .defender.plans.AppServices)"
gh variable set DEFENDER_CONTAINERS_TIER --env "$environment_name" --repo "$repository" --body "$(cfg .defender.plans.Containers)"
gh variable set DEFENDER_CSPM_TIER --env "$environment_name" --repo "$repository" --body "$(cfg .defender.plans.CloudPosture)"
gh variable set DEFENDER_ARM_TIER --env "$environment_name" --repo "$repository" --body "$(cfg .defender.plans.Arm)"
gh variable set DEFENDER_MANAGE_EXTENSIONS --env "$environment_name" --repo "$repository" --body "$(cfg .defender.manageExtensions)"
gh variable set DEFENDER_CSPM_SERVERLESS_PROTECTION --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.AgentlessServerlessPosture)"
gh variable set DEFENDER_CSPM_SERVERLESS_CONTAINERS --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.ServerlessContainers)"
gh variable set DEFENDER_CSPM_REGISTRY_ASSESSMENT --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.ContainerRegistriesVulnerabilityAssessments)"
gh variable set DEFENDER_CSPM_KUBERNETES_DISCOVERY --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.AgentlessDiscoveryForKubernetes)"
gh variable set DEFENDER_CSPM_VM_SCANNING --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.AgentlessVmScanning)"
gh variable set DEFENDER_CSPM_SENSITIVE_DATA --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.SensitiveDataDiscovery)"
gh variable set DEFENDER_CSPM_PERMISSIONS_MANAGEMENT --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.EntraPermissionsManagement)"
gh variable set DEFENDER_CSPM_API_POSTURE --env "$environment_name" --repo "$repository" --body "$(cfg .defender.cspmExtensions.ApiPosture)"
gh variable set DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT --env "$environment_name" --repo "$repository" --body "$(cfg .defender.containersExtensions.ContainerRegistriesVulnerabilityAssessments)"
gh variable set DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY --env "$environment_name" --repo "$repository" --body "$(cfg .defender.containersExtensions.AgentlessDiscoveryForKubernetes)"
gh variable set DEFENDER_CONTAINERS_VM_SCANNING --env "$environment_name" --repo "$repository" --body "$(cfg .defender.containersExtensions.AgentlessVmScanning)"
gh variable set DEFENDER_CONTAINERS_SENSOR --env "$environment_name" --repo "$repository" --body "$(cfg .defender.containersExtensions.ContainerSensor)"
gh variable set DEFENDER_DEVOPS_CONNECTOR_ENABLED --env "$environment_name" --repo "$repository" --body "$(cfg .defender.devops.connectorEnabled)"
gh variable set DEFENDER_DEVOPS_CONNECTOR_NAME --env "$environment_name" --repo "$repository" --body "ninjapaws-github-$environment_name"
gh variable set DEFENDER_DEVOPS_GITHUB_OWNER --env "$environment_name" --repo "$repository" --body "${repository%%/*}"
gh variable set GITHUB_ADVANCED_SECURITY_EXPECTED --env "$environment_name" --repo "$repository" --body 'true'
gh variable set DEFENDER_DEVOPS_AGENTLESS_CODE_SCANNING_EXPECTED --env "$environment_name" --repo "$repository" --body "$(cfg .defender.devops.agentlessCodeScanningExpected)"
# Migrate and remove any legacy copy created by older bootstrap versions.
gh secret delete AZURE_CLIENT_ID --env "$environment_name" --repo "$repository" --confirm 2>/dev/null || true

printf '\nConfigured GitHub Environment %s for %s.\n' "$environment_name" "$repository"
printf 'OIDC subject: %s\n' "$credential_subject"
printf 'Deployment branch: %s\n' "$deployment_branch"
printf 'Resource group: %s\n' "$resource_group"
printf 'No client secret was created; Azure identifiers and deployment settings were saved as Environment variables.\n'
if [[ "$provision" != true ]]; then
  printf 'Rerun with --provision to deploy infra/main.bicep and grant ACR build/push roles.\n'
fi

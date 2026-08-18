#!/usr/bin/env bash

# Configure Azure and GitHub OIDC prerequisites for the Ninja Paws dojo.
# Creates one Entra application per GitHub Environment. No client secrets are created.

set -Eeuo pipefail

environment_name=dev
resource_group=""
location=centralus
registry_name=""
app_service_name=""
repository=""
subscription_id="${AZURE_SUBSCRIPTION_ID:-}"
provision=false

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
  --provision                Also deploy infra/main.bicep and grant AcrPush
  --help                     Show this help

Defaults for --environment prod match the existing production resources.
EOF
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
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

for command_name in az gh; do
  command -v "$command_name" >/dev/null || { printf "ERROR: '%s' is required.\n" "$command_name" >&2; exit 1; }
done

case "$environment_name" in
  dev)
    deployment_branch=dev
    resource_group="${resource_group:-NP-ninjapaws-dojo-Dev-CentralUS}"
    registry_name="${registry_name:-ninjapawsdojodev}"
    app_service_name="${app_service_name:-ninjapaws-dojo-app-dev}"
    ;;
  prod)
    deployment_branch=main
    resource_group="${resource_group:-NP-ninjapaws-dojo-CentralUS}"
    registry_name="${registry_name:-ninjapawsdojo}"
    app_service_name="${app_service_name:-ninjapaws-dojo-app}"
    ;;
  *)
    printf '%s\n' '--environment must be dev or prod.' >&2
    exit 1
    ;;
esac

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
acr_scope="$resource_group_scope/providers/Microsoft.ContainerRegistry/registries/$registry_name"

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
    --template-file infra/main.bicep \
    --parameters \
      location="$location" \
      containerRegistryName="$registry_name" \
      appServiceName="$app_service_name" \
    --output table

  # The registry exists after Bicep completes, so assign image-push access now.
  ensure_role AcrPush "$acr_scope"
elif az acr show --name "$registry_name" --resource-group "$resource_group" --output none 2>/dev/null; then
  ensure_role AcrPush "$acr_scope"
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

printf '%s' "$app_client_id" | gh secret set AZURE_CLIENT_ID --env "$environment_name" --repo "$repository"
printf '%s' "$tenant_id" | gh secret set AZURE_TENANT_ID --env "$environment_name" --repo "$repository"
printf '%s' "$subscription_id" | gh secret set AZURE_SUBSCRIPTION_ID --env "$environment_name" --repo "$repository"
gh variable set AZURE_LOCATION --env "$environment_name" --repo "$repository" --body "$location"
gh variable set AZURE_RESOURCE_GROUP --env "$environment_name" --repo "$repository" --body "$resource_group"
gh variable set AZURE_CONTAINER_REGISTRY_NAME --env "$environment_name" --repo "$repository" --body "$registry_name"
gh variable set AZURE_APP_SERVICE_NAME --env "$environment_name" --repo "$repository" --body "$app_service_name"

printf '\nConfigured GitHub Environment %s for %s.\n' "$environment_name" "$repository"
printf 'OIDC subject: %s\n' "$credential_subject"
printf 'Deployment branch: %s\n' "$deployment_branch"
printf 'Resource group: %s\n' "$resource_group"
printf 'No client secret was created.\n'
if [[ "$provision" != true ]]; then
  printf 'Rerun with --provision to deploy infra/main.bicep and grant AcrPush.\n'
fi

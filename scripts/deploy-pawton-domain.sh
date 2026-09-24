#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
export CONFIG_FILE="${DEPLOY_CONFIG_FILE:-$REPO_ROOT/config/deploy.config.json}"
COMMAND=plan
ENVIRONMENT="${DEPLOY_ENVIRONMENT:-dev}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
RESOURCE_GROUP=""
WEB_APP_NAME=""
DOMAIN="${PORTAL_CUSTOM_DOMAIN:-}"
ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
ASSUME_YES=false
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash scripts/deploy-pawton-domain.sh <plan|check|deploy> [options]
  plan: offline configuration preview; no network or writes.
  check: read Azure/Cloudflare and public DNS; no writes.
  deploy: create missing Cloudflare DNS records and deploy Bicep hostname/TLS.
Options: --environment dev|prod --subscription ID --resource-group NAME
         --web-app-name NAME --custom-domain HOST --cloudflare-zone-id ID --yes
Secrets: CLOUDFLARE_API_TOKEN in the environment only (Zone Read + DNS Edit).
Cloudflare must remain DNS-only; existing conflicting records are never changed.
EOF
}
while (($#)); do
    case "$1" in
        plan|check|deploy) COMMAND="$1"; shift ;;
        --environment|--subscription|--resource-group|--web-app-name|--custom-domain|--cloudflare-zone-id)
            [[ $# -ge 2 && "$2" != --* ]] || fail "Missing value for $1."
            case "$1" in
                --environment) ENVIRONMENT="$2" ;;
                --subscription) SUBSCRIPTION_ID="$2" ;;
                --resource-group) RESOURCE_GROUP="$2" ;;
                --web-app-name) WEB_APP_NAME="$2" ;;
                --custom-domain) DOMAIN="$2" ;;
                --cloudflare-zone-id) ZONE_ID="$2" ;;
            esac
            shift 2 ;;
        --yes) ASSUME_YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ "$ENVIRONMENT" == dev || "$ENVIRONMENT" == prod ]] || fail 'Environment must be dev or prod.'
setting() {
    local value
    value="$(config_lookup "environments.$ENVIRONMENT.$1")"
    [[ -n "$value" ]] || value="$(config_lookup "sqlScenario.$1")"
    printf '%s' "${value:-$2}"
}
RESOURCE_GROUP="${RESOURCE_GROUP:-$(setting sqlResourceGroup "NP-ninjapaws-dojo-sql-$ENVIRONMENT")}"
WEB_APP_NAME="${WEB_APP_NAME:-$(setting webAppName "ninjapaws-pawton-$ENVIRONMENT")}"
DOMAIN="${DOMAIN:-$(setting webAppCustomDomain '')}"
ZONE_ID="${ZONE_ID:-$(setting cloudflareZoneId '')}"
[[ -n "$DOMAIN" ]] || { printf '[skip] No webAppCustomDomain configured.\n'; exit 0; }
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
export PAWTON_DOMAIN="$DOMAIN"
"$NODE_COMMAND" scripts/configure-pawton-dns.mjs validate
printf 'Pawton custom domain: %s\nWeb App: %s\nResource group: %s\nCloudflare zone: %s\nDNS mode: DNS-only (not proxied)\n' "$DOMAIN" "$WEB_APP_NAME" "$RESOURCE_GROUP" "${ZONE_ID:-not configured}"
if [[ "$COMMAND" == plan ]]; then
    printf 'Plan: read Web App verification ID; ensure asuid TXT and direct CNAME; bind hostname; issue managed certificate; bind SNI; verify HTTPS.\n'
    printf 'No network calls or changes. Set PORTAL_CUSTOM_DOMAIN during the portal build and deployment.\n'
    exit 0
fi
[[ -n "$ZONE_ID" && -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail 'Set CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN before check/deploy.'
[[ "$ZONE_ID" =~ ^[a-fA-F0-9]{32}$ ]] || fail 'Cloudflare zone ID must be 32 hexadecimal characters.'
if [[ "$COMMAND" == deploy ]]; then
    branch="$(git -C "$REPO_ROOT" branch --show-current)"
    expected_branch=dev
    [[ "$ENVIRONMENT" != prod ]] || expected_branch=main
    [[ "$branch" == "$expected_branch" ]] || fail "Deploy $ENVIRONMENT only from $expected_branch."
fi
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
[[ "$SUBSCRIPTION_ID" =~ ^[a-fA-F0-9-]{36}$ ]] || fail 'Azure subscription ID is invalid.'
app_args=(--subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME")
metadata="$(az webapp show "${app_args[@]}" --query '[defaultHostName,customDomainVerificationId,location,httpsOnly]' -o json | "$NODE_COMMAND" -e 'let text="";process.stdin.on("data",data=>text+=data);process.stdin.on("end",()=>console.log(JSON.parse(text).join("\t")));')"
IFS=$'\t' read -r PAWTON_AZURE_HOSTNAME PAWTON_VERIFICATION_ID LOCATION HTTPS_ONLY <<<"$metadata"
[[ "$HTTPS_ONLY" == true || "$HTTPS_ONLY" == True ]] || fail 'The Web App must enforce HTTPS before adding a custom domain.'
export PAWTON_AZURE_HOSTNAME PAWTON_VERIFICATION_ID
export CLOUDFLARE_ZONE_ID="$ZONE_ID"
"$NODE_COMMAND" scripts/configure-pawton-dns.mjs plan
binding_state="$(az webapp config hostname list --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --webapp-name "$WEB_APP_NAME" --query "[?name=='$DOMAIN'].sslState | [0]" -o tsv)"
certificate_name="$(az webapp config ssl list --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --query "[?canonicalName=='$DOMAIN'].name | [0]" -o tsv)"
if [[ "$COMMAND" == check ]]; then
    "$NODE_COMMAND" scripts/configure-pawton-dns.mjs verify
    [[ "$binding_state" == SniEnabled ]] || fail 'The custom hostname does not yet have an SNI HTTPS binding.'
else
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Create missing DNS records and bind HTTPS for $DOMAIN to $WEB_APP_NAME? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || fail 'Aborted without changes.'
    fi
    if [[ -n "$binding_state" && "$binding_state" != Disabled && -z "$certificate_name" ]]; then
        fail 'An existing non-managed TLS binding will not be replaced. Review its certificate ownership first.'
    fi
    "$NODE_COMMAND" scripts/configure-pawton-dns.mjs apply
    "$NODE_COMMAND" scripts/configure-pawton-dns.mjs verify
    template="$AZURE_REPO_ROOT/infra/sql-defender-scenario/custom-domain.bicep"
    deploy_args=(--subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --template-file "$template" --mode Incremental)
    parameters=(webAppName="$WEB_APP_NAME" customDomain="$DOMAIN" location="$LOCATION" certificateName="$certificate_name")
    if [[ -z "$binding_state" ]]; then
        az deployment group what-if "${deploy_args[@]}" --parameters "${parameters[@]}" enableTls=false
        az deployment group create "${deploy_args[@]}" --name "pawton-hostname-$ENVIRONMENT" --parameters "${parameters[@]}" enableTls=false --output none
    fi
    az deployment group what-if "${deploy_args[@]}" --parameters "${parameters[@]}" enableTls=true
    az deployment group create "${deploy_args[@]}" --name "pawton-tls-$ENVIRONMENT" --parameters "${parameters[@]}" enableTls=true --output none
    binding_state="$(az webapp config hostname list --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --webapp-name "$WEB_APP_NAME" --query "[?name=='$DOMAIN'].sslState | [0]" -o tsv)"
    [[ "$binding_state" == SniEnabled ]] || fail 'SNI binding was not verified. Rerun after certificate issuance completes.'
fi
http_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 30 "https://$DOMAIN/status")"
[[ "$http_code" == 200 ]] || fail "HTTPS endpoint returned $http_code. DNS/TLS may be ready but the portal is not healthy."
printf '[found] Verified HTTPS: https://%s/status\n' "$DOMAIN"
printf 'Portal sign-in also requires a build with PORTAL_CUSTOM_DOMAIN=%s. No application code or credentials were changed by this command.\n' "$DOMAIN"
// Resolves runtime configuration for GitHub Actions jobs from config/deploy.config.json's
// `defaults` block, letting a GitHub Environment variable override any individual value.
// This is the only place these fallback values are read; do not re-hardcode them elsewhere.
const fs = require('fs');
const path = require('path');

const workspace = process.env.GITHUB_WORKSPACE || process.cwd();
const config = JSON.parse(fs.readFileSync(path.join(workspace, 'config', 'deploy.config.json'), 'utf8'));
const defaults = config.defaults || {};
const defender = defaults.defender || {};
const plans = defender.plans || {};
const cspmExtensions = defender.cspmExtensions || {};
const containersExtensions = defender.containersExtensions || {};
const devops = defender.devops || {};

let vars = {};
try {
  vars = JSON.parse(process.env.VARS_JSON || '{}');
} catch {
  vars = {};
}

function pick(name, fallback) {
  const override = vars[name];
  if (override !== undefined && override !== null && String(override).trim() !== '') {
    return override;
  }
  return fallback;
}

const resolved = {
  LOCATION: pick('AZURE_LOCATION', defaults.location),
  IMAGE_NAME: pick('AZURE_IMAGE_NAME', defaults.imageName),
  BASE_OS_IMAGE: pick('BASE_OS_IMAGE', defaults.baseOsImage),
  BASE_OS_VERSION: pick('BASE_OS_VERSION', defaults.baseOsVersion),
  NGINX_VERSION: pick('NGINX_VERSION', defaults.nginxVersion),
  CONTAINER_REGISTRY_SKU: pick('CONTAINER_REGISTRY_SKU', defaults.containerRegistrySku),
  APP_SERVICE_PLAN_SKU: pick('APP_SERVICE_PLAN_SKU', defaults.appServicePlanSku),
  APP_SERVICE_PLAN_CAPACITY: pick('APP_SERVICE_PLAN_CAPACITY', defaults.appServicePlanCapacity),
  NODE_MAJOR_VERSION: pick('NODE_MAJOR_VERSION', defaults.nodeMajorVersion),
  VULNERABILITY_STATUS: pick('VULNERABILITY_STATUS', defaults.vulnerabilityStatus),
  PORT: pick('PORT', defaults.port),
  NPM_REGISTRY_URL: pick('NPM_REGISTRY_URL', defaults.npmRegistryUrl),
  NPM_USE_MIRROR: pick('NPM_USE_MIRROR', defaults.npmUseMirror),
  NPM_NETWORK_MODE: pick('NPM_NETWORK_MODE', defaults.npmNetworkMode),
  DEFENDER_ENABLED: pick('DEFENDER_ENABLED', defaults.defenderEnabled),
  DEFENDER_SCAN_ENABLED: pick('DEFENDER_SCAN_ENABLED', defender.scanAfterVerify),
  DEFENDER_MANAGE_PLANS: pick('DEFENDER_MANAGE_PLANS', defender.managePlans),
  // No config default: falls back to the active scenario's own CVE (scripts/deploy.sh SCENARIO_CVE)
  // unless an operator explicitly overrides it to search for a different CVE.
  DEFENDER_TARGET_CVE: pick('DEFENDER_TARGET_CVE', ''),
  DEFENDER_APPSERVICES_TIER: pick('DEFENDER_APPSERVICES_TIER', plans.AppServices),
  DEFENDER_CONTAINERS_TIER: pick('DEFENDER_CONTAINERS_TIER', plans.Containers),
  DEFENDER_CSPM_TIER: pick('DEFENDER_CSPM_TIER', plans.CloudPosture),
  DEFENDER_ARM_TIER: pick('DEFENDER_ARM_TIER', plans.Arm),
  DEFENDER_MANAGE_EXTENSIONS: pick('DEFENDER_MANAGE_EXTENSIONS', defender.manageExtensions),
  DEFENDER_CSPM_SERVERLESS_PROTECTION: pick('DEFENDER_CSPM_SERVERLESS_PROTECTION', cspmExtensions.AgentlessServerlessPosture),
  DEFENDER_CSPM_SERVERLESS_CONTAINERS: pick('DEFENDER_CSPM_SERVERLESS_CONTAINERS', cspmExtensions.ServerlessContainers),
  DEFENDER_CSPM_REGISTRY_ASSESSMENT: pick('DEFENDER_CSPM_REGISTRY_ASSESSMENT', cspmExtensions.ContainerRegistriesVulnerabilityAssessments),
  DEFENDER_CSPM_KUBERNETES_DISCOVERY: pick('DEFENDER_CSPM_KUBERNETES_DISCOVERY', cspmExtensions.AgentlessDiscoveryForKubernetes),
  DEFENDER_CSPM_VM_SCANNING: pick('DEFENDER_CSPM_VM_SCANNING', cspmExtensions.AgentlessVmScanning),
  DEFENDER_CSPM_SENSITIVE_DATA: pick('DEFENDER_CSPM_SENSITIVE_DATA', cspmExtensions.SensitiveDataDiscovery),
  DEFENDER_CSPM_PERMISSIONS_MANAGEMENT: pick('DEFENDER_CSPM_PERMISSIONS_MANAGEMENT', cspmExtensions.EntraPermissionsManagement),
  DEFENDER_CSPM_API_POSTURE: pick('DEFENDER_CSPM_API_POSTURE', cspmExtensions.ApiPosture),
  DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT: pick('DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT', containersExtensions.ContainerRegistriesVulnerabilityAssessments),
  DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY: pick('DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY', containersExtensions.AgentlessDiscoveryForKubernetes),
  DEFENDER_CONTAINERS_VM_SCANNING: pick('DEFENDER_CONTAINERS_VM_SCANNING', containersExtensions.AgentlessVmScanning),
  DEFENDER_CONTAINERS_SENSOR: pick('DEFENDER_CONTAINERS_SENSOR', containersExtensions.ContainerSensor),
  DEFENDER_DEVOPS_CONNECTOR_ENABLED: pick('DEFENDER_DEVOPS_CONNECTOR_ENABLED', devops.connectorEnabled),
  DEFENDER_DEVOPS_CONNECTOR_NAME: pick('DEFENDER_DEVOPS_CONNECTOR_NAME', devops.connectorName),
  GITHUB_ADVANCED_SECURITY_EXPECTED: pick('GITHUB_ADVANCED_SECURITY_EXPECTED', devops.advancedSecurityExpected),
  DEFENDER_DEVOPS_AGENTLESS_CODE_SCANNING_EXPECTED: pick('DEFENDER_DEVOPS_AGENTLESS_CODE_SCANNING_EXPECTED', devops.agentlessCodeScanningExpected),
};

const lines = Object.entries(resolved)
  .filter(([, value]) => value !== undefined && value !== null)
  .map(([key, value]) => `${key}=${value}`)
  .join('\n') + '\n';

const githubEnvPath = process.env.GITHUB_ENV;
if (githubEnvPath) {
  fs.appendFileSync(githubEnvPath, lines);
} else {
  process.stdout.write(lines);
}

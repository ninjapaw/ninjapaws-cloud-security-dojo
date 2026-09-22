// Deployed into the central workspace's own resource group (NP-Sentinel-CentralUS by default),
// which differs from this scenario's resource group -- a plain resource declaration in main.bicep
// cannot target a different resource group without a module (BCP139).
@description('Name of the standardized Log Analytics workspace to grant read access to.')
param workspaceName string

@description('Principal ID of the Web App system-assigned managed identity to grant Log Analytics Reader.')
param principalId string

@description('A stable, unique suffix for the role assignment name (e.g. the Web App name).')
param roleAssignmentNameSuffix string

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

resource logAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: workspace
  name: guid(workspace.id, roleAssignmentNameSuffix, 'logAnalyticsReader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a8f5')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

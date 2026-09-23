targetScope = 'resourceGroup'

@description('Existing workspace to onboard. Deploy only after approving Microsoft Sentinel charges.')
param workspaceName string = 'log-np-sentinel-centralus'

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

// Billing opt-in stays separate from main.bicep, which deploys content only.
// The existing workspace, retention, AMA and DCR settings are not modified.
resource onboarding 'Microsoft.SecurityInsights/onboardingStates@2025-09-01' = {
  scope: workspace
  name: 'default'
  properties: {
    customerManagedKey: false
  }
}

output onboardingId string = onboarding.id

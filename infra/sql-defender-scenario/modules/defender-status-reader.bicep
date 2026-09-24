// The status cards read subscription-level Defender pricing. Security Reader is read-only
// and does not permit plan changes, VM extension writes, or alert simulation execution.
targetScope = 'subscription'

@description('Principal ID of the Web App system-assigned managed identity.')
param principalId string

@description('A stable, unique suffix for the role assignment name (for example, the Web App name).')
param roleAssignmentNameSuffix string

resource securityReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, roleAssignmentNameSuffix, 'securityReader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '39bc4728-0917-49c7-9d2c-d95423bc2eb4')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

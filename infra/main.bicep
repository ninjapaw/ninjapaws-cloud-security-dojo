param location string = resourceGroup().location
param containerRegistryName string
param appServiceName string
param appServicePlanName string = '${appServiceName}-plan'
param imageName string = 'ninjapaws-dojo'
param imageTag string = 'latest'
param nginxVersion string = '1.30.3'
param vulnerabilityStatus string = 'vulnerable'
param port int = 3000
param defenderEnabled bool = false

// Azure Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace(containerRegistryName, '-', '')
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
  }
}

// User-assigned Managed Identity for App Service
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appServiceName}-identity'
  location: location
}

// Role assignment: App Service can pull from ACR
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: containerRegistry
  name: guid(containerRegistry.id, managedIdentity.id, 'acrPull')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

// App Service for Linux Container
resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: appServiceName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerRegistry.properties.loginServer}/${imageName}:${imageTag}'
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: managedIdentity.properties.clientId
      appSettings: [
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${containerRegistry.properties.loginServer}'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'WEBSITES_PORT'
          value: '80'
        }
        {
          name: 'NGINX_VERSION'
          value: nginxVersion
        }
        {
          name: 'VULNERABILITY_STATUS'
          value: vulnerabilityStatus
        }
        {
          name: 'PORT'
          value: string(port)
        }
        {
          name: 'DEFENDER_ENABLED'
          value: string(defenderEnabled)
        }
      ]
    }
  }
}

// App Service Health Check
resource healthCheck 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: appService
  name: 'web'
  properties: {
    healthCheckPath: '/health'
  }
}

// Outputs
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerRegistryId string = containerRegistry.id
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output appServiceName string = appService.name
output managedIdentityId string = managedIdentity.id
output managedIdentityClientId string = managedIdentity.properties.clientId
output image string = '${containerRegistry.properties.loginServer}/${imageName}:${imageTag}'

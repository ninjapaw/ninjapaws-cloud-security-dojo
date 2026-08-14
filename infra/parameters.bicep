param location string = 'eastus'
param environment string = 'training'
param containerRegistryName string = 'ninjapawsdojo'
param appServiceName string = 'ninjapaws-dojo-app'
param appServicePlanName string = 'ninjapaws-dojo-plan'

module infrastructure './main.bicep' = {
  name: 'ninjapaws-dojo-infrastructure'
  params: {
    location: location
    containerRegistryName: containerRegistryName
    appServiceName: appServiceName
    appServicePlanName: appServicePlanName
    environment: environment
  }
}

output containerRegistryLoginServer string = infrastructure.outputs.containerRegistryLoginServer
output appServiceUrl string = infrastructure.outputs.appServiceUrl
output appServiceName string = infrastructure.outputs.appServiceName

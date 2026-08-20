param location string = 'centralus'
param containerRegistryName string = 'ninjapawsdojoprod'
param appServiceName string = 'ninjapaws-dojo-app-prod'
param appServicePlanName string = 'ninjapaws-dojo-plan'
param imageName string = 'ninjapaws-dojo'
param imageTag string = 'latest'
param nginxVersion string = '1.30.3'
param vulnerabilityStatus string = 'vulnerable'
param port int = 3000
param defenderEnabled bool = false

module infrastructure './main.bicep' = {
  name: 'ninjapaws-dojo-infrastructure'
  params: {
    location: location
    containerRegistryName: containerRegistryName
    appServiceName: appServiceName
    appServicePlanName: appServicePlanName
    imageName: imageName
    imageTag: imageTag
    nginxVersion: nginxVersion
    vulnerabilityStatus: vulnerabilityStatus
    port: port
    defenderEnabled: defenderEnabled
  }
}

output containerRegistryLoginServer string = infrastructure.outputs.containerRegistryLoginServer
output appServiceUrl string = infrastructure.outputs.appServiceUrl
output appServiceName string = infrastructure.outputs.appServiceName

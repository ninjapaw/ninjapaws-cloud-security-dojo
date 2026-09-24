@description('Existing Pawton Linux Web App name.')
param webAppName string

@description('Region of the existing Web App and its App Service plan.')
param location string

@minLength(4)
@maxLength(64)
@description('Verified custom subdomain. Public CNAME must point directly to the Web App default hostname.')
param customDomain string

@description('Deploy false only for a hostname that has no existing binding; deploy true after the hostname exists to issue and bind HTTPS.')
param enableTls bool = true

@description('Existing managed certificate name when adopting a certificate already issued for this hostname; otherwise a deterministic name is used.')
param certificateName string = ''

resource webApp 'Microsoft.Web/sites@2025-03-01' existing = {
  name: webAppName
}

resource certificate 'Microsoft.Web/certificates@2025-03-01' = if (enableTls) {
  name: empty(certificateName) ? 'pawton-${uniqueString(webApp.id, customDomain)}' : certificateName
  location: location
  properties: {
    canonicalName: customDomain
    serverFarmId: webApp.properties.serverFarmId
  }
}

resource binding 'Microsoft.Web/sites/hostNameBindings@2025-03-01' = {
  parent: webApp
  name: customDomain
  properties: {
    siteName: webApp.name
    hostNameType: 'Verified'
    customHostNameDnsRecordType: 'CName'
    sslState: enableTls ? 'SniEnabled' : 'Disabled'
    thumbprint: enableTls ? certificate!.properties.thumbprint : null
  }
}

output portalUrl string = 'https://${customDomain}'
output certificateName string = enableTls ? certificate!.name : ''

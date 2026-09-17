@description('Azure region for all resources in this scenario.')
param location string = resourceGroup().location

@description('Base name used to derive the VM, NIC, disk, and related resource names.')
param vmName string = 'ninjapaws-sql-vm'

@description('Windows administrator login for the SQL Server VM. Must not be a literal default; supply at deploy time.')
param adminUsername string

@secure()
@description('Windows administrator password for the SQL Server VM. No default; the deploy script generates a random value per run.')
param adminPassword string

@allowed([
  'Standard_D2s_v4'
  'Standard_D4s_v4'
  'Standard_D4ds_v4'
])
@description('VM size. D-series with local/temp SSD supports SQL Server tempdb placement best practices. v4 sizes are used because the v5 generation has no capacity in this subscription/region.')
param vmSize string = 'Standard_D4s_v4'

@allowed([
  'sqldev-gen2'
  'standard-gen2'
  'enterprise-gen2'
])
@description('SQL Server 2022 on Windows Server 2022 marketplace image SKU. Must be a -gen2 SKU: Trusted Launch (below) requires a generation 2 image, and the publisher no longer offers generation 1 SKUs for this offer. sqldev-gen2 is free for training/dev use.')
param sqlImageSku string = 'sqldev-gen2'

@description('Log Analytics workspace name backing Defender for Servers and SQL auditing.')
param workspaceName string = '${vmName}-law'

@description('Raw content base URL used to fetch the futon-manufacturing bootstrap script onto the VM.')
param bootstrapScriptUrl string

@description('Enable Azure Bastion for browser-based RDP instead of a public IP on the VM.')
param deployBastion bool = true

@description('Deploy the Pawton Manufacturing dashboard: a Node.js/Astro Web App that reads the restored sample data over a private VNet connection.')
param deployWebApp bool = true

@description('Name of the Linux Web App hosting the Pawton Manufacturing dashboard.')
param webAppName string = '${vmName}-web'

@description('App Service plan SKU for the dashboard Web App.')
param webAppPlanSku string = 'B1'

@secure()
@description('Password for the least-privilege futon_app SQL login, shared between the Key Vault secret the Web App reads and the VM bootstrap script that creates the login. No default; the deploy script generates a random value per run.')
param sqlAppLoginPassword string

var nsgName = '${vmName}-nsg'
var vnetName = '${vmName}-vnet'
var nicName = '${vmName}-nic'
var vmSubnetPrefix = '10.20.1.0/24'
var bastionSubnetPrefix = '10.20.2.0/26'
var webAppSubnetPrefix = '10.20.3.0/24'
var sqlVmResourceName = vmName
// Windows computer names are capped at 15 characters and can't contain hyphens meaningfully longer
// than that; the Azure resource name (vmName) has no such limit, so derive a short one separately.
var computerName = take(replace(vmName, '-', ''), 15)
// Key Vault names are globally unique and capped at 24 characters; derive a short, RG-scoped
// name instead of taking it as a param so callers never have to hand-pick one.
// Folds in the deployment name (unique per run) as well as the RG, not just the RG, so a
// redeploy never targets a vault name that's soft-deleted-but-purge-protected from a prior run.
var keyVaultResourceName = take(toLower(replace('${vmName}kv${uniqueString(resourceGroup().id, deployment().name)}', '-', '')), 24)

// Log Analytics workspace: required for Defender for Servers Plan 2 (MDE) and SQL Server audit/diagnostic data.
resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// No inbound rules are defined here on purpose except the one path the dashboard Web App needs:
// RDP goes through Bastion, and every other SQL client is expected to use a private connection.
// Defender for Servers Just-In-Time VM Access manages any temporary exceptions beyond that.
resource nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: deployWebApp ? [
      {
        name: 'AllowWebAppToSql'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: webAppSubnetPrefix
          destinationAddressPrefix: vmSubnetPrefix
        }
      }
    ] : []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: concat([
      {
        name: 'sql-vm-subnet'
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ], deployBastion ? [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ] : [], deployWebApp ? [
      {
        name: 'webapp-integration-subnet'
        properties: {
          addressPrefix: webAppSubnetPrefix
          delegations: [
            {
              name: 'webapp-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ] : [])
  }
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = if (deployBastion) {
  name: '${vmName}-bastion-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-01-01' = if (deployBastion) {
  name: '${vmName}-bastion'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: vnet.properties.subnets[1].id
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

// No public IP: the VM is reached only through Bastion, keeping the SQL Server host off the internet.
resource nic 'Microsoft.Network/networkInterfaces@2025-01-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        // AutomaticByPlatform (VM Guest Patching) is not supported on this SQL Server
        // marketplace image; the SQL IaaS Agent's own autoPatchingSettings (below) already
        // schedules OS/engine patching, so plain Windows Update (AutomaticByOS) is enough here.
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: sqlImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    // Encryption at host is not enabled here because it requires the Microsoft.Compute/EncryptionAtHost
    // subscription feature to be registered first, which not every subscription has opted into.
    // Managed disks are still encrypted at rest by default via platform-managed keys either way.
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Registers the VM with the SQL VM RP so Azure manages patching/backup and Defender for SQL
// on machines can evaluate the workload, instead of treating it as an opaque generic VM.
resource sqlVirtualMachine 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: sqlVmResourceName
  location: location
  properties: {
    virtualMachineResourceId: vm.id
    sqlManagement: 'Full'
    // 'DR' (free disaster-recovery secondary) only applies to Standard/Enterprise editions;
    // Developer edition (sqldev-gen2, this scenario's default) must use PAYG even though the
    // edition itself carries no license cost.
    sqlServerLicenseType: 'PAYG'
    leastPrivilegeMode: 'Enabled'
    autoPatchingSettings: {
      enable: true
      dayOfWeek: 'Sunday'
      maintenanceWindowStartingHour: 2
      maintenanceWindowDuration: 60
    }
    // Automated backups need a storage account URL/key, which this training scenario doesn't
    // provision (it would add a storage account purely for backup targets); disabled rather than
    // wired to a placeholder. Add a storage account and set enable/storageAccountUrl to turn it on.
    autoBackupSettings: {
      enable: false
    }
    serverConfigurationsManagementSettings: {
      sqlConnectivityUpdateSettings: {
        connectivityType: 'PRIVATE'
        port: 1433
      }
      sqlWorkloadTypeUpdateSettings: {
        sqlWorkloadType: 'OLTP'
      }
      additionalFeaturesServerConfigurations: {
        isRServicesEnabled: false
      }
    }
  }
}

// Custom Script Extension runs after SQL Server is available, restoring the futon-manufacturing
// sample content and applying least-privilege / TDE / auditing hardening. protectedSettings keeps
// arguments out of the extension's public instance view (no secrets are embedded in commandToExecute).
resource bootstrapExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'futon-manufacturing-bootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        bootstrapScriptUrl
      ]
    }
    protectedSettings: {
      // The password is base64-encoded before it ever reaches commandToExecute: this is a cmd.exe
      // command line (Custom Script Extension always shells out via cmd /c), and several of the
      // generator's allowed special characters (&, %, ^, !) are cmd.exe metacharacters that would
      // corrupt or split the command if embedded raw. No surrounding quotes are used either:
      // neither cmd.exe nor Win32 argv parsing (which powershell.exe uses) treats a single quote
      // as a quote character, so wrapping the value in '...' would pass the literal quote
      // characters through as part of the argument instead of stripping them.
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Setup-FutonManufacturing.ps1 -AppLoginPasswordBase64 ${base64(sqlAppLoginPassword)}'
    }
  }
  dependsOn: [
    sqlVirtualMachine
  ]
}

// Holds the futon_app SQL login password so both the VM bootstrap script and the dashboard Web
// App use the same credential, without ever putting it in an ARM output or app-visible setting.
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultResourceName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    // This subscription's policy baseline requires purge protection on every Key Vault, so it
    // can't be turned off for easier redeploys. The name below folds in the deployment name (which
    // the deploy script makes unique per run) specifically so a repeat deploy never collides with a
    // soft-deleted vault from a prior run; the trade-off is that torn-down vaults linger, purgeable
    // only after the default 90-day retention or by an operator with Key Vault purge permission.
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

resource sqlAppLoginSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'sql-app-login-password'
  properties: {
    value: sqlAppLoginPassword
  }
}

// Pawton Manufacturing dashboard: Astro/Node.js Web App reading the restored sample data. It
// never touches the internet path to SQL Server -- regional VNet integration routes its traffic
// to the private IP on the sql-vm-subnet, and the NSG only allows that one subnet on port 1433.
resource webAppPlan 'Microsoft.Web/serverfarms@2025-03-01' = if (deployWebApp) {
  name: '${webAppName}-plan'
  location: location
  kind: 'linux'
  sku: {
    name: webAppPlanSku
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2025-03-01' = if (deployWebApp) {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: webAppPlan.id
    httpsOnly: true
    virtualNetworkSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'webapp-integration-subnet')
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: true
      http20Enabled: true
      minTlsVersion: '1.2'
      healthCheckPath: '/health'
      appSettings: [
        {
          name: 'SQL_SERVER_HOST'
          value: nic.properties.ipConfigurations[0].properties.privateIPAddress
        }
        {
          name: 'SQL_DATABASE'
          value: 'FutonManufacturing'
        }
        {
          name: 'SQL_APP_LOGIN'
          value: 'futon_app'
        }
        {
          name: 'SQL_APP_LOGIN_PASSWORD'
          value: '@Microsoft.KeyVault(SecretUri=${sqlAppLoginSecret.properties.secretUri})'
        }
        {
          name: 'WEBSITES_PORT'
          value: '8080'
        }
        {
          name: 'PORT'
          value: '8080'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
      ]
    }
  }
}

resource webAppKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployWebApp) {
  scope: keyVault
  name: guid(keyVault.id, webAppName, 'kvSecretsUser')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: webApp!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// SQL Server audit and Windows Security events reach this workspace through the Microsoft
// Defender for Endpoint sensor and the SQL IaaS agent extension, not a diagnosticSettings
// resource; classic VM diagnosticSettings only forwards host metrics, not those event streams.
output vmName string = vm.name
output vmResourceId string = vm.id
output sqlVirtualMachineId string = sqlVirtualMachine.id
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output bastionName string = deployBastion ? bastion.name : ''
output vnetId string = vnet.id
output principalId string = vm.identity.principalId
output keyVaultName string = keyVaultResourceName
output webAppName string = deployWebApp ? webApp!.name : ''
output webAppHostName string = deployWebApp ? webApp!.properties.defaultHostName : ''

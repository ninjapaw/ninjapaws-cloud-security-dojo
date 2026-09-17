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
  'Standard_D2s_v5'
  'Standard_D4s_v5'
  'Standard_D4ds_v5'
])
@description('VM size. D-series with local/temp SSD supports SQL Server tempdb placement best practices.')
param vmSize string = 'Standard_D4s_v5'

@allowed([
  'sqldev'
  'standard'
  'enterprise'
])
@description('SQL Server 2022 on Windows Server 2022 marketplace image SKU. sqldev is free for training/dev use.')
param sqlImageSku string = 'sqldev'

@description('Log Analytics workspace name backing Defender for Servers and SQL auditing.')
param workspaceName string = '${vmName}-law'

@description('Raw content base URL used to fetch the futon-manufacturing bootstrap script onto the VM.')
param bootstrapScriptUrl string

@description('Enable Azure Bastion for browser-based RDP instead of a public IP on the VM.')
param deployBastion bool = true

var nsgName = '${vmName}-nsg'
var vnetName = '${vmName}-vnet'
var nicName = '${vmName}-nic'
var vmSubnetPrefix = '10.20.1.0/24'
var bastionSubnetPrefix = '10.20.2.0/26'
var sqlVmResourceName = vmName

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

// No inbound rules are defined here on purpose: RDP goes through Bastion and SQL access
// is expected over a private connection. Defender for Servers Just-In-Time VM Access
// manages any temporary exceptions instead of a standing allow rule.
resource nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: []
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
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
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
    securityProfile: {
      encryptionAtHost: true
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
    sqlServerLicenseType: sqlImageSku == 'sqldev' ? 'DR' : 'PAYG'
    leastPrivilegeMode: 'Enabled'
    autoPatchingSettings: {
      enable: true
      dayOfWeek: 'Sunday'
      maintenanceWindowStartingHour: 2
      maintenanceWindowDuration: 60
    }
    autoBackupSettings: {
      enable: true
      enableEncryption: true
      retentionPeriod: 7
      backupScheduleType: 'Automated'
      backupSystemDbs: true
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
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Setup-FutonManufacturing.ps1'
    }
  }
  dependsOn: [
    sqlVirtualMachine
  ]
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

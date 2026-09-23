targetScope = 'resourceGroup'

@description('Existing central Log Analytics workspace. This template does not change ingestion or workspace billing.')
param workspaceName string = 'log-np-sentinel-centralus'

@description('SQL VM resource ID used to scope all content to this scenario.')
@minLength(1)
param sqlVmResourceId string

@description('Enable scheduled detections. Sentinel must already be onboarded on the workspace.')
param enableAnalytics bool = true

@description('Minimum SQL Server Audit failed logins in a 15-minute window from one client against one account.')
@minValue(2)
param failedLoginThreshold int = 5

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

// Embed the parser so scheduled rules do not depend on saved-function deployment order.
// Its local alias must differ from the published DojoSqlAudit workspace function.
var parserQuery = loadTextContent('queries/DojoSqlAudit.kql')
var queryPrefix = 'let DojoSqlAuditInline = (VmResourceId:string) {\n${parserQuery}\n};\nDojoSqlAuditInline(base64_decode_tostring(\'${base64(sqlVmResourceId)}\'))\n'

var detections = [
  {
    key: 'login-changes'
    displayName: 'Dojo SQL - login enabled, disabled, renamed or password changed'
    description: 'SQL Server Audit login changes, including the renamed built-in administrator. Includes failed attempts; inspect Outcome. Legitimate portal operations and bootstrap also trigger this training detection.'
    severity: 'High'
    tactics: ['Persistence', 'PrivilegeEscalation']
    techniques: ['T1098']
    filter: '''
| where TimeGenerated > ago(1h) and IngestedAt > ago(5m)
| where EventID == 33205
| where Operation in ('Login enabled', 'Login disabled', 'Login password changed', 'Login renamed')
  '''
  }
  {
    key: 'admin-login'
    displayName: 'Dojo SQL - built-in administrator login succeeded'
    description: 'Successful SQL Server Audit authentication by the built-in administrator SID, including renamed accounts. Name fallback only applies when the SID is absent.'
    severity: 'High'
    tactics: ['InitialAccess']
    techniques: ['T1078']
    filter: '''
| where TimeGenerated > ago(1h) and IngestedAt > ago(5m)
| where EventID == 33205 and Operation == 'Login succeeded' and Succeeded == true
| where IsBuiltInAdminActor
  '''
  }
  {
    key: 'failed-logins'
    displayName: 'Dojo SQL - repeated failed logins'
    description: 'Repeated failed SQL Server Audit authentications per VM, principal and client over 15 minutes. Uses 33205 only to avoid counting the same attempt again as instance event 18456. Retriggers while a burst continues.'
    severity: 'Medium'
    tactics: ['CredentialAccess']
    techniques: ['T1110']
    filter: replace('''
| where TimeGenerated > ago(15m)
| where EventID == 33205 and Operation == 'Login failed'
| summarize Attempts = count(), FirstSeen = min(TimeGenerated), TimeGenerated = max(TimeGenerated), LastIngested = max(IngestedAt) by Computer, Actor, ClientAddress, _ResourceId
  | where Attempts >= FAILED_LOGIN_THRESHOLD and LastIngested > ago(5m)
| extend Operation = 'Repeated failed logins', Outcome = 'Failed', TargetLogin = Actor, ActionId = 'LGIF', EventID = 33205
  ''', 'FAILED_LOGIN_THRESHOLD', string(failedLoginThreshold))
  }
  {
    key: 'audit-changes'
    displayName: 'Dojo SQL - audit configuration changed'
    description: 'SQL audit creation, alteration or removal. Review authorized bootstrap changes before escalating; ingestion silence is not proof that auditing remains enabled.'
    severity: 'High'
    tactics: ['DefenseEvasion']
    techniques: ['T1562']
    filter: '''
| where TimeGenerated > ago(1h) and IngestedAt > ago(5m)
| where EventID == 33205 and Operation == 'Audit configuration changed'
  '''
  }
]

resource parser 'Microsoft.OperationalInsights/workspaces/savedSearches@2025-07-01' = {
  parent: workspace
  name: 'DojoSqlAudit'
  properties: {
    category: 'Dojo SQL'
    displayName: 'Dojo SQL audit events'
    functionAlias: 'DojoSqlAudit'
    functionParameters: 'VmResourceId:string'
    query: loadTextContent('queries/DojoSqlAudit.kql')
    version: 1
  }
}

resource analytics 'Microsoft.SecurityInsights/alertRules@2025-09-01' = [for detection in detections: {
  scope: workspace
  name: guid(workspace.id, toLower(sqlVmResourceId), 'dojo-sql', detection.key)
  kind: 'Scheduled'
  properties: {
    displayName: '${detection.displayName} (${last(split(sqlVmResourceId, '/'))})'
    description: detection.description
    enabled: enableAnalytics
    query: '${queryPrefix}${detection.filter}'
    severity: detection.severity
    // Filters select newly ingested events within this wider event-time lookback.
    // This tolerates ordinary AMA delays without replaying the entire hour every run.
    queryFrequency: 'PT5M'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionEnabled: false
    suppressionDuration: 'PT5M'
    tactics: detection.tactics
    techniques: detection.techniques
    eventGroupingSettings: {
      aggregationKind: 'SingleAlert'
    }
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: true
        reopenClosedIncident: false
        lookbackDuration: 'PT1H'
        matchingMethod: 'AllEntities'
      }
    }
    entityMappings: [
      {
        entityType: 'Host'
        fieldMappings: [{ identifier: 'FullName', columnName: 'Computer' }]
      }
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'Name', columnName: 'Actor' }]
      }
      {
        entityType: 'AzureResource'
        fieldMappings: [{ identifier: 'ResourceId', columnName: '_ResourceId' }]
      }
    ]
    customDetails: {
      Operation: 'Operation'
      Outcome: 'Outcome'
      TargetLogin: 'TargetLogin'
      ClientAddress: 'ClientAddress'
      ActionId: 'ActionId'
      EventID: 'EventID'
    }
  }
}]

var huntFilter = '''
| where TimeGenerated > ago(24h)
| where Operation in ('Login enabled', 'Login disabled', 'Login password changed', 'Login renamed', 'Audit configuration changed')
| order by TimeGenerated desc
'''

resource hunt 'Microsoft.OperationalInsights/workspaces/savedSearches@2025-07-01' = {
  parent: workspace
  name: guid(workspace.id, toLower(sqlVmResourceId), 'dojo-sql-hunt')
  properties: {
    category: 'Hunting Queries'
    displayName: 'Dojo SQL - login change timeline (${last(split(sqlVmResourceId, '/'))})'
    query: '${queryPrefix}${huntFilter}'
    version: 1
    tags: [{ name: 'tactics', value: 'Persistence' }]
  }
}

var healthFilter = '''
| where TimeGenerated > ago(24h)
| summarize Events = count(), LastEvent = max(TimeGenerated), LastIngested = max(IngestedAt) by Computer, EventID, ActionId, Operation
| order by LastEvent desc
'''

resource health 'Microsoft.OperationalInsights/workspaces/savedSearches@2025-07-01' = {
  parent: workspace
  name: guid(workspace.id, toLower(sqlVmResourceId), 'dojo-sql-health')
  properties: {
    category: 'Dojo SQL'
    displayName: 'Dojo SQL - ingestion health (${last(split(sqlVmResourceId, '/'))})'
    query: '${queryPrefix}${healthFilter}'
    version: 1
  }
}

output parserName string = parser.name
output monitoredSqlVm string = sqlVmResourceId
output ruleIds array = [for (detection, index) in detections: analytics[index].id]
output huntingQueryId string = hunt.id
output healthQueryId string = health.id

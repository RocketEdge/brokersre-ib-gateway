// Data collection rule for the Logs Ingestion API, plus the one role assignment that lets the
// shipper write to it.
//
// Purpose   Declare the three input streams Vector sends and route each, unchanged, to the
//           table of the same name. Kind Direct gives the rule its own logs ingestion endpoint,
//           so no data collection endpoint is needed; with usePrivateLink a data collection
//           endpoint with public access disabled is created instead and the rule uses it.
// Contract  Stream columns are LITERALS and must equal the table columns in tables.bicep and
//           the rows azure/vector/vector.yaml emits (azure/tests/run.sh, group drift).
//           transformKql is `source`: redaction and mapping happen on the host, before
//           anything leaves it, never in Azure.
// Security  The role assignment grants Monitoring Metrics Publisher on THIS rule only: the
//           principal can send rows to these three streams and nothing else (it cannot read
//           the workspace). No other principal is granted anything.
// Outputs   The endpoint and the immutable id the shipper needs, and the rule's resource id.

targetScope = 'resourceGroup'

@description('Azure region of the rule. Must be the region of the destination workspace.')
param location string

@description('Name of the data collection rule.')
@minLength(3)
@maxLength(64)
param ruleName string

@description('Resource id of the Log Analytics workspace that holds IbGwEvents_CL, IbGwMetrics_CL and IBGatewayLogs_CL.')
param workspaceResourceId string

@description('false (default): a rule of kind Direct with its own public logs ingestion endpoint (Entra ID authentication, TLS). true: a data collection endpoint with public network access disabled is created and the rule ingests through it; you then add that endpoint and the workspace to your own Azure Monitor Private Link Scope.')
param usePrivateLink bool = false

@description('Object (principal) id of the identity that ships the logs: the managed identity of the VM, or the service principal of the Entra application. Empty: no role is assigned here (assign Monitoring Metrics Publisher on the rule yourself, or let vm.bicep do it for its VM).')
param ingestPrincipalId string = ''

@description('Type of ingestPrincipalId. ServicePrincipal covers managed identities and Entra applications; stating it avoids a failed assignment while a new principal is still replicating.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param ingestPrincipalType string = 'ServicePrincipal'

@description('Tags applied to the rule and, when created, the data collection endpoint.')
param tags object = {}

// Built-in role Monitoring Metrics Publisher (the role the Logs Ingestion API requires).
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource endpoint 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = if (usePrivateLink) {
  name: '${ruleName}-endpoint'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

resource rule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: ruleName
  location: location
  tags: tags
  kind: usePrivateLink ? null : 'Direct'
  properties: {
    dataCollectionEndpointId: usePrivateLink ? endpoint.id : null
    streamDeclarations: {
      'Custom-IbGwEvents_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Instance', type: 'string' }
          { name: 'Host', type: 'string' }
          { name: 'BootId', type: 'string' }
          { name: 'Seq', type: 'long' }
          { name: 'Src', type: 'string' }
          { name: 'Level', type: 'string' }
          { name: 'Event', type: 'string' }
          { name: 'Msg', type: 'string' }
          { name: 'Props', type: 'dynamic' }
        ]
      }
      'Custom-IbGwMetrics_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Instance', type: 'string' }
          { name: 'Host', type: 'string' }
          { name: 'BootId', type: 'string' }
          { name: 'Seq', type: 'long' }
          { name: 'Phase', type: 'string' }
          { name: 'MemWorkingSetBytes', type: 'long' }
          { name: 'MemLimitBytes', type: 'long' }
          { name: 'OomKills', type: 'long' }
          { name: 'CpuUsageUsec', type: 'long' }
          { name: 'CpuThrottledUsec', type: 'long' }
          { name: 'Pids', type: 'long' }
          { name: 'JavaRssBytes', type: 'long' }
          { name: 'JavaThreads', type: 'long' }
          { name: 'OpenFds', type: 'long' }
          { name: 'CloseWaitSockets', type: 'long' }
          { name: 'DiskFreeBytesLogs', type: 'long' }
          { name: 'DiskFreeBytesSettings', type: 'long' }
          { name: 'DiskTotalBytesLogs', type: 'long' }
          { name: 'DiskTotalBytesSettings', type: 'long' }
        ]
      }
      'Custom-IBGatewayLogs_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'RawData', type: 'string' }
          { name: 'FilePath', type: 'string' }
          { name: 'Computer', type: 'string' }
          { name: 'Instance', type: 'string' }
          { name: 'Level', type: 'string' }
          { name: 'Code', type: 'int' }
          { name: 'Truncated', type: 'boolean' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-IbGwEvents_CL'
        ]
        destinations: [
          'workspace'
        ]
        transformKql: 'source'
        outputStream: 'Custom-IbGwEvents_CL'
      }
      {
        streams: [
          'Custom-IbGwMetrics_CL'
        ]
        destinations: [
          'workspace'
        ]
        transformKql: 'source'
        outputStream: 'Custom-IbGwMetrics_CL'
      }
      {
        streams: [
          'Custom-IBGatewayLogs_CL'
        ]
        destinations: [
          'workspace'
        ]
        transformKql: 'source'
        outputStream: 'Custom-IBGatewayLogs_CL'
      }
    ]
  }
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ingestPrincipalId)) {
  name: guid(rule.id, ingestPrincipalId, monitoringMetricsPublisherRoleId)
  scope: rule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: ingestPrincipalId
    principalType: ingestPrincipalType
  }
}

@description('Logs ingestion endpoint for DCR_LOGS_ENDPOINT: the rule\'s own endpoint, or the data collection endpoint when usePrivateLink is true.')
output logsIngestionEndpoint string = usePrivateLink ? endpoint!.properties.logsIngestion.endpoint : rule.properties.endpoints.logsIngestion

@description('Immutable id of the rule for DCR_IMMUTABLE_ID (dcr- followed by 32 hex characters).')
output immutableId string = rule.properties.immutableId

@description('Resource id of the rule; the scope of the Monitoring Metrics Publisher assignment.')
output ruleResourceId string = rule.id

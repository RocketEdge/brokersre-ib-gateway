// Azure Log Analytics pack for brokersre-ib-gateway: everything the Vector shipper needs in
// YOUR subscription, deployed with one command:
//
//   az deployment group create -g <resource group> -f azure/bicep/main.bicep \
//     -p azure/bicep/main.bicepparam
//
// Creates   a Log Analytics workspace (or uses yours), the tables IbGwEvents_CL,
//           IbGwMetrics_CL and IBGatewayLogs_CL, a data collection rule for the Logs Ingestion
//           API, one role assignment on that rule for the shipper's identity, an action group,
//           three alert rules, a workbook and a query pack.
// Access    Nothing here gives anyone but you access to anything. The only role assignment is
//           Monitoring Metrics Publisher on the data collection rule, for the principal you
//           name; it can send rows and cannot read them. No template parameter takes an IBKR
//           credential.
// Outputs   logsIngestionEndpoint, dcrImmutableId and tenantId for compose/.env, plus the
//           resource ids vm.bicep and the README refer to.
// Tests     azure/tests/run.sh compiles this file offline, compares its tables and streams
//           with the rows Vector really emits and checks every query against the schema.
//           Nothing is deployed by the tests; a what-if needs your Azure login.

targetScope = 'resourceGroup'

import { phoneReceiver } from 'modules/alerts.bicep'

@description('Azure region of everything this template creates. When existingWorkspaceId is set, this MUST be the region of that workspace: a data collection rule and its alert rules live in the region of their workspace.')
param location string = resourceGroup().location

@description('Prefix of every resource name (workspace <prefix>-logs, rule <prefix>-dcr, action group <prefix>-alerts, ...). Lower-case letters, digits and hyphens.')
@minLength(2)
@maxLength(20)
param namePrefix string = 'ibgw'

@description('Resource id of an existing Log Analytics workspace to use (/subscriptions/.../resourceGroups/.../providers/Microsoft.OperationalInsights/workspaces/<name>). Empty: a workspace named <namePrefix>-logs is created in this resource group. The tables are created in the workspace either way.')
param existingWorkspaceId string = ''

@description('Default retention in days of a newly created workspace (30 to 730). Ignored when existingWorkspaceId is set.')
@minValue(30)
@maxValue(730)
param workspaceRetentionDays int = 30

@description('Interactive retention in days of IbGwEvents_CL and IbGwMetrics_CL (4 to 730). 30 days are included in the ingestion price; longer costs extra per GB and month.')
@minValue(4)
@maxValue(730)
param interactiveRetentionDays int = 30

@description('Total retention in days of IbGwEvents_CL and IbGwMetrics_CL: interactive plus cheaper long-term retention (4 to 4383). Must not be smaller than interactiveRetentionDays.')
@minValue(4)
@maxValue(4383)
param totalRetentionDays int = 90

@description('Table plan of IBGatewayLogs_CL (redacted raw lines). Auxiliary (default) is the cheapest plan that accepts rows from a data collection rule, but it can never be changed afterwards, its queries are slower and billed per GB scanned, and alert rules cannot use it. Choose Basic or Analytics before the first deployment if you need more.')
@allowed([
  'Analytics'
  'Basic'
  'Auxiliary'
])
param rawLogsPlan string = 'Auxiliary'

@description('Total retention in days of IBGatewayLogs_CL (4 to 4383).')
@minValue(4)
@maxValue(4383)
param rawLogsTotalRetentionDays int = 30

@description('false (default): the data collection rule is of kind Direct and has its own public logs ingestion endpoint (Entra ID authentication over TLS). true: a data collection endpoint with public network access disabled is created instead; you connect it and the workspace to your own Azure Monitor Private Link Scope and private endpoint.')
param usePrivateLink bool = false

@description('Object (principal) id of the identity that ships the logs: the service principal of your Entra application (az ad sp show --id <appId> --query id) or a managed identity. It receives Monitoring Metrics Publisher on the data collection rule and nothing else. Empty: no role is assigned (vm.bicep assigns it for its own VM).')
param ingestPrincipalId string = ''

@description('Type of ingestPrincipalId: ServicePrincipal for an Entra application or a managed identity.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param ingestPrincipalType string = 'ServicePrincipal'

@description('E-mail addresses that receive every alert.')
param alertEmailReceivers string[] = []

@description('Phone numbers that receive every alert as an SMS (name, countryCode, phoneNumber). Optional.')
param alertSmsReceivers phoneReceiver[] = []

@description('Phone numbers that receive every alert as a voice call (name, countryCode, phoneNumber). Optional.')
param alertVoiceReceivers phoneReceiver[] = []

@description('HTTPS webhook URL that receives every alert in the common alert schema. Optional; treated as a secret because webhook URLs usually embed a token.')
@secure()
param alertWebhookUri string = ''

@description('Daily window in UTC (HH:mm-HH:mm, for example 03:40-04:10) around the gateway\'s daily restart: the health rule is silent and "not logged in" is not reported inside it. May cross midnight. Empty: no window. AUTO_RESTART_TIME is exchange-local, so the UTC time moves by an hour with daylight saving; make the window cover both.')
@maxLength(11)
param maintenanceWindowUtc string = ''

@description('Severity of the "human needed" rule (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityHumanNeeded int = 1

@description('Severity of the "health" rule (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityHealth int = 2

@description('Severity of the "dead man" rule (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityDeadMan int = 1

@description('Whether to create the workbook "IB Gateway".')
param deployWorkbook bool = true

@description('Whether to create the query pack <namePrefix>-queries with the documented queries of azure/kql (Logs > Queries shows them).')
param deployQueryPack bool = true

@description('Tags applied to every resource this template creates.')
param tags object = {}

var createWorkspace = empty(existingWorkspaceId)
// /subscriptions/<2>/resourceGroups/<4>/providers/Microsoft.OperationalInsights/workspaces/<8>
var existingWorkspaceParts = split(existingWorkspaceId, '/')
var workspaceSubscriptionId = createWorkspace ? subscription().subscriptionId : existingWorkspaceParts[2]
var workspaceResourceGroupName = createWorkspace ? resourceGroup().name : existingWorkspaceParts[4]
var workspaceName = createWorkspace ? '${namePrefix}-logs' : existingWorkspaceParts[8]
var workspaceResourceId = createWorkspace
  ? resourceId('Microsoft.OperationalInsights/workspaces', workspaceName)
  : existingWorkspaceId

module workspace 'modules/workspace.bicep' = if (createWorkspace) {
  params: {
    location: location
    workspaceName: workspaceName
    retentionDays: workspaceRetentionDays
    tags: tags
  }
}

module tables 'modules/tables.bicep' = {
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  // The tables do not read an output of the workspace module, so the order is stated.
  dependsOn: [
    workspace
  ]
  params: {
    workspaceName: workspaceName
    interactiveRetentionDays: interactiveRetentionDays
    totalRetentionDays: totalRetentionDays
    rawLogsPlan: rawLogsPlan
    rawLogsTotalRetentionDays: rawLogsTotalRetentionDays
  }
}

module collection 'modules/dcr.bicep' = {
  // A data flow can only target a table that exists.
  dependsOn: [
    tables
  ]
  params: {
    location: location
    ruleName: '${namePrefix}-dcr'
    workspaceResourceId: workspaceResourceId
    usePrivateLink: usePrivateLink
    ingestPrincipalId: ingestPrincipalId
    ingestPrincipalType: ingestPrincipalType
    tags: tags
  }
}

module alerts 'modules/alerts.bicep' = {
  dependsOn: [
    tables
  ]
  params: {
    location: location
    namePrefix: namePrefix
    workspaceResourceId: workspaceResourceId
    emailReceivers: alertEmailReceivers
    smsReceivers: alertSmsReceivers
    voiceReceivers: alertVoiceReceivers
    webhookUri: alertWebhookUri
    maintenanceWindowUtc: maintenanceWindowUtc
    severityHumanNeeded: severityHumanNeeded
    severityHealth: severityHealth
    severityDeadMan: severityDeadMan
    tags: tags
  }
}

module workbook 'modules/workbook.bicep' = if (deployWorkbook) {
  dependsOn: [
    tables
  ]
  params: {
    location: location
    workspaceResourceId: workspaceResourceId
    tags: tags
  }
}

module queryPack 'modules/query-pack.bicep' = if (deployQueryPack) {
  params: {
    location: location
    packName: '${namePrefix}-queries'
    tags: tags
  }
}

@description('Value for DCR_LOGS_ENDPOINT in compose/.env: the logs ingestion endpoint of the data collection rule.')
output logsIngestionEndpoint string = collection.outputs.logsIngestionEndpoint

@description('Value for DCR_IMMUTABLE_ID in compose/.env.')
output dcrImmutableId string = collection.outputs.immutableId

@description('Value for AZURE_TENANT_ID in compose/.env (certificate authentication only): the tenant of this subscription.')
output tenantId string = tenant().tenantId

@description('Resource id of the data collection rule; pass it to vm.bicep as dcrResourceId.')
output dcrResourceId string = collection.outputs.ruleResourceId

@description('Resource id of the Log Analytics workspace that holds the tables.')
output workspaceResourceId string = workspaceResourceId

@description('Resource id of the action group that the three alert rules notify.')
output actionGroupResourceId string = alerts.outputs.actionGroupResourceId

// Action group and the three log search alert rules of the IB Gateway pack.
//
// Purpose   Tell a human when a gateway needs one (rule A), is unhealthy (rule B) or went
//           silent (rule C). Each rule is one query from azure/kql/ that returns a row per
//           gateway instance and condition; the rule splits by the columns Instance and
//           Condition, alerts while a row exists and resolves by itself when it is gone.
// Why three A log search rule is billed per rule and per evaluation frequency, so the
//           conditions are consolidated: two rules every 5 minutes, one every 15 minutes.
// Contract  The queries are loaded from the .kql files at compile time. The two
//           maintenance-window lines of a query are replaced with the maintenanceWindowUtc
//           parameter; azure/tests/run.sh fails when a file no longer contains those lines.
//           Rules are created with skipQueryValidation: the tables are created in the same
//           deployment and a brand-new table is not always queryable yet; the queries are
//           checked offline against the table schema instead (azure/tests/kql-check.cs).
// Latency   Rows take seconds to a few minutes to arrive and the rules run every 5 or 15
//           minutes: these alerts are for "within a quarter of an hour", not for paging on a
//           second-factor prompt within seconds.
// Identity  The rules run with the access of whoever deployed them last (Azure's default for
//           a rule without a managed identity); that person needs read access to the workspace.

targetScope = 'resourceGroup'

@description('A phone number that receives SMS or voice notifications.')
@export()
type phoneReceiver = {
  @description('Name of the receiver, unique within the action group, for example the person on call.')
  name: string

  @description('Country calling code without the plus sign, for example 1 or 65.')
  countryCode: string

  @description('Phone number without the country calling code, digits only.')
  phoneNumber: string
}

@description('Azure region of the alert rules. Must be the region of the Log Analytics workspace.')
param location string

@description('Prefix of the resource names (action group and rules).')
@minLength(2)
@maxLength(20)
param namePrefix string

@description('Resource id of the Log Analytics workspace that holds IbGwEvents_CL and IbGwMetrics_CL; the scope of the three rules.')
param workspaceResourceId string

@description('E-mail addresses that receive every alert. May be empty when another receiver is given; with no receiver at all the alerts are only visible in the portal.')
param emailReceivers string[] = []

@description('Phone numbers that receive every alert as an SMS. Azure sends at most one SMS every five minutes per number.')
param smsReceivers phoneReceiver[] = []

@description('Phone numbers that receive every alert as a voice call. Azure places at most one call every five minutes per number.')
param voiceReceivers phoneReceiver[] = []

@description('HTTPS URL that receives every alert in the common alert schema (chat or paging webhook). Empty: no webhook. Treated as a secret because webhook URLs usually embed a token.')
@secure()
param webhookUri string = ''

@description('Daily window in UTC, written HH:mm-HH:mm (for example 03:40-04:10), in which rule B is silent and rule A does not report "not logged in": the gateway restarts once a day on purpose. The window may cross midnight. Empty: no window. AUTO_RESTART_TIME is exchange-local, so cover both its summer and winter UTC time.')
@maxLength(11)
param maintenanceWindowUtc string = ''

@description('Severity of rule A "human needed" (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityHumanNeeded int = 1

@description('Severity of rule B "health" (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityHealth int = 2

@description('Severity of rule C "dead man" (0 critical ... 4 verbose).')
@minValue(0)
@maxValue(4)
param severityDeadMan int = 1

@description('Tags applied to the action group and the rules.')
param tags object = {}

// HH:mm-HH:mm, checked by position; a malformed value stops the deployment instead of
// producing a query that fails silently at every evaluation.
var windowIsWellFormed = empty(maintenanceWindowUtc) || (length(maintenanceWindowUtc) == 11 && substring(maintenanceWindowUtc, 2, 1) == ':' && substring(maintenanceWindowUtc, 5, 1) == '-' && substring(maintenanceWindowUtc, 8, 1) == ':')
var windowParts = !windowIsWellFormed
  ? fail('maintenanceWindowUtc must be empty or look like 03:40-04:10 (HH:mm-HH:mm, UTC).')
  : empty(maintenanceWindowUtc) ? ['00:00', '00:00'] : split(maintenanceWindowUtc, '-')

// The exact lines the .kql files carry, and what replaces them.
var defaultStartLine = 'let maintenance_start = time(00:00:00);'
var defaultEndLine = 'let maintenance_end = time(00:00:00);'
var startLine = 'let maintenance_start = time(${windowParts[0]}:00);'
var endLine = 'let maintenance_end = time(${windowParts[1]}:00);'

var humanNeededQuery = replace(replace(loadTextContent('../../kql/alert-human-needed.kql'), defaultStartLine, startLine), defaultEndLine, endLine)
var healthQuery = replace(replace(loadTextContent('../../kql/alert-health.kql'), defaultStartLine, startLine), defaultEndLine, endLine)
var deadManQuery = loadTextContent('../../kql/alert-dead-man.kql')

// Every rule splits by gateway instance and by the condition the query reports.
var splitByInstanceAndCondition = [
  {
    name: 'Instance'
    operator: 'Include'
    values: [
      '*'
    ]
  }
  {
    name: 'Condition'
    operator: 'Include'
    values: [
      '*'
    ]
  }
]

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-alerts'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(namePrefix, 12)
    enabled: true
    emailReceivers: [
      for (address, index) in emailReceivers: {
        name: 'email-${index}'
        emailAddress: address
        useCommonAlertSchema: true
      }
    ]
    smsReceivers: [
      for receiver in smsReceivers: {
        name: receiver.name
        countryCode: receiver.countryCode
        phoneNumber: receiver.phoneNumber
      }
    ]
    voiceReceivers: [
      for receiver in voiceReceivers: {
        name: receiver.name
        countryCode: receiver.countryCode
        phoneNumber: receiver.phoneNumber
      }
    ]
    webhookReceivers: empty(webhookUri)
      ? []
      : [
          {
            name: 'webhook'
            serviceUri: webhookUri
            useCommonAlertSchema: true
          }
        ]
  }
}

resource humanNeeded 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = {
  name: '${namePrefix}-alert-human-needed'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'IB Gateway: human needed'
    description: 'A gateway has been waiting for a second factor or in phase needs-human for more than 5 minutes, or has not been logged in for more than 10 minutes outside the maintenance window. Dimension Condition says which: twofa_pending (approve the IBKR Mobile prompt), needs_human (look at the gateway through VNC), not_logged_in (check the events of the instance). Query: azure/kql/alert-human-needed.kql.'
    enabled: true
    severity: severityHumanNeeded
    scopes: [
      workspaceResourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    autoMitigate: true
    skipQueryValidation: true
    checkWorkspaceAlertsStorageConfigured: false
    criteria: {
      allOf: [
        {
          query: humanNeededQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: splitByInstanceAndCondition
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource health 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = {
  name: '${namePrefix}-alert-health'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'IB Gateway: health'
    description: 'A gateway is unhealthy. Dimension Condition says how: connectivity_lost (IB API code 1100 three times in 15 minutes), memory_high (working set above 85 % of the container limit for 10 minutes), restart_loop (3 container starts in 30 minutes), oom_kill, disk_low. Silent during the maintenance window. Nothing is restarted automatically: a restart forces a new login and a second factor. Query: azure/kql/alert-health.kql.'
    enabled: true
    severity: severityHealth
    scopes: [
      workspaceResourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    autoMitigate: true
    skipQueryValidation: true
    checkWorkspaceAlertsStorageConfigured: false
    criteria: {
      allOf: [
        {
          query: healthQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: splitByInstanceAndCondition
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource deadMan 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = {
  name: '${namePrefix}-alert-dead-man'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'IB Gateway: dead man (no metrics arriving)'
    description: 'No metrics row of a gateway instance has arrived for more than 10 minutes: the gateway container, the Vector shipper, the host or the network path to Azure is down. The gateway writes a sample every 30 seconds, so silence is never normal. An instance is remembered for two days after its last row. Query: azure/kql/alert-dead-man.kql.'
    enabled: true
    severity: severityDeadMan
    scopes: [
      workspaceResourceId
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    // The query must see instances that have been silent for longer than the window.
    overrideQueryTimeRange: 'P2D'
    autoMitigate: true
    skipQueryValidation: true
    checkWorkspaceAlertsStorageConfigured: false
    criteria: {
      allOf: [
        {
          query: deadManQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: splitByInstanceAndCondition
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

@description('Resource id of the action group; add or change receivers there.')
output actionGroupResourceId string = actionGroup.id

@description('Resource ids of the three alert rules, in the order human needed, health, dead man.')
output alertRuleResourceIds array = [
  humanNeeded.id
  health.id
  deadMan.id
]

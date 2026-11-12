// Action group and the three log search alert rules of the IB Gateway pack.
//
// Purpose   Tell a human when a gateway needs one (rule A), is unhealthy (rule B) or went
//           silent (rule C). Each rule is one query from azure/kql/ that returns a row per
//           gateway and condition; the rule splits by the columns its query declares
//           (Instance and Condition for rule B; Instance, Host and Condition for rules A and
//           C), alerts while a row exists and resolves by itself when it is gone.
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

// HH:mm-HH:mm with real times of day, checked completely: a malformed value stops the
// deployment instead of producing a query that fails silently at every evaluation (the
// rules are created without query validation). Plain variables on purpose: no user-defined
// function, so nothing here depends on what a nested function may call.
var windowHasLength = length(maintenanceWindowUtc) == 11
var windowSeparators = windowHasLength
  ? '${substring(maintenanceWindowUtc, 2, 1)}${substring(maintenanceWindowUtc, 5, 1)}${substring(maintenanceWindowUtc, 8, 1)}'
  : ''
var windowDigits = windowHasLength
  ? '${substring(maintenanceWindowUtc, 0, 2)}${substring(maintenanceWindowUtc, 3, 2)}${substring(maintenanceWindowUtc, 6, 2)}${substring(maintenanceWindowUtc, 9, 2)}'
  : 'x'
var windowIsNumeric = empty(reduce(
  ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'],
  windowDigits,
  (rest, digit) => replace(rest, digit, '')
))
var windowIsWellFormed = empty(maintenanceWindowUtc) || (windowSeparators == ':-:' && windowIsNumeric
  ? int(substring(windowDigits, 0, 2)) <= 23 && int(substring(windowDigits, 2, 2)) <= 59 && int(substring(windowDigits, 4, 2)) <= 23 && int(substring(windowDigits, 6, 2)) <= 59
  : false)
var windowParts = !windowIsWellFormed
  ? fail('maintenanceWindowUtc must be empty or two times of day in UTC written HH:mm-HH:mm, for example 03:40-04:10.')
  : empty(maintenanceWindowUtc) ? ['00:00', '00:00'] : split(maintenanceWindowUtc, '-')

// The exact lines the .kql files carry, and what replaces them.
var defaultStartLine = 'let maintenance_start = time(00:00:00);'
var defaultEndLine = 'let maintenance_end = time(00:00:00);'
var startLine = 'let maintenance_start = time(${windowParts[0]}:00);'
var endLine = 'let maintenance_end = time(${windowParts[1]}:00);'

var humanNeededQuery = replace(replace(loadTextContent('../../kql/alert-human-needed.kql'), defaultStartLine, startLine), defaultEndLine, endLine)
var healthQuery = replace(replace(loadTextContent('../../kql/alert-health.kql'), defaultStartLine, startLine), defaultEndLine, endLine)
var deadManQuery = loadTextContent('../../kql/alert-dead-man.kql')

// Dimensions. Each .kql file states the dimensions of its rule in a "// Dimensions:" line;
// azure/tests/template-checks.jq fails when a rule here splits by anything else.
// Rule B splits by gateway instance and by the condition the query reports.
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
// Rules A and C also split by host: they answer "is THIS gateway alive and logged in", and
// two gateways that share an instance label on different hosts must not hide each other.
var splitByInstanceHostAndCondition = [
  {
    name: 'Instance'
    operator: 'Include'
    values: [
      '*'
    ]
  }
  {
    name: 'Host'
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
    description: 'A human is needed at a gateway. Dimension Condition says why: twofa_pending (a second-factor prompt has been unanswered for more than 5 minutes: approve it in IBKR Mobile; the gateway keeps asking, it never approves by itself), needs_human (the gateway asked for a human or is in phase needs-human: look at it), not_logged_in (not logged in for more than 10 minutes outside the maintenance window: check the events of the instance). Built on events, so it holds while the phase flips between 2fa-pending and login. Query: azure/kql/alert-human-needed.kql.'
    enabled: true
    severity: severityHumanNeeded
    scopes: [
      workspaceResourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    // The first unanswered prompt may be hours old; the query reads the events of the last day.
    overrideQueryTimeRange: 'P1D'
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
          dimensions: splitByInstanceHostAndCondition
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
    description: 'A gateway is unhealthy. Dimension Condition says how: memory_high (working set above 85 % of the container limit for 10 minutes), restart_loop (3 container starts in 30 minutes), oom_kill, disk_low (not followed by disk_ok), login_stalled (not followed by login_resumed), needs_human, unknown_window (IBC met a dialog it does not know). Silent during the maintenance window. Nothing is restarted automatically: a restart forces a new login and a second factor. Query: azure/kql/alert-health.kql.'
    enabled: true
    severity: severityHealth
    scopes: [
      workspaceResourceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    // disk_low and login_stalled are states reported once; the query must still see them hours later.
    overrideQueryTimeRange: 'P2D'
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
    description: 'Condition no_metrics: no metrics row of a gateway (instance and host) has arrived for more than 10 minutes: the gateway container, the Vector shipper, the host or the network path to Azure is down. Condition stale_samples: rows arrive but the newest sample is more than 10 minutes old (a backlog is being replayed, or the gateway stopped sampling). The gateway writes a sample every 30 seconds, so silence is never normal. Worst case from the last row to this alert: 25 to 30 minutes. A gateway is remembered for two days after its last row. Query: azure/kql/alert-dead-man.kql.'
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
          dimensions: splitByInstanceHostAndCondition
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

// Log Analytics query pack with the queries of azure/kql.
//
// Purpose   Put the documented queries where the desk works: Logs > Queries shows them for any
//           workspace the user can read, so nobody has to copy them out of the repository.
//           The three alert queries are included as well (to see what a rule sees).
// Contract  Every file of azure/kql is one saved query; the text is loaded at compile time, so
//           the pack cannot drift from the files (azure/tests/run.sh compares the counts).
//           A query pack grants no access to data; it only stores query text.

targetScope = 'resourceGroup'

@description('Azure region of the query pack.')
param location string

@description('Name of the query pack.')
@minLength(3)
@maxLength(63)
param packName string

@description('Tags applied to the query pack.')
param tags object = {}

// File name (without .kql), title and one-line description of every saved query.
var queries = [
  {
    id: 'session-timeline'
    title: 'IB Gateway: session timeline'
    description: 'Every stretch of time a gateway spent in one phase.'
    body: loadTextContent('../../kql/session-timeline.kql')
  }
  {
    id: 'twofa-approval-time'
    title: 'IB Gateway: second-factor approval time'
    description: 'Weekly percentiles of the time from the first second-factor request to the completed login.'
    body: loadTextContent('../../kql/twofa-approval-time.kql')
  }
  {
    id: 'monthly-uptime'
    title: 'IB Gateway: monthly uptime'
    description: 'Share of the month in phase logged-in, IBKR reset windows left out, missing data counted against uptime.'
    body: loadTextContent('../../kql/monthly-uptime.kql')
  }
  {
    id: 'sequence-gaps'
    title: 'IB Gateway: sequence gaps'
    description: 'Seq gaps per BootId: events the gateway wrote that never reached the workspace.'
    body: loadTextContent('../../kql/sequence-gaps.kql')
  }
  {
    id: 'alert-human-needed'
    title: 'IB Gateway: alert rule A, human needed'
    description: 'What the "human needed" rule evaluates: unanswered second factor, needs-human, not logged in.'
    body: loadTextContent('../../kql/alert-human-needed.kql')
  }
  {
    id: 'alert-health'
    title: 'IB Gateway: alert rule B, health'
    description: 'What the "health" rule evaluates: memory, restart loop, OOM kill, disk, stalled login, unknown window.'
    body: loadTextContent('../../kql/alert-health.kql')
  }
  {
    id: 'alert-dead-man'
    title: 'IB Gateway: alert rule C, dead man'
    description: 'What the "dead man" rule evaluates: no metrics arriving, or only stale samples.'
    body: loadTextContent('../../kql/alert-dead-man.kql')
  }
]

resource pack 'Microsoft.OperationalInsights/queryPacks@2026-03-01' = {
  name: packName
  location: location
  tags: tags
  properties: {}
}

resource savedQueries 'Microsoft.OperationalInsights/queryPacks/queries@2026-03-01' = [
  for query in queries: {
    parent: pack
    // The name of a saved query must be a GUID; derived from stable inputs so a redeployment
    // updates the same query.
    name: guid(pack.id, query.id)
    properties: {
      displayName: query.title
      description: query.description
      body: query.body
      related: {
        categories: [
          'monitor'
        ]
        resourceTypes: [
          'microsoft.operationalinsights/workspaces'
        ]
      }
      tags: {
        labels: [
          'ib-gateway'
        ]
      }
    }
  }
]

@description('Resource id of the query pack.')
output queryPackResourceId string = pack.id

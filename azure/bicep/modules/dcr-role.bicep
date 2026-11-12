// Monitoring Metrics Publisher on ONE existing data collection rule for ONE principal.
//
// Purpose   Let vm.bicep give the VM's managed identity the right to send rows to the data
//           collection rule that main.bicep created, even when the rule lives in another
//           resource group (the module is deployed at the rule's resource group).
// Contract  The assignment is scoped to the rule itself, never to a resource group or a
//           subscription. The principal can write to the rule's streams and cannot read data.
//           The name of the assignment is derived from the PRINCIPAL id: a VM that was deleted
//           and created again has a new identity, and an assignment named after the VM would
//           collide with the old one (Azure refuses to change the principal of an existing
//           assignment).

targetScope = 'resourceGroup'

@description('Name of the existing data collection rule in this resource group.')
param ruleName string

@description('Object (principal) id that receives Monitoring Metrics Publisher on the rule. It also seeds the name of the assignment.')
param principalId string

@description('Type of the principal; ServicePrincipal for a managed identity.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

// Built-in role Monitoring Metrics Publisher.
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource rule 'Microsoft.Insights/dataCollectionRules@2024-03-11' existing = {
  name: ruleName
}

resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(rule.id, principalId, monitoringMetricsPublisherRoleId)
  scope: rule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: principalId
    principalType: principalType
  }
}

@description('Resource id of the role assignment.')
output roleAssignmentId string = publisher.id

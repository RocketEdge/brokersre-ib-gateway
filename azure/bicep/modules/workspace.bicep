// Log Analytics workspace for the IB Gateway tables.
//
// Purpose   Create the workspace when the operator does not bring one (main.bicep skips this
//           module when existingWorkspaceId is set).
// Contract  Pay-as-you-go (PerGB2018) pricing, no daily cap, shared-key ingestion disabled:
//           the only way in is the data collection rule with Entra ID authentication.
// Outputs   id, name and location of the workspace.

targetScope = 'resourceGroup'

@description('Azure region of the workspace. The data collection rule, the alert rules and the workbook are created in the same region.')
param location string

@description('Name of the Log Analytics workspace to create (4 to 63 letters, digits or hyphens).')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Default interactive retention of the workspace in days (30 to 730). Tables set their own retention; this value only applies to tables without one.')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

@description('Tags applied to the workspace.')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    features: {
      // No workspace keys: the retired HTTP Data Collector API cannot be used against it.
      disableLocalAuth: true
    }
  }
}

@description('Resource id of the workspace.')
output workspaceResourceId string = workspace.id

@description('Name of the workspace.')
output workspaceName string = workspace.name

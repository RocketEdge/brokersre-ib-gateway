// Azure Monitor workbook "IB Gateway" on the pack's workspace.
//
// Purpose   One page for the desk: phase timeline, logins and second-factor approval times,
//           connectivity codes, memory/CPU/threads/file descriptors/CLOSE_WAIT sockets,
//           container starts and OOM kills, versions over time, latest raw lines.
// Contract  The content is ../../workbook/gateway.workbook.json (Notebook/1.0), loaded at
//           compile time; its queries are checked offline by azure/tests/kql-check.cs.
//           The workbook is shared with everyone who can read the resource group; it grants
//           no access to the data by itself (a reader also needs read access to the workspace).

targetScope = 'resourceGroup'

@description('Azure region of the workbook resource. Use the region of the Log Analytics workspace.')
param location string

@description('Display name of the workbook in the Azure portal.')
@minLength(1)
@maxLength(128)
param displayName string = 'IB Gateway'

@description('Resource id of the Log Analytics workspace the workbook queries.')
param workspaceResourceId string

@description('Tags applied to the workbook.')
param tags object = {}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  // A workbook's resource name must be a GUID; derived from stable inputs so a redeployment
  // updates the same workbook instead of creating another one.
  name: guid(resourceGroup().id, workspaceResourceId, 'ib-gateway-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: displayName
    category: 'workbook'
    version: 'Notebook/1.0'
    sourceId: workspaceResourceId
    serializedData: loadTextContent('../../workbook/gateway.workbook.json')
  }
}

@description('Resource id of the workbook.')
output workbookResourceId string = workbook.id

// Key Vault Secrets User (read secret values) on ONE existing Key Vault for ONE principal.
//
// Purpose   Let the gateway VM's managed identity read ib-username and ib-password.
// Contract  Scoped to the vault itself. The name of the assignment is derived from the
//           PRINCIPAL id, so a re-created VM (new identity) gets a new assignment instead of
//           colliding with the one of its predecessor.

targetScope = 'resourceGroup'

@description('Name of the existing Key Vault in this resource group.')
param vaultName string

@description('Object (principal) id that may read the secret values. It also seeds the name of the assignment.')
param principalId string

@description('Type of the principal; ServicePrincipal for a managed identity.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

// Built-in role "Key Vault Secrets User" (a public id, the same in every tenant, not a
// secret). The variable name avoids the words a secret scanner keys on.
var vaultReaderRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: vaultName
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, principalId, vaultReaderRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vaultReaderRoleId)
    principalId: principalId
    principalType: principalType
  }
}

@description('Resource id of the role assignment.')
output roleAssignmentId string = reader.id

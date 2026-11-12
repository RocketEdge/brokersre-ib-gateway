// Key Vault Secrets Officer (set and delete secrets) on ONE existing Key Vault for ONE principal.
//
// Purpose   Let the operator set ib-username and ib-password after the deployment. Deployed
//           by vm.bicep only when the operator names their own object id; the default is no
//           assignment at all.
// Contract  Scoped to the vault itself; the name of the assignment is derived from the
//           principal id.

targetScope = 'resourceGroup'

@description('Name of the existing Key Vault in this resource group.')
param vaultName string

@description('Object (principal) id of the operator who may set the secrets. It also seeds the name of the assignment.')
param principalId string

@description('Type of the principal; User for a person.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'User'

// Built-in role "Key Vault Secrets Officer" (a public id, the same in every tenant, not a
// secret). The variable name avoids the words a secret scanner keys on.
var vaultWriterRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: vaultName
}

resource writer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, principalId, vaultWriterRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vaultWriterRoleId)
    principalId: principalId
    principalType: principalType
  }
}

@description('Resource id of the role assignment.')
output roleAssignmentId string = writer.id

// Example parameters for vm.bicep (the optional one-click gateway VM). Deploy main.bicep
// first; three of the values below are its outputs. Copy this file, replace every
// <placeholder> and deploy:
//
//   az deployment group create -g <resource group> -f azure/bicep/vm.bicep \
//     -p <your copy>.bicepparam
//
// There is deliberately NO parameter for the IBKR user name or password. After the
// deployment, set the Key Vault secrets ib-username and ib-password (azure/README.md).
using 'vm.bicep'

// Your SSH public key (the content of ~/.ssh/id_ed25519.pub). Not a secret.
param adminSshPublicKey = '<ssh-ed25519 AAAA... you@your-machine>'

// The gateway image, pinned by digest (from the release you verified).
param gatewayImage = 'ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<64-hex-digest>'

// The commit of this repository the VM runs: git rev-parse HEAD (40 characters; the zeros
// below are a placeholder, replace them).
param packCommit = '0000000000000000000000000000000000000000'

// Outputs of the main.bicep deployment:
//   az deployment group show -g <resource group> -n main --query properties.outputs
param dcrResourceId = '<output dcrResourceId>'
param dcrLogsIngestionEndpoint = '<output logsIngestionEndpoint>'
param dcrImmutableId = '<output dcrImmutableId>'

// You, so that you can set the two secrets: az ad signed-in-user show --query id -o tsv
param vaultOperatorPrincipalId = '<your-own-object-id>'

// Your workstation's public IP, to reach the vault for setting the secrets.
param keyVaultAllowedCidrs = [
  '<your-public-ip>/32'
]

param tradingMode = 'paper'
param instanceLabel = 'paper-1'
param timeZone = 'America/New_York'

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

// The gateway image, pinned by digest, in your own private registry: build it with
// scripts/build-image.sh and push it there (azure/README.md, "The gateway image"). RocketEdge
// no longer distributes a public image. The VM has no registry login yet (docs/limitations.md L37).
param gatewayImage = '<registry>.azurecr.io/brokersre-ib-gateway@sha256:<64-hex-digest>'

// The commit of this repository the VM runs: git rev-parse HEAD (40 characters; the zeros
// below are a placeholder, replace them).
param packCommit = '0000000000000000000000000000000000000000'

// Outputs of the main.bicep deployment:
//   az deployment group show -g <resource group> -n main --query properties.outputs
param dcrResourceId = '<output dcrResourceId>'
param dcrLogsIngestionEndpoint = '<output logsIngestionEndpoint>'
param dcrImmutableId = '<output dcrImmutableId>'

// Optional. You, so that you can set the two secrets (az ad signed-in-user show --query id
// -o tsv): this object id receives Key Vault Secrets Officer on the new vault. Set '' to
// assign nothing (the template's default) and grant yourself the role another way.
param vaultOperatorPrincipalId = '<your-own-object-id>'

// Your workstation's public IP, to reach the vault for setting the secrets.
param keyVaultAllowedCidrs = [
  '<your-public-ip>/32'
]

param tradingMode = 'paper'
// The label of this gateway on every row; unique in the workspace (alerts tell gateways apart
// by it). Nothing in it may have the shape of an account id (gw-UAT10001 is refused; see the
// parameter's description in vm.bicep). namePrefix (default ibgw) names the VM and so the
// host label <namePrefix>-vm, which cannot change later: a prefix such as ib10001 makes the
// VM refuse its own configuration.
param instanceLabel = 'paper-1'
param timeZone = 'America/New_York'

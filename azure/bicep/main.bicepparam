// Example parameters for main.bicep. Copy this file, replace every <placeholder> and deploy:
//
//   az deployment group create -g <resource group> -f azure/bicep/main.bicep \
//     -p <your copy>.bicepparam
//
// Nothing in this file is a secret and nothing identifies a real tenant, subscription or
// person. Do not commit your filled-in copy to a public repository: object ids, e-mail
// addresses and phone numbers are yours.
using 'main.bicep'

// Prefix of every resource name.
param namePrefix = 'ibgw'

// Leave empty to create a workspace; or the resource id of your own workspace (then also set
// location to that workspace's region on the command line: -p location=<region>).
param existingWorkspaceId = ''

// Object id of the identity that ships the logs:
//   Entra application (Windows / on-premises): az ad sp show --id <appId> --query id -o tsv
//   Azure VM from vm.bicep: leave empty, vm.bicep assigns the role to its VM.
param ingestPrincipalId = '<object-id-of-the-shipper-identity-or-empty>'

// Who is told. At least one receiver, otherwise alerts are only visible in the portal.
param alertEmailReceivers = [
  '<oncall@your-domain.example>'
]

// Optional: SMS and voice. Country code without "+", number without the country code.
param alertSmsReceivers = []
param alertVoiceReceivers = []

// Daily restart of the gateway in UTC, wide enough for summer and winter time.
// Example: AUTO_RESTART_TIME 11:45 PM America/New_York = 03:45 or 04:45 UTC.
param maintenanceWindowUtc = '03:40-05:00'

// Auxiliary is the cheapest plan for the raw lines and can never be changed afterwards.
param rawLogsPlan = 'Auxiliary'

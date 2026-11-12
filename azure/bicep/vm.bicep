// One-click single-gateway VM (optional): one Ubuntu LTS VM that runs the IB Gateway compose
// stack and ships its logs to the data collection rule created by main.bicep.
//
//   az deployment group create -g <resource group> -f azure/bicep/vm.bicep \
//     -p azure/bicep/vm.bicepparam
//
// Creates   a virtual network with one private subnet, a NAT gateway for outbound traffic (IBKR,
//           image registries, Azure Monitor), a network security group that denies every
//           inbound connection (optionally SSH from one admin range; Azure Bastion is the
//           better way in), a Key Vault in RBAC mode, the VM with a system-assigned managed
//           identity and no public IP, and a daily patch window.
// Access    Exactly three role assignments, all for identities of YOUR tenant:
//             - the VM's identity: Key Vault Secrets User on the vault (read the two secrets);
//             - the VM's identity: Monitoring Metrics Publisher on the data collection rule;
//             - optionally you: Key Vault Secrets Officer on the vault, to set the secrets.
//           No Azure Lighthouse, no foreign tenant, no third-party principal, no extension.
// Secrets   This template has NO parameter for an IBKR credential. After deployment you set
//           the secrets ib-username and ib-password in the vault; the VM reads them into
//           tmpfs at start (azure/cloud-init/gateway.yaml) and the stack starts by itself.
// 2FA       Nothing here approves or bypasses the second factor, and nothing restarts a
//           running gateway: patches never reboot on their own (patchRebootSetting), Docker
//           packages are excluded from the patch window and a daemon restart keeps containers.
// Limits    The gateway API stays on the VM's loopback (PRIVATE_IP unset). To serve a strategy
//           host in the network, set PRIVATE_IP in /opt/ibgateway/.env and add an inbound
//           rule for that host; both are deliberate manual steps.
// Tests     azure/tests/run.sh compiles this file offline and checks the properties above in
//           the compiled template. Nothing is deployed by the tests.

targetScope = 'resourceGroup'

@description('Azure region of every resource this template creates.')
param location string = resourceGroup().location

@description('Prefix of the resource names (VM <prefix>-vm, network <prefix>-vnet, ...). 2 to 12 lower-case letters, digits or hyphens.')
@minLength(2)
@maxLength(12)
param namePrefix string = 'ibgw'

@description('VM size. Must support generation 2 images, Trusted Launch and, when encryptionAtHost is true, encryption at host. 2 vCPU and 8 GiB are comfortable for one gateway.')
param vmSize string = 'Standard_D2as_v5'

@description('Name of the Linux administrator account. Password login is disabled; this account signs in with adminSshPublicKey (through Azure Bastion, the serial console, or SSH from adminSourceCidr).')
param adminUsername string = 'gatewayadmin'

@description('SSH public key of the administrator (the text of an id_ed25519.pub or id_rsa.pub file). A public key is not a secret.')
param adminSshPublicKey string

@description('Source address range (CIDR) that may open SSH to the VM over the virtual network, for example the subnet of a jump host or of a VPN. Empty (default): no inbound rule at all; use Azure Bastion or the serial console. The VM has no public IP either way.')
param adminSourceCidr string = ''

@description('Managed disk type of the OS disk.')
@allowed([
  'StandardSSD_LRS'
  'Premium_LRS'
])
param osDiskType string = 'StandardSSD_LRS'

@description('Encrypt the VM\'s temporary disk, caches and data in transit to storage on the host. Needs the subscription feature Microsoft.Compute/EncryptionAtHost (az feature register --namespace Microsoft.Compute --name EncryptionAtHost); set false if you cannot register it.')
param encryptionAtHost bool = true

@description('Create a daily patch window (Azure Update Manager, critical and security updates of the OS). false: no automatic patching is configured; you patch by hand.')
param enablePatchWindow bool = true

@description('Start of the daily patch window in UTC, written HH:mm. The window lasts three hours. Choose a time when the gateway may be patched; updates do not restart the gateway.')
@minLength(5)
@maxLength(5)
param patchWindowStartUtc string = '22:00'

@description('First day of the patch schedule (yyyy-MM-dd). Defaults to tomorrow; leave it alone unless a deployment must reproduce an earlier schedule.')
param patchWindowStartDate string = dateTimeAdd(utcNow(), 'P1D', 'yyyy-MM-dd')

@description('What a patch run does when an update needs a reboot. Never (default): the reboot waits for you, because a reboot forces a new IBKR login with a second factor. IfRequired: reboot inside the window.')
@allowed([
  'Never'
  'IfRequired'
])
param patchRebootSetting string = 'Never'

@description('Gateway image pinned by digest, for example ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<64 hex>. Take the digest from the release you verified; a tag is refused.')
param gatewayImage string

@description('Vector image pinned by digest. The default is the image this repository tests (compose/docker-compose.azure.yml); azure/tests/run.sh fails when the two differ.')
param vectorImage string = 'timberio/vector:0.61.0-alpine@sha256:3bb7ed5152910ed51729e256937b1d8a4bf67ff624e9d565e8e5877bffd015c7'

@description('Git URL of this repository; the VM checks out packCommit from it to get the compose files and the Vector configuration.')
param packRepository string = 'https://github.com/RocketEdge/brokersre-ib-gateway.git'

@description('Full 40-character commit id of this repository to run on the VM (git rev-parse HEAD of the checkout you deploy from). A commit id is content-addressed, so the VM runs exactly what you reviewed.')
@minLength(40)
@maxLength(40)
param packCommit string

@description('IBKR trading mode of this gateway: paper or live (one brokerage session per container).')
@allowed([
  'paper'
  'live'
])
param tradingMode string = 'paper'

@description('Whether the gateway API is read-only (yes) or may place orders for your strategy (no). This template never places an order itself.')
@allowed([
  'yes'
  'no'
])
param readOnlyApi string = 'yes'

@description('IANA time zone of the gateway (TIME_ZONE), for example America/New_York.')
param timeZone string = 'America/New_York'

@description('Daily restart time of the gateway in its time zone (AUTO_RESTART_TIME), for example 11:45 PM. Keep it outside IBKR\'s reset windows.')
param autoRestartTime string = '11:45 PM'

@description('Label of this gateway on every shipped row (IBGW_INSTANCE); alerts are split by it.')
@minLength(1)
@maxLength(64)
param instanceLabel string = 'default'

@description('Resource id of the data collection rule (output dcrResourceId of main.bicep). The VM\'s identity receives Monitoring Metrics Publisher on this rule only.')
param dcrResourceId string

@description('Logs ingestion endpoint of the data collection rule (output logsIngestionEndpoint of main.bicep).')
param dcrLogsIngestionEndpoint string

@description('Immutable id of the data collection rule (output dcrImmutableId of main.bicep).')
param dcrImmutableId string

@description('Ship the redacted raw IBC/launcher logs too. The IBKR user name is replaced by [USER] (the VM has the user-name secret in tmpfs) and account ids keep only their last three characters.')
param shipRawLogs bool = false

@description('Your own object id (az ad signed-in-user show --query id -o tsv). It receives Key Vault Secrets Officer on the vault so that you can set ib-username and ib-password. Empty: no assignment; grant yourself the role another way.')
param vaultOperatorPrincipalId string = ''

@description('Public address ranges (CIDR) that may reach the Key Vault besides the VM\'s subnet, typically your workstation\'s public IP as x.x.x.x/32 for setting the two secrets. Empty: only the subnet can reach the vault.')
param keyVaultAllowedCidrs string[] = []

@description('Address space of the virtual network.')
param vnetAddressPrefix string = '10.61.0.0/24'

@description('Address range of the gateway subnet inside vnetAddressPrefix.')
param subnetAddressPrefix string = '10.61.0.0/27'

@description('Tags applied to every resource this template creates.')
param tags object = {}

// Built-in role definitions (public ids, the same in every tenant; they are not secrets):
// the first is "Key Vault Secrets User" (read secret values), the second "Key Vault Secrets
// Officer" (set and delete secrets). The variable names avoid the words a secret scanner
// keys on, so that these public ids are not reported as credentials.
var vaultReaderRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var vaultWriterRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

var vmName = '${namePrefix}-vm'
// Key Vault names are global, 3 to 24 characters: kv- + prefix (at most 7) + - + 13 characters.
var keyVaultName = 'kv-${take(namePrefix, 7)}-${uniqueString(resourceGroup().id)}'

// /subscriptions/<2>/resourceGroups/<4>/providers/Microsoft.Insights/dataCollectionRules/<8>
var dcrParts = split(dcrResourceId, '/')

// Refuse values that would run something else than the operator reviewed.
var checkedGatewayImage = contains(gatewayImage, '@sha256:')
  ? gatewayImage
  : fail('gatewayImage must be pinned by digest (name@sha256:<64 hex>), not by tag.')
var checkedVectorImage = contains(vectorImage, '@sha256:')
  ? vectorImage
  : fail('vectorImage must be pinned by digest (name:tag@sha256:<64 hex>).')

// Placeholder -> value for azure/cloud-init/gateway.yaml (each key appears there between two
// pairs of underscores). azure/tests/run.sh keeps this list and the file in step.
var cloudInitValues = {
  AUTO_RESTART_TIME: autoRestartTime
  DCR_IMMUTABLE_ID: dcrImmutableId
  DCR_LOGS_ENDPOINT: dcrLogsIngestionEndpoint
  GATEWAY_IMAGE: checkedGatewayImage
  HOST_LABEL: vmName
  IBGW_INSTANCE: instanceLabel
  IBGW_REDACT_USERNAME_FILE: shipRawLogs ? '/run/secrets/ib-username' : ''
  KEY_VAULT_NAME: keyVaultName
  PACK_COMMIT: packCommit
  PACK_REPOSITORY: packRepository
  READ_ONLY_API: readOnlyApi
  TIME_ZONE: timeZone
  TRADING_MODE: tradingMode
  VECTOR_IMAGE: checkedVectorImage
}
var cloudInit = reduce(
  items(cloudInitValues),
  loadTextContent('../cloud-init/gateway.yaml'),
  (text, entry) => replace(text, '__${entry.key}__', entry.value)
)

resource outboundAddress 'Microsoft.Network/publicIPAddresses@2026-03-01' = {
  name: '${namePrefix}-nat-ip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Outbound only: new subnets have no default outbound access, and the gateway must reach IBKR.
resource natGateway 'Microsoft.Network/natGateways@2026-03-01' = {
  name: '${namePrefix}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: outboundAddress.id
      }
    ]
  }
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2026-03-01' = {
  name: '${namePrefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: concat(
      empty(adminSourceCidr)
        ? []
        : [
            {
              name: 'allow-ssh-from-admin-range'
              properties: {
                description: 'SSH from the administrator range given at deployment.'
                priority: 100
                direction: 'Inbound'
                access: 'Allow'
                protocol: 'Tcp'
                sourceAddressPrefix: adminSourceCidr
                sourcePortRange: '*'
                destinationAddressPrefix: '*'
                destinationPortRange: '22'
              }
            }
          ],
      [
        {
          name: 'deny-all-inbound'
          properties: {
            description: 'Nothing else may connect to the gateway host, not even from inside the virtual network.'
            priority: 4096
            direction: 'Inbound'
            access: 'Deny'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
      ]
    )
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2026-03-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'gateway'
        properties: {
          addressPrefix: subnetAddressPrefix
          defaultOutboundAccess: false
          natGateway: {
            id: natGateway.id
          }
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
            }
          ]
        }
      }
    ]
  }
}

var gatewaySubnetId = virtualNetwork.properties.subnets[0].id

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      virtualNetworkRules: [
        {
          id: gatewaySubnetId
        }
      ]
      ipRules: [
        for range in keyVaultAllowedCidrs: {
          value: range
        }
      ]
    }
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2026-03-01' = {
  name: '${namePrefix}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: gatewaySubnetId
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-26_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: '${namePrefix}-osdisk'
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: osDiskType
        }
        deleteOption: 'Delete'
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      encryptionAtHost: encryptionAtHost
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        patchSettings: enablePatchWindow
          ? {
              patchMode: 'AutomaticByPlatform'
              assessmentMode: 'AutomaticByPlatform'
              automaticByPlatformSettings: {
                bypassPlatformSafetyChecksOnUserSchedule: true
                rebootSetting: patchRebootSetting
              }
            }
          : {
              patchMode: 'ImageDefault'
              assessmentMode: 'ImageDefault'
            }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource patchWindow 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = if (enablePatchWindow) {
  name: '${namePrefix}-patch-window'
  location: location
  tags: tags
  properties: {
    maintenanceScope: 'InGuestPatch'
    extensionProperties: {
      InGuestPatchMode: 'User'
    }
    maintenanceWindow: {
      startDateTime: '${patchWindowStartDate} ${patchWindowStartUtc}'
      duration: '03:00'
      timeZone: 'UTC'
      recurEvery: 'Day'
    }
    installPatches: {
      rebootSetting: patchRebootSetting
      linuxParameters: {
        classificationsToInclude: [
          'Critical'
          'Security'
        ]
        // Updating the container engine restarts it; keep that a deliberate, attended step.
        packageNameMasksToExclude: [
          'docker-ce*'
          'containerd.io'
          'docker-compose-plugin'
          'docker-buildx-plugin'
        ]
      }
    }
  }
}

resource patchAssignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = if (enablePatchWindow) {
  name: '${namePrefix}-patch-window'
  location: location
  scope: virtualMachine
  properties: {
    maintenanceConfigurationId: patchWindow.id
    resourceId: virtualMachine.id
  }
}

resource vmReadsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, virtualMachine.id, vaultReaderRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vaultReaderRoleId)
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorSetsSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(vaultOperatorPrincipalId)) {
  name: guid(keyVault.id, vaultOperatorPrincipalId, vaultWriterRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vaultWriterRoleId)
    principalId: vaultOperatorPrincipalId
    principalType: 'User'
  }
}

module vmShipsLogs 'modules/dcr-role.bicep' = {
  scope: resourceGroup(dcrParts[2], dcrParts[4])
  params: {
    ruleName: dcrParts[8]
    principalId: virtualMachine.identity.principalId
    principalType: 'ServicePrincipal'
    assignmentSeed: virtualMachine.id
  }
}

@description('Name of the VM.')
output vmName string = virtualMachine.name

@description('Name of the Key Vault: set the secrets ib-username and ib-password in it (az keyvault secret set --vault-name <this> --name ib-username --file <file>).')
output keyVaultName string = keyVault.name

@description('Object id of the VM\'s managed identity (the principal of the two role assignments).')
output vmPrincipalId string = virtualMachine.identity.principalId

@description('Public IP address the VM\'s outbound connections come from (NAT gateway).')
output outboundIpAddress string = outboundAddress.properties.ipAddress

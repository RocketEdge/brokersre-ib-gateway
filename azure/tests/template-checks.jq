# Security and shape checks on a COMPILED template (stdin): main.bicep with --arg which main,
# vm.bicep with --arg which vm. Output: one line per problem; no output means the template
# keeps the promises its header makes. Modules compile to nested deployments, hence the
# recursive descent. A value that is an ARM expression is a string starting with "[" and is
# checked as text.
#
# Why these checks: nobody can deploy the template where the tests run, so the properties
# that matter for access (which roles, on what, for whom), for secrets (no credential
# parameter) and for the "never restart, never expose" rules are asserted on the compiled
# output instead of being trusted from the source.

def resources: [.. | objects | select((.type? | type) == "string" and (.apiVersion? | type) == "string")];
def of_type($t): [resources[] | select(.type == $t)];
def parameters_of: [.. | objects | select(has("parameters") and has("resources")) | .parameters | to_entries[]];
def guids: [.. | strings | scan("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")] | unique;

# Built-in role definition ids, identical in every tenant.
def monitoring_metrics_publisher: "3913510d-42f4-4e42-8a64-420c390055eb";
def vault_reader_role: "4633458b-17de-408a-b874-0445c86b69e6";
def vault_writer_role: "b86a8fe4-44ce-4948-aee5-eccb2c155cd7";
# The only GUIDs main.bicep may contain: the publisher role and the ids of the two workbook
# parameters (random, they identify nothing outside the workbook). Anything else would be a
# tenant, subscription or principal id that must not be committed to a public repository.
def main_guids: [monitoring_metrics_publisher, "7b0f3c52-5f0e-4c1e-9b1a-0d6c2f1a9e01", "7b0f3c52-5f0e-4c1e-9b1a-0d6c2f1a9e02"];

def common:
  (resources[] | select(.type | startswith("Microsoft.ManagedServices")) | "Azure Lighthouse resource \(.type) must not exist"),
  (resources[] | select(.type | test("/extensions$")) | "VM extension \(.type) must not exist"),
  (parameters_of[] | select(.key | test("(?i)password|tws|ib[-_]?user|ibkr")) | "parameter \(.key) looks like an IBKR credential; the templates take none");

def main_checks:
  (of_type("Microsoft.Insights/scheduledQueryRules")) as $rules
  | (of_type("Microsoft.Authorization/roleAssignments")) as $roles
  | (of_type("Microsoft.Insights/dataCollectionRules")) as $dcr
  | (if ($rules | length) != 3 then "expected exactly 3 alert rules, found \($rules | length)" else empty end),
    (if ([$rules[].properties.evaluationFrequency] | sort) != ["PT15M", "PT5M", "PT5M"] then "alert rules must run every 5, 5 and 15 minutes" else empty end),
    ($rules[] | select(.properties.autoMitigate != true) | "alert rule \(.properties.displayName) must resolve by itself (autoMitigate)"),
    ($rules[] | select(.kind != "LogAlert") | "alert rule \(.properties.displayName) must be a log search alert"),
    ($rules[] | select((.properties.criteria.allOf | length) != 1 or (.properties.criteria.allOf[0].dimensions | tostring | contains("splitByInstanceAndCondition") | not))
      | "alert rule \(.properties.displayName) must split by the shared Instance/Condition dimensions"),
    (if ([.. | objects | select(has("splitByInstanceAndCondition")) | .splitByInstanceAndCondition | map(.name)] | first) != ["Instance", "Condition"]
      then "the alert dimensions must be Instance and Condition" else empty end),
    (if ($roles | length) != 1 then "expected exactly 1 role assignment, found \($roles | length)" else empty end),
    ($roles[] | select((.scope // "" | contains("Microsoft.Insights/dataCollectionRules")) | not) | "the role assignment must be scoped to the data collection rule"),
    (if (guids - main_guids) != [] then "unexpected GUID(s) in the template: \(guids - main_guids | join(", "))" else empty end),
    (if ($dcr | length) != 1 then "expected exactly 1 data collection rule" else empty end),
    ($dcr[] | select((.kind | tostring | contains("Direct")) | not) | "the data collection rule must be of kind Direct unless private link is asked for"),
    ($dcr[].properties.dataFlows[] | select(.transformKql != "source") | "data flow \(.outputStream) must pass rows through unchanged (redaction happens on the host)"),
    (parameters_of[] | select(.value.type == "securestring" and (.key | test("(?i)webhook") | not)) | "unexpected secure parameter \(.key)");

def vm_checks:
  (of_type("Microsoft.Compute/virtualMachines")) as $vms
  | (of_type("Microsoft.Authorization/roleAssignments")) as $roles
  | (of_type("Microsoft.KeyVault/vaults")) as $vaults
  | (if ($vms | length) != 1 then "expected exactly 1 virtual machine" else empty end),
    ($vms[] | select(.identity.type != "SystemAssigned") | "the VM must use a system-assigned managed identity"),
    ($vms[] | select(.properties.osProfile.linuxConfiguration.disablePasswordAuthentication != true) | "password login to the VM must be disabled"),
    ($vms[] | select(.properties.storageProfile.imageReference.offer != "ubuntu-26_04-lts") | "the VM image must be Ubuntu 26.04 LTS"),
    ($vms[] | select(.properties.securityProfile.securityType != "TrustedLaunch") | "the VM must use Trusted Launch"),
    (of_type("Microsoft.Network/networkInterfaces")[] | select(tostring | test("(?i)publicIPAddress")) | "the VM's network interface must not have a public IP address"),
    (of_type("Microsoft.Network/networkSecurityGroups")[] | select((.properties.securityRules | tostring | contains("deny-all-inbound")) | not) | "the network security group must deny all inbound traffic"),
    (of_type("Microsoft.Network/virtualNetworks")[].properties.subnets[] | select(.properties.defaultOutboundAccess != false or (.properties.natGateway | not)) | "the subnet must be private with a NAT gateway"),
    ($vaults[] | select(.properties.enableRbacAuthorization != true) | "the Key Vault must use RBAC authorization"),
    ($vaults[] | select(.properties.enablePurgeProtection != true) | "the Key Vault must have purge protection"),
    ($vaults[] | select(.properties.networkAcls.defaultAction != "Deny") | "the Key Vault firewall must deny by default"),
    (if ($roles | length) != 3 then "expected exactly 3 role assignments (VM reads secrets, VM ships logs, operator sets secrets), found \($roles | length)" else empty end),
    (if (guids - [monitoring_metrics_publisher, vault_reader_role, vault_writer_role]) != []
      then "unexpected GUID(s) in the template: \(guids - [monitoring_metrics_publisher, vault_reader_role, vault_writer_role] | join(", "))" else empty end),
    (parameters_of[] | select(.value.type == "securestring") | "the VM template must not need a secret parameter, found \(.key)"),
    (if (tostring | contains("packageNameMasksToExclude")) then empty else "the patch window must exclude the Docker packages" end);

[common, (if $which == "main" then main_checks elif $which == "vm" then vm_checks else "unknown template \($which)" end)]
| unique
| .[]

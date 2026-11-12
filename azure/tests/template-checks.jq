# Security and shape checks on a COMPILED template (stdin): main.bicep with --arg which main,
# vm.bicep with --arg which vm. Output: one line per problem; no output means the template
# keeps the promises its header makes. Modules compile to nested deployments, hence the
# recursive descent. A value that is an ARM expression is a string starting with "[" and is
# checked as text.
#
# Why these checks: nobody can deploy the template where the tests run, so the properties
# that matter for access (WHICH role goes to WHICH principal at WHICH scope), for secrets (no
# credential parameter), for the network (the literal rules) and for the "never restart, never
# expose" promises are asserted on the compiled output instead of being trusted from the source.

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

# "[variables('x')]" or any ARM expression -> the name of the first variable it refers to (null when none).
def first_variable: (tostring | capture("variables\\('(?<name>[^']+)'\\)").name)? // null;
# "[parameters('x')]" -> "x" (null for anything else).
def sole_parameter: (tostring | capture("^\\[parameters\\('(?<name>[^']+)'\\)\\]$").name)? // null;
# The resources a template declares itself (an array, or a map when Bicep uses symbolic names).
def direct_resources: .resources | .[];

# The variables of the alerts module (the object that holds the dimension lists and the queries).
def alert_variables: [.. | objects | select(has("splitByInstanceAndCondition"))] | first;
# The KQL text behind a query expression: follow variables down to the file loaded at compile
# time (Bicep stores it in a variable named $fxv#<n>, or directly in the variable when nothing
# is replaced in it). A value without a variable reference is the text itself.
def query_text($vars):
  . as $value
  | ($value | first_variable) as $name
  | if $name == null then $value
    elif ($name | startswith("$fxv#")) then $vars[$name]
    else ($vars[$name] | query_text($vars)) end;
# The dimensions a query file declares in its "// Dimensions: A, B" line.
def declared_dimensions: [capture("(?m)^// Dimensions: (?<list>.+)$").list | split(",")[] | gsub("^\\s+|\\s+$"; "")];

# Every role assignment of the template, wherever it is declared, as one sentence:
#   "<role> for <principal> on <scope>[ (conditional)]"
# The role is resolved through the variables of the template that declares the assignment; the
# principal through the module call when the assignment takes it as a module parameter.
def assignments_in($template; $call):
  $template | direct_resources | select(.type? == "Microsoft.Authorization/roleAssignments") | . as $assignment
  | {
      role: (($assignment.properties.roleDefinitionId | first_variable) as $name
        | if $name == null then "an unresolved role" else ($template.variables[$name] // "an unresolved role") end),
      principal: (($assignment.properties.principalId | sole_parameter) as $name
        | if $name != null and $call != null then ($call.properties.parameters[$name].value // "nothing")
          else ($assignment.properties.principalId // "nothing") end),
      scope: ($assignment.scope // "the resource group"),
      conditional: (($assignment.condition? != null) or ($call != null and $call.condition? != null))
    };
def role_name:
  if . == monitoring_metrics_publisher then "Monitoring Metrics Publisher"
  elif . == vault_reader_role then "Key Vault Secrets User"
  elif . == vault_writer_role then "Key Vault Secrets Officer"
  else "role \(.)" end;
def principal_kind:
  tostring
  | if test("reference\\(") and test("identity\\.principalId") and test("virtualMachine") then "the VM's managed identity"
    elif sole_parameter != null then "parameter \(sole_parameter)"
    else "principal \(.)" end;
def scope_kind:
  tostring
  | if test("Microsoft.KeyVault/vaults") then "the Key Vault"
    elif test("Microsoft.Insights/dataCollectionRules") then "the data collection rule"
    else "scope \(.)" end;
def role_assignments:
  . as $root
  | [ assignments_in($root; null),
      ( .. | objects
        | select(.type? == "Microsoft.Resources/deployments" and (.properties.template? | type) == "object")
        | . as $call | assignments_in($call.properties.template; $call) ) ]
  | map("\(.role | role_name) for \(.principal | principal_kind) on \(.scope | scope_kind)\(if .conditional then " (conditional)" else "" end)")
  | sort;
# expect_roles($expected): one problem line when the template assigns anything else.
def expect_roles($expected):
  role_assignments as $actual
  | if $actual == ($expected | sort) then empty
    else "the role assignments are not the promised ones. Expected: \($expected | sort | join("; ")). Found: \($actual | join("; "))" end;

def common:
  (resources[] | select(.type | startswith("Microsoft.ManagedServices")) | "Azure Lighthouse resource \(.type) must not exist"),
  (resources[] | select(.type | test("/extensions$")) | "VM extension \(.type) must not exist"),
  (parameters_of[] | select(.key | test("(?i)password|tws|ib[-_]?user|ibkr")) | "parameter \(.key) looks like an IBKR credential; the templates take none");

def main_checks:
  (of_type("Microsoft.Insights/scheduledQueryRules")) as $rules
  | (of_type("Microsoft.Insights/dataCollectionRules")) as $dcr
  | (if ($rules | length) != 3 then "expected exactly 3 alert rules, found \($rules | length)" else empty end),
    (if ([$rules[].properties.evaluationFrequency] | sort) != ["PT15M", "PT5M", "PT5M"] then "alert rules must run every 5, 5 and 15 minutes" else empty end),
    ($rules[] | select(.properties.autoMitigate != true) | "alert rule \(.properties.displayName) must resolve by itself (autoMitigate)"),
    ($rules[] | select(.kind != "LogAlert") | "alert rule \(.properties.displayName) must be a log search alert"),
    ($rules[] | select((.properties.criteria.allOf | length) != 1) | "alert rule \(.properties.displayName) must have exactly one condition"),
    # A rule must split by exactly the dimensions its query file declares ("// Dimensions: ...").
    (alert_variables as $vars
      | $rules[] | . as $rule
      | ($rule.properties.criteria.allOf[0]) as $condition
      | ($condition.query | query_text($vars) | declared_dimensions) as $declared
      | ($vars[$condition.dimensions | first_variable] | map(.name)) as $split
      | select(($declared | length) < 2 or $declared != $split)
      | "alert rule \($rule.properties.displayName) splits by [\($split | join(", "))] but its query declares [\($declared | join(", "))]"),
    expect_roles(["Monitoring Metrics Publisher for parameter ingestPrincipalId on the data collection rule (conditional)"]),
    (if (guids - main_guids) != [] then "unexpected GUID(s) in the template: \(guids - main_guids | join(", "))" else empty end),
    (if ($dcr | length) != 1 then "expected exactly 1 data collection rule" else empty end),
    ($dcr[] | select((.kind | tostring | contains("Direct")) | not) | "the data collection rule must be of kind Direct unless private link is asked for"),
    ($dcr[].properties.dataFlows[] | select(.transformKql != "source") | "data flow \(.outputStream) must pass rows through unchanged (redaction happens on the host)"),
    (parameters_of[] | select(.value.type == "securestring" and (.key | test("(?i)webhook") | not)) | "unexpected secure parameter \(.key)");

def vm_checks:
  (of_type("Microsoft.Compute/virtualMachines")) as $vms
  | (of_type("Microsoft.KeyVault/vaults")) as $vaults
  | (of_type("Microsoft.Network/networkSecurityGroups")) as $groups
  | (of_type("Microsoft.Network/networkSecurityGroups/securityRules")) as $extra_rules
  | (if ($vms | length) != 1 then "expected exactly 1 virtual machine" else empty end),
    ($vms[] | select(.identity.type != "SystemAssigned") | "the VM must use a system-assigned managed identity"),
    ($vms[] | select(.properties.osProfile.linuxConfiguration.disablePasswordAuthentication != true) | "password login to the VM must be disabled"),
    ($vms[] | select(.properties.storageProfile.imageReference.offer != "ubuntu-26_04-lts") | "the VM image must be Ubuntu 26.04 LTS"),
    ($vms[] | select(.properties.securityProfile.securityType != "TrustedLaunch") | "the VM must use Trusted Launch"),
    # customData cannot change on an existing VM, so it must not depend on any parameter;
    # everything changeable travels in userData.
    ($vms[] | select(.properties.osProfile.customData | tostring | test("parameters\\(|replace\\(|format\\(|reduce\\("))
      | "customData must be a fixed file: it must not depend on a parameter"),
    ($vms[] | select((.properties.userData | tostring | test("vmConfig")) | not) | "the changeable settings must be in the VM's userData"),
    (of_type("Microsoft.Network/networkInterfaces")[] | select(tostring | test("(?i)publicIPAddress")) | "the VM's network interface must not have a public IP address"),
    # The network rules, literally: one inline rule that denies everything inbound, and at
    # most one more rule, SSH from the administrator range, deployed only on request.
    (if ($groups | length) != 1 then "expected exactly 1 network security group" else empty end),
    ($groups[] | .properties.securityRules as $inline
      | select(($inline | type) != "array" or ($inline | length) != 1
          or ($inline[0].properties | (.access != "Deny" or .direction != "Inbound" or .protocol != "*"
              or .sourceAddressPrefix != "*" or .sourcePortRange != "*"
              or .destinationAddressPrefix != "*" or .destinationPortRange != "*")))
      | "the network security group must carry exactly one inline rule, and it must deny every inbound connection"),
    (if ($extra_rules | length) > 1 then "at most one additional network rule may exist" else empty end),
    ($extra_rules[] | select(.condition == null or (.properties | (.access != "Allow" or .direction != "Inbound"
          or .protocol != "Tcp" or .destinationPortRange != "22" or .sourceAddressPrefix != "[parameters('adminSourceCidr')]")))
      | "the only rule that may allow traffic is SSH (22/tcp) from adminSourceCidr, deployed only when that parameter is set"),
    (of_type("Microsoft.Network/virtualNetworks")[].properties.subnets[] | select(.properties.defaultOutboundAccess != false or (.properties.natGateway | not)) | "the subnet must be private with a NAT gateway"),
    ($vaults[] | select(.properties.enableRbacAuthorization != true) | "the Key Vault must use RBAC authorization"),
    ($vaults[] | select(.properties.enablePurgeProtection != true) | "the Key Vault must have purge protection"),
    ($vaults[] | select(.properties.networkAcls.defaultAction != "Deny") | "the Key Vault firewall must deny by default"),
    expect_roles([
      "Key Vault Secrets User for the VM's managed identity on the Key Vault",
      "Monitoring Metrics Publisher for the VM's managed identity on the data collection rule",
      "Key Vault Secrets Officer for parameter vaultOperatorPrincipalId on the Key Vault (conditional)"
    ]),
    (if (guids - [monitoring_metrics_publisher, vault_reader_role, vault_writer_role]) != []
      then "unexpected GUID(s) in the template: \(guids - [monitoring_metrics_publisher, vault_reader_role, vault_writer_role] | join(", "))" else empty end),
    (parameters_of[] | select(.value.type == "securestring") | "the VM template must not need a secret parameter, found \(.key)"),
    (if (tostring | contains("packageNameMasksToExclude")) then empty else "the patch window must exclude the Docker packages" end);

[common, (if $which == "main" then main_checks elif $which == "vm" then vm_checks else "unknown template \($which)" end)]
| unique
| .[]

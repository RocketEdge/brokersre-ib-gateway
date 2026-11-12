# Cuts the declarations the drift check needs out of the COMPILED ARM template of
# azure/bicep/main.bicep (stdin). Modules compile to nested deployments, hence the recursive
# descent. Output: {"dcr": {"streamDeclarations", "dataFlows"}, "tables": [<schema>, ...]}.
# The columns must be literals in the Bicep modules; an ARM expression in their place would
# make this check (and a reader) unable to see the schema without deploying it.
{
  dcr: ([.. | objects | select(.type? == "Microsoft.Insights/dataCollectionRules") | .properties
         | {streamDeclarations, dataFlows}] | first),
  tables: [.. | objects | select(.type? == "Microsoft.OperationalInsights/workspaces/tables")
           | .properties.schema]
}

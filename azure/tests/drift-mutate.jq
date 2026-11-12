# Deliberately breaks the declarations (stdin: output of drift-declarations.jq) so that
# azure/tests/run.sh can prove the drift check notices each kind of defect. $name picks one.
if $name == "column_removed" then
  del(.dcr.streamDeclarations["Custom-IbGwEvents_CL"].columns[] | select(.name == "Props"))
elif $name == "column_added" then
  .dcr.streamDeclarations["Custom-IbGwMetrics_CL"].columns += [{"name": "NotEmitted", "type": "long"}]
elif $name == "column_retyped" then
  (.dcr.streamDeclarations["Custom-IbGwEvents_CL"].columns[] | select(.name == "Seq") | .type) = "string"
elif $name == "table_differs" then
  (.tables[] | select(.name == "IBGatewayLogs_CL") | .columns[] | select(.name == "RawData") | .name) = "Raw"
elif $name == "flow_missing" then
  .dcr.dataFlows |= map(select(.outputStream != "Custom-IbGwMetrics_CL"))
else
  error("unknown mutation: \($name)")
end

// The three custom tables of the IB Gateway pack in an existing Log Analytics workspace.
//
// Purpose   IbGwEvents_CL and IbGwMetrics_CL (Analytics plan: alert rules and the workbook query
//           them) and IBGatewayLogs_CL (redacted raw lines; plan chosen by the operator).
// Contract  Deployed in the resource group of the workspace. Column names and types are
//           LITERALS and must equal the stream declarations in dcr.bicep and the rows that
//           azure/vector/vector.yaml emits; azure/tests/run.sh (group drift) compares the
//           compiled template with real Vector output and fails on any difference.
//           The tables API spells the date type dateTime; the DCR spells it datetime.
// Change    Add a column here and in dcr.bicep, deploy, wait a few minutes for the schema to
//           propagate, then let Vector emit it. Never rename or retype a column in place.
// Limits    An Auxiliary table cannot change its plan later (Azure refuses the update); Basic
//           and Auxiliary tables have no separate interactive retention, only total retention.

targetScope = 'resourceGroup'

@description('Name of the existing Log Analytics workspace (in this resource group) that receives the tables.')
param workspaceName string

@description('Interactive (analytics) retention in days of IbGwEvents_CL and IbGwMetrics_CL, and of IBGatewayLogs_CL when its plan is Analytics. 4 to 730; 30 days are included in the ingestion price.')
@minValue(4)
@maxValue(730)
param interactiveRetentionDays int = 30

@description('Total retention in days of IbGwEvents_CL and IbGwMetrics_CL (interactive plus long-term). Must not be smaller than interactiveRetentionDays; 4 to 4383.')
@minValue(4)
@maxValue(4383)
param totalRetentionDays int = 90

@description('Table plan of IBGatewayLogs_CL. Auxiliary is the cheapest plan that accepts rows from a data collection rule; it cannot be changed after creation, has slower queries billed per GB scanned and supports no alert rule. Basic supports simple log alerts; Analytics supports everything at the full ingestion price.')
@allowed([
  'Analytics'
  'Basic'
  'Auxiliary'
])
param rawLogsPlan string = 'Auxiliary'

@description('Total retention in days of IBGatewayLogs_CL (4 to 4383). For the Basic and Auxiliary plans this is the only retention setting.')
@minValue(4)
@maxValue(4383)
param rawLogsTotalRetentionDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: workspaceName
}

resource eventsTable 'Microsoft.OperationalInsights/workspaces/tables@2026-03-01' = {
  parent: workspace
  name: 'IbGwEvents_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: interactiveRetentionDays
    totalRetentionInDays: totalRetentionDays
    schema: {
      name: 'IbGwEvents_CL'
      description: 'IB Gateway container events: one row per line of events/events.jsonl (log contract v2).'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime', description: 'Event time (UTC) from the ts field of the event.' }
        { name: 'Instance', type: 'string', description: 'IBGW_INSTANCE label of the gateway that emitted the event.' }
        { name: 'Host', type: 'string', description: 'HOST_LABEL of the Docker host; empty when the operator did not set it.' }
        { name: 'BootId', type: 'string', description: '16 hex characters identifying one container start (boot_id).' }
        { name: 'Seq', type: 'long', description: 'Sequence number, monotonic per BootId; a gap means lost events.' }
        { name: 'Src', type: 'string', description: 'Emitting component: entrypoint, ibc, xvfb, vnc, socat, doctor or metrics.' }
        { name: 'Level', type: 'string', description: 'info, warn or error.' }
        { name: 'Event', type: 'string', description: 'snake_case event name, for example login_completed or twofa_initiated.' }
        { name: 'Phase', type: 'string', description: 'Gateway phase attached to the event, when the event carries one.' }
        { name: 'Code', type: 'int', description: 'Numeric code attached to the event, for example IB API code 1100; empty when absent.' }
        { name: 'AccountTail', type: 'string', description: 'Last three characters of an IBKR account id; the full id never leaves the host.' }
        { name: 'Msg', type: 'string', description: 'Human-readable message; never a raw IBC or Gateway line.' }
        { name: 'Props', type: 'dynamic', description: 'Every other key of the event line, kept as a JSON object.' }
      ]
    }
  }
}

resource metricsTable 'Microsoft.OperationalInsights/workspaces/tables@2026-03-01' = {
  parent: workspace
  name: 'IbGwMetrics_CL'
  // One table operation at a time: parallel writes to the tables of one workspace can conflict.
  dependsOn: [
    eventsTable
  ]
  properties: {
    plan: 'Analytics'
    retentionInDays: interactiveRetentionDays
    totalRetentionInDays: totalRetentionDays
    schema: {
      name: 'IbGwMetrics_CL'
      description: 'IB Gateway container resource samples: one row per line of metrics/metrics.jsonl (every 30 s). A value that was not measured is empty, never 0.'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime', description: 'Sample time (UTC) from the ts field of the sample.' }
        { name: 'Instance', type: 'string', description: 'IBGW_INSTANCE label of the gateway that emitted the sample.' }
        { name: 'Host', type: 'string', description: 'HOST_LABEL of the Docker host; empty when the operator did not set it.' }
        { name: 'BootId', type: 'string', description: '16 hex characters identifying one container start (boot_id).' }
        { name: 'Seq', type: 'long', description: 'Sequence number, monotonic per BootId.' }
        { name: 'Phase', type: 'string', description: 'Gateway phase when the sample was taken (logged-in, 2fa-pending, needs-human, ...).' }
        { name: 'MemWorkingSetBytes', type: 'long', description: 'Container memory working set in bytes (mem_working_set_bytes).' }
        { name: 'MemLimitBytes', type: 'long', description: 'Container memory limit in bytes (mem_limit_bytes); empty when unlimited or unknown.' }
        { name: 'OomKills', type: 'long', description: 'Cumulative OOM kills of the container cgroup (oom_kills).' }
        { name: 'CpuUsageUsec', type: 'long', description: 'Cumulative CPU time in microseconds (cpu_usage_usec).' }
        { name: 'CpuThrottledUsec', type: 'long', description: 'Cumulative throttled CPU time in microseconds (cpu_throttled_usec).' }
        { name: 'Pids', type: 'long', description: 'Number of processes and threads in the cgroup (pids).' }
        { name: 'JavaRssBytes', type: 'long', description: 'Resident set size of the Gateway JVM in bytes (java_rss_bytes).' }
        { name: 'JavaThreads', type: 'long', description: 'Thread count of the Gateway JVM (java_threads).' }
        { name: 'OpenFds', type: 'long', description: 'Open file descriptors of the Gateway JVM (open_fds).' }
        { name: 'CloseWaitSockets', type: 'long', description: 'API sockets stuck in CLOSE_WAIT (api_close_wait_sockets).' }
        { name: 'DiskFreeBytesLogs', type: 'long', description: 'Free bytes on the log volume (disk_free_bytes_logs).' }
        { name: 'DiskFreeBytesSettings', type: 'long', description: 'Free bytes on the settings volume (disk_free_bytes_settings).' }
      ]
    }
  }
}

resource rawTable 'Microsoft.OperationalInsights/workspaces/tables@2026-03-01' = {
  parent: workspace
  name: 'IBGatewayLogs_CL'
  dependsOn: [
    metricsTable
  ]
  properties: {
    plan: rawLogsPlan
    // Basic and Auxiliary tables accept only totalRetentionInDays; null omits the property.
    retentionInDays: rawLogsPlan == 'Analytics' ? interactiveRetentionDays : null
    totalRetentionInDays: rawLogsTotalRetentionDays
    schema: {
      name: 'IBGatewayLogs_CL'
      description: 'Redacted raw IBC and launcher log lines (opt-in). IBKR encrypts the Gateway logs on disk; those are not here.'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime', description: 'Time (UTC) at which the shipper read the line; the timestamp of the line itself stays inside RawData.' }
        { name: 'RawData', type: 'string', description: 'The log line after redaction, at most 32,768 bytes.' }
        { name: 'FilePath', type: 'string', description: 'Path of the source file inside the log volume.' }
        { name: 'Computer', type: 'string', description: 'HOST_LABEL of the Docker host; empty when the operator did not set it.' }
        { name: 'Instance', type: 'string', description: 'IBGW_INSTANCE label of the gateway that wrote the line.' }
        { name: 'Level', type: 'string', description: 'error or warn when the line says so; empty when the line carries no level.' }
        { name: 'Code', type: 'int', description: 'Error code found in the line (code=1100 style); empty when none.' }
        { name: 'Truncated', type: 'boolean', description: 'true when the line was longer than the limit and was cut.' }
      ]
    }
  }
}

@description('Names of the three tables, in the order events, metrics, raw logs.')
output tableNames array = [
  eventsTable.name
  metricsTable.name
  rawTable.name
]

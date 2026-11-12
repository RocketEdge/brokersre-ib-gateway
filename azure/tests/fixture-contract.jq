# Checks that fixture lines have the shape the gateway really writes (log contract v2), so
# that the tests cannot pass on a key the gateway never emits (a `code` or `phase` on an
# event, for example) and the drift test stays a statement about real input.
#
# Input   (stdin, slurped with -s): the JSON lines of the fixture files; --arg kind events|metrics.
# Output  One line per problem; no output means every line is within the contract.
# Source  The key lists were taken from real output of the gateway image and from the
#         coordinator's statement of the final contract; change them only with the contract.

def event_keys: ["ts", "src", "level", "event", "msg", "boot_id", "seq", "data"];
def event_required: ["ts", "src", "level", "event", "msg", "boot_id", "seq"];
def sources: ["entrypoint", "ibc", "xvfb", "vnc", "socat", "healthcheck", "doctor", "metrics"];
def event_names: [
  "container_start", "config_rendered", "config_custom", "config_missing", "config_conflict",
  "config_invalid", "secret_unreadable", "dirs_not_writable", "jts_ini_written", "jts_ini_kept",
  "xvfb_started", "xvfb_failed", "vnc_disabled", "vnc_enabled", "socat_started", "relay_opened",
  "relay_closed", "ibc_starting", "ibc_not_launched", "ibc_exited", "needs_human",
  "shutdown_requested", "shutdown_complete", "twofa_initiated", "twofa_dialog", "twofa_timeout",
  "login_completed", "login_failed", "login_failed_dialog", "existing_session",
  "relogin_required", "daily_restart", "login_dialog", "ibc_version", "unknown_window",
  "doctor_ok", "doctor_failed", "doctor_warning", "config_deprecated", "oom_kill", "disk_low",
  "disk_ok", "login_stalled", "login_resumed", "memory_high", "memory_ok"
];
def phases: [
  "starting", "login", "2fa-pending", "logged-in", "restarting", "existing-session",
  "needs-human", "stopping", "stopped", "exited", "test-mode"
];
def sample_required: ["ts", "src", "boot_id", "seq", "phase"];
def sample_measured: [
  "mem_working_set_bytes", "mem_limit_bytes", "oom_kills", "cpu_usage_usec",
  "cpu_throttled_usec", "pids", "java_rss_bytes", "java_threads", "open_fds",
  "api_close_wait_sockets", "disk_free_bytes_logs", "disk_free_bytes_settings",
  "disk_total_bytes_logs", "disk_total_bytes_settings"
];

def event_problems:
  . as $line
  | "seq \($line.seq // "?") of boot \($line.boot_id // "?")" as $where
  | ((keys - event_keys)[] | "\($where): key \(.) is not in the event contract"),
    ((event_required - keys)[] | "\($where): required key \(.) is missing"),
    (if (sources | index($line.src)) == null then "\($where): src \($line.src | tojson) is not a contract source" else empty end),
    (if (event_names | index($line.event)) == null then "\($where): event \($line.event | tojson) is not a contract event" else empty end),
    (if ($line.level | IN("info", "warn", "error")) then empty else "\($where): level \($line.level | tojson) is not info, warn or error" end),
    (if ($line | has("data")) and (($line.data | type) != "object" or ([$line.data[] | type] | all(. == "string") | not))
      then "\($where): data must be a flat object of strings" else empty end);

def sample_problems:
  . as $line
  | "sample \($line.seq // "?")" as $where
  | ((keys - (sample_required + sample_measured))[] | "\($where): key \(.) is not in the metrics contract"),
    ((sample_required - keys)[] | "\($where): required key \(.) is missing"),
    (if $line.src != "metrics" then "\($where): src must be metrics" else empty end),
    (if (phases | index($line.phase)) == null then "\($where): phase \($line.phase | tojson) is not a contract phase" else empty end),
    ($line | to_entries[] | select(.key as $k | sample_measured | index($k)) | select((.value | type) != "number" or .value != (.value | floor))
      | "\($where): \(.key) must be an integer");

[ .[] | if $kind == "events" then event_problems elif $kind == "metrics" then sample_problems else "unknown kind \($kind)" end ]
| unique
| .[]

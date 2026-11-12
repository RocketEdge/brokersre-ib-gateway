#!/usr/bin/env bash
# Relay the Gateway's loopback-only API port to the container interface for the strategy host.
# IB Gateway accepts connections from TrustedIPs=127.0.0.1 only, so socat on 0.0.0.0:SOCAT_PORT
# forwards to 127.0.0.1:API_PORT. Compose binds SOCAT_PORT to a private address only.
#
# The relay follows the Gateway's phase (RELAY_MODE=gated, the default): it listens only while
# the phase is `logged-in`. A relay that listens before the Gateway is logged in accepts a
# client and then drops it, which strategy code sees as a connection reset; a closed port is a
# clean "connection refused" that every client library retries. The same applies during the
# daily restart. RELAY_MODE=always restores the old behaviour (listen from container start).
# With IBC_LAUNCH=no (offline tests) there is no login, so the relay listens at once.
#
# RELAY_ALLOW_CIDR (optional, one IPv4 network such as 172.18.0.0/16) limits who the relay
# serves. The API behind it has no authentication, so the network path is the only access
# control there is; this is a second line behind the host's port binding and firewall, not a
# replacement. socat accepts a peer outside the network and closes it at once without relaying
# a byte (observed with socat 1.8.1.1; a second `range=` option is ignored, hence one network).
# Refusals are reported as `relay_refused`, at once for the first and then at most once per
# RELAY_REFUSED_REPORT_S (default 60 s) with a count, so a port scan cannot flood the events.
# Unset, the relay is started exactly as it was before this option existed.

# State of relay_refusals_poll (one supervisor per container, so plain globals).
relay_refused_pending=0
relay_refused_last_peer=""
relay_refused_reported_at=""

# relay_wanted: true when the relay should be listening right now.
relay_wanted() {
  [ "${RELAY_MODE:-gated}" = "always" ] || [ "${IBC_LAUNCH:-yes}" = "no" ] || [ "$(current_phase)" = "logged-in" ]
}

# relay_allow_cidr_valid VALUE: true when VALUE is exactly one IPv4 network in CIDR form
# (a.b.c.d/n, each octet 0 to 255, n 0 to 32). Everything else is refused, above all a comma:
# the value becomes part of a socat address, where a comma starts another option.
relay_allow_cidr_valid() {
  local value="${1:-}" octet prefix
  local -a octets
  [[ "${value}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  octets=("${BASH_REMATCH[@]:1:4}")
  prefix="${BASH_REMATCH[5]}"
  for octet in "${octets[@]}"; do
    # 10# so that a leading zero is not read as octal.
    ((10#${octet} <= 255)) || return 1
  done
  ((10#${prefix} <= 32))
}

# relay_refusals_poll FILE NOW: report peers that socat refused because of RELAY_ALLOW_CIDR.
#
# FILE is socat's own log (-lf); NOW is the current time in whole seconds. Every call consumes
# the file (counts the refusal lines, then empties it, so it never grows without limit; socat
# appends, so emptying it is safe). The first refusal is reported at once; later ones are held
# back until RELAY_REFUSED_REPORT_S seconds (default 60) after the last report and then
# reported as one event with their count. A line written between the count and the emptying is
# lost, so the count is a lower bound. Only the peer address of a well-formed line is echoed
# (anything else becomes `unknown`): the event must never carry text a peer could shape.
# Emits `relay_refused` (warn) with data count, last_peer, allow. Always returns 0.
relay_refusals_poll() {
  local file="$1" now="$2" interval="${RELAY_REFUSED_REPORT_S:-60}" count=0 last=""
  local refusal=' W refusing connection from .* due to range option$'
  local peer=' from AF=2 ([0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]+ due to range option$'
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=60
  if [ -s "${file}" ]; then
    count="$(grep -c -a -- "${refusal}" "${file}" 2>/dev/null)" || true
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    if ((count > 0)); then
      last="$(grep -a -- "${refusal}" "${file}" 2>/dev/null | tail -n 1)" || true
      if [[ "${last}" =~ ${peer} ]]; then
        relay_refused_last_peer="${BASH_REMATCH[1]}"
      else
        relay_refused_last_peer="unknown"
      fi
      relay_refused_pending=$((relay_refused_pending + count))
    fi
    : >"${file}" 2>/dev/null || true
  fi
  ((relay_refused_pending > 0)) || return 0
  if [ -n "${relay_refused_reported_at}" ] && ((now - relay_refused_reported_at < interval)); then
    return 0
  fi
  log_event_data socat warn relay_refused \
    "$(json_object count "${relay_refused_pending}" last_peer "${relay_refused_last_peer}" allow "${RELAY_ALLOW_CIDR:-}")" \
    "refused ${relay_refused_pending} connection(s) from outside RELAY_ALLOW_CIDR (${RELAY_ALLOW_CIDR:-}); last peer ${relay_refused_last_peer}"
  relay_refused_reported_at="${now}"
  relay_refused_pending=0
  return 0
}

# relay_supervise: run until terminated; keep socat running exactly while relay_wanted.
#
# Polls every RELAY_POLL_S (default 1 s). Opening and closing emit relay_opened/relay_closed.
# A relay that exits while it is wanted is started again after SOCAT_RESTART_DELAY (default
# 5 s). Closing also ends the per-connection children socat forked, so no client keeps a
# half-dead connection to a Gateway that is restarting. TERM/INT stop the relay and return.
# With RELAY_ALLOW_CIDR set (validated by start_socat) the listener carries `range=` and
# socat logs to ${RUN_DIR}/relay.log, which relay_refusals_poll reads on every poll. When
# that file cannot be written the allowlist still applies and only the reports are lost
# (socat does not start at all with a log file it cannot open), which is said once.
relay_supervise() {
  local pid="" poll="${RELAY_POLL_S:-1}" allow="${RELAY_ALLOW_CIDR:-}" now
  local relay_log="${RUN_DIR:-/run/brokersre}/relay.log" listen="TCP-LISTEN:${SOCAT_PORT},fork,reuseaddr" suffix=""
  local -a log_option=()
  if [ -n "${allow}" ]; then
    listen+=",range=${allow}"
    suffix="; allowed peers ${allow}"
    if : >"${relay_log}" 2>/dev/null; then
      log_option=(-lf "${relay_log}")
    else
      log_event socat warn relay_log_unwritable "cannot write ${relay_log}: RELAY_ALLOW_CIDR applies, but refused peers will not be reported"
    fi
  fi
  # shellcheck disable=SC2317,SC2329  # invoked through the TERM/INT trap and from the loop
  relay_stop() {
    if [ -n "${pid}" ]; then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      pid=""
    fi
  }
  trap 'relay_stop; exit 0' TERM INT
  while true; do
    if relay_wanted; then
      if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || true
        pid=""
        log_event socat warn relay_closed "relay on ${SOCAT_PORT} exited unexpectedly; restarting it"
        sleep "${SOCAT_RESTART_DELAY:-5}" &
        wait $! 2>/dev/null || true
      fi
      if [ -z "${pid}" ]; then
        socat "${log_option[@]}" "${listen}" "TCP:127.0.0.1:${API_PORT}" >/dev/null 2>&1 &
        pid=$!
        log_event socat info relay_opened "relay listening on ${SOCAT_PORT} -> 127.0.0.1:${API_PORT}${suffix}"
      fi
    elif [ -n "${pid}" ]; then
      relay_stop
      log_event socat info relay_closed "relay on ${SOCAT_PORT} closed: the Gateway is not logged in (phase $(current_phase))"
    fi
    if [ "${#log_option[@]}" -gt 0 ]; then
      printf -v now '%(%s)T' -1
      relay_refusals_poll "${relay_log}" "${now}"
    fi
    # `sleep` in the background plus `wait` lets the TERM trap run at once.
    sleep "${poll}" &
    wait $! 2>/dev/null || true
  done
}

# start_socat: start the relay supervisor in the background. Sets SOCAT_PID (the supervisor).
# Fails with config_invalid (exit 1) when RELAY_MODE is neither `gated` nor `always`, or when
# RELAY_ALLOW_CIDR is set and is not one IPv4 network in CIDR form: a relay that silently
# ignored a mistyped allowlist would serve everyone the operator meant to keep out.
start_socat() {
  local suffix=""
  case "${RELAY_MODE:-gated}" in
    gated | always) ;;
    *)
      log_event socat error config_invalid "RELAY_MODE must be gated or always (got '${RELAY_MODE}')"
      exit 1
      ;;
  esac
  if [ -n "${RELAY_ALLOW_CIDR:-}" ]; then
    if ! relay_allow_cidr_valid "${RELAY_ALLOW_CIDR}"; then
      log_event socat error config_invalid "RELAY_ALLOW_CIDR must be one IPv4 network in CIDR form, for example 172.18.0.0/16"
      exit 1
    fi
    suffix="; allowed peers ${RELAY_ALLOW_CIDR}"
  fi
  relay_supervise &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  SOCAT_PID=$!
  log_event socat info socat_started "relay 0.0.0.0:${SOCAT_PORT} -> 127.0.0.1:${API_PORT} (${TRADING_MODE}); mode ${RELAY_MODE:-gated}${suffix}"
}

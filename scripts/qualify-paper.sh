#!/usr/bin/env bash
# Qualify an image with ONE real login to an IBKR paper account, and record the result.
#
# Usage:
#   scripts/qualify-paper.sh --image <ref> --secrets-dir <dir> [--out <dir>]
#                            [--login-timeout <s>] [--twofa-wait <s>] [--keep]
#
#   --image          image reference to qualify (pin a digest for a result worth keeping)
#   --secrets-dir    directory holding the files ib-username and ib-password (UTF-8, as for
#                    the compose example); mounted read-only, never read by this script
#   --out            directory for result.json and events.jsonl (default: ./qualify-out)
#   --login-timeout  seconds to wait for the login to finish (default 300)
#   --twofa-wait     extra seconds granted once when IBKR asks for a second factor
#                    (default 600); a person approves it, this script never does
#   --keep           leave the container and its volumes in place for inspection
#
# Purpose: nothing in CI logs in, so a Gateway or IBC change that breaks the login is otherwise
# found by users. This script starts the image in the hardened reference configuration
# (read-only root, no capabilities), lets it log in to a PAPER account once, and checks what a
# desk relies on: the phase reaches logged-in, the health check agrees, the API answers its
# handshake, the relay opens, the event sequence is complete and gap-free, no window was left
# unhandled, and a stop logs out inside the grace period.
#
# Safety rules built in (do not weaken them):
#   - exactly one login attempt per run: the container has no restart policy, a second-factor
#     timeout ends IBC, and the script never starts a second container. Wrong credentials are
#     therefore tried once, not until the account locks;
#   - the second factor is never answered, typed or bypassed: the script prints that a person
#     must approve it and waits;
#   - paper mode and the read-only API are forced; no API request is made at all (the probe is
#     the protocol handshake only), so no order can be placed, changed or cancelled;
#   - one session per username: do not run two qualifications with the same username at once;
#   - the result holds no username, password or account id.
#
# Exit status: 0 qualified; 1 not qualified (see result.json); 2 usage error.
# Needs only bash and the docker CLI on the host: JSON is built with the jq inside the image.
# QUALIFY_DOCKER_ARGS adds arguments to `docker run` (the offline test passes --network none).
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep the
# container-side paths literal and convert host paths explicitly (no-op elsewhere).
export MSYS_NO_PATHCONV=1

image="" secrets_dir="" out_dir="./qualify-out" login_timeout=300 twofa_wait=600 keep=0
usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) image="${2:-}" ;;
    --secrets-dir) secrets_dir="${2:-}" ;;
    --out) out_dir="${2:-}" ;;
    --login-timeout) login_timeout="${2:-}" ;;
    --twofa-wait) twofa_wait="${2:-}" ;;
    --keep)
      keep=1
      shift
      continue
      ;;
    *)
      echo "qualify-paper.sh: unknown argument '$1'" >&2
      usage
      ;;
  esac
  shift 2 || usage
done
[ -n "${image}" ] && [ -n "${secrets_dir}" ] || usage
if ! [[ "${login_timeout}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${twofa_wait}" =~ ^[0-9]+$ ]]; then
  echo "qualify-paper.sh: --login-timeout and --twofa-wait take whole seconds" >&2
  exit 2
fi
for f in ib-username ib-password; do
  if [ ! -s "${secrets_dir}/${f}" ]; then
    echo "qualify-paper.sh: ${secrets_dir}/${f} is missing or empty" >&2
    exit 2
  fi
done

# host_path <path>: the form of a host path that the docker CLI on this host accepts.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

mkdir -p "${out_dir}"
name="ibgw-qualify-$$"
started_epoch="${EPOCHSECONDS:-$(date +%s)}"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
checks="" # newline-separated "status<TAB>name<TAB>detail"
reason=""
twofa_prompted=false
login_seconds=""

# check <status> <name> <detail>: record one check (status is pass, fail or info) and print it.
check() {
  checks+="$1"$'\t'"$2"$'\t'"$3"$'\n'
  printf '%-5s %s: %s\n' "${1^^}" "$2" "$3"
}
in_container() { docker exec "${name}" bash -c "$1"; }
phase() { in_container 'cat /var/log/ibgateway/state/phase 2>/dev/null' 2>/dev/null || true; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" = "true" ]; }

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  if [ "${keep}" -eq 1 ]; then
    echo "kept: container ${name}, volumes ${name}-settings and ${name}-logs"
    return 0
  fi
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker volume rm "${name}-settings" "${name}-logs" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "qualifying ${image} (paper, read-only API, one login attempt)"
# shellcheck disable=SC2086  # QUALIFY_DOCKER_ARGS is a deliberate word-split list of arguments
if ! docker run -d --name "${name}" --restart no --stop-timeout 90 \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=64m --tmpfs /run/brokersre:size=16m,uid=1000,gid=1000,mode=0750 \
  -v "${name}-settings:/home/ibgateway/Jts/settings" -v "${name}-logs:/var/log/ibgateway" \
  -v "$(host_path "${secrets_dir}"):/run/secrets:ro" \
  -e TWS_USERID_FILE=/run/secrets/ib-username -e TWS_PASSWORD_FILE=/run/secrets/ib-password \
  -e TRADING_MODE=paper -e READ_ONLY_API=yes \
  -e TWOFA_TIMEOUT_ACTION=exit -e RELOGIN_AFTER_TWOFA_TIMEOUT=no \
  ${QUALIFY_DOCKER_ARGS:-} "${image}" >/dev/null; then
  reason="the container could not be started"
fi

# --- wait for the one login attempt to end, one way or the other ---------------------------
if [ -z "${reason}" ]; then
  deadline=$((SECONDS + login_timeout))
  last=""
  while true; do
    if ! running; then
      reason="the container exited before the login completed (exit code $(docker inspect -f '{{.State.ExitCode}}' "${name}" 2>/dev/null))"
      break
    fi
    now="$(phase)"
    if [ "${now}" != "${last}" ]; then
      echo "phase: ${now:-unknown}"
      last="${now}"
    fi
    case "${now}" in
      logged-in)
        login_seconds=$((${EPOCHSECONDS:-$(date +%s)} - started_epoch))
        break
        ;;
      needs-human)
        reason="IBKR rejected the login or a person is needed (phase needs-human); one attempt was made and none will follow"
        break
        ;;
      existing-session)
        reason="another session of this username exists (phase existing-session); close it or use a dedicated username"
        break
        ;;
      2fa-pending)
        if [ "${twofa_prompted}" = false ]; then
          twofa_prompted=true
          deadline=$((deadline + twofa_wait))
          echo "SECOND FACTOR: IBKR asks for a second factor. Approve it in IBKR Mobile now."
          echo "This script does not answer it and waits up to ${twofa_wait} s more."
        fi
        ;;
    esac
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      reason="the login did not complete in time (last phase: ${now:-unknown})"
      break
    fi
    sleep 2
  done
fi

# --- checks on a logged-in Gateway ------------------------------------------------------
if [ -z "${reason}" ]; then
  check pass login "phase logged-in after ${login_seconds} s"
  healthy=0
  for _ in $(seq 1 30); do
    if in_container 'TRADING_MODE=paper /usr/local/lib/brokersre/healthcheck.sh' >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 2
  done
  if [ "${healthy}" -eq 1 ]; then check pass healthcheck "healthy"; else
    check fail healthcheck "not healthy within 60 s of logging in"
    reason="${reason:-the health check did not turn healthy}"
  fi
  if handshake="$(in_container '/usr/local/lib/brokersre/api-handshake.sh 127.0.0.1 4002 10' 2>&1)"; then
    check pass api_handshake "${handshake#ok: }"
  else
    check fail api_handshake "${handshake:-no output}"
    reason="${reason:-the API did not answer its handshake}"
  fi
  if in_container 'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/4004"' 2>/dev/null; then
    check pass relay "relay port 4004 open after login"
  else
    check fail relay "relay port 4004 closed although the phase is logged-in"
    reason="${reason:-the relay did not open}"
  fi
fi

# --- evidence that is collected in every case -------------------------------------------
events_ok=0
if running || [ "$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null)" = "exited" ]; then
  if docker cp "${name}:/var/log/ibgateway/events/events.jsonl" "$(host_path "${out_dir}")/events.jsonl" >/dev/null 2>&1; then
    events_ok=1
  fi
fi
if [ "${events_ok}" -eq 1 ] && running; then
  if in_container 'jq -es "[.[].seq] == [range(1; length + 1)]" /var/log/ibgateway/events/events.jsonl' >/dev/null 2>&1; then
    check pass event_sequence "events are numbered 1..n without a gap"
  else
    check fail event_sequence "a gap or a missing seq in events.jsonl"
    reason="${reason:-the event sequence has a gap}"
  fi
  unknown="$(in_container 'jq -s "[.[] | select(.event == \"unknown_window\")] | length" /var/log/ibgateway/events/events.jsonl' 2>/dev/null || echo "?")"
  if [ "${unknown}" = "0" ]; then check pass unknown_windows "none"; else
    check fail unknown_windows "${unknown} window(s) without a handler (titles in ibc/ibc.log inside the container)"
    reason="${reason:-a window without a handler appeared}"
  fi
  if [ -z "${reason}" ]; then
    missing=""
    for e in container_start ibc_starting login_dialog login_completed relay_opened; do
      if ! in_container "jq -es --arg e ${e} 'any(.event == \$e)' /var/log/ibgateway/events/events.jsonl" >/dev/null 2>&1; then
        missing+=" ${e}"
      fi
    done
    if [ -z "${missing}" ]; then check pass expected_events "all present"; else
      check fail expected_events "missing:${missing}"
      reason="an expected event is missing:${missing}"
    fi
  fi
  written="$(docker diff "${name}" 2>/dev/null | grep -c . || true)"
  check info root_filesystem_writes "${written} path(s) changed outside the mounts (0 expected under a read-only root)"
fi

# --- graceful stop ------------------------------------------------------------------------
if running; then
  stop_start=${SECONDS}
  docker stop -t 90 "${name}" >/dev/null 2>&1 || true
  stop_seconds=$((SECONDS - stop_start))
  if docker logs "${name}" 2>&1 | grep -q '"event":"shutdown_complete"' && [ "${stop_seconds}" -le 75 ]; then
    check pass graceful_stop "shutdown_complete after ${stop_seconds} s"
  else
    check fail graceful_stop "no shutdown_complete event, or the stop took ${stop_seconds} s"
    if [ -z "${reason}" ]; then reason="the stop was not graceful"; fi
  fi
fi
if [ -n "${reason}" ] && [ -z "${login_seconds}" ]; then check fail login "${reason}"; fi

# --- result ---------------------------------------------------------------------------
result="pass"
if [ -n "${reason}" ]; then result="fail"; fi
digest="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "${image}" 2>/dev/null || true)"
gateway_version="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null | sed -n 's/^IB_GATEWAY_VERSION=//p')"
ibc_tag="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null | sed -n 's/^IBC_RELEASE_TAG=//p')"
# The image's own jq turns the collected text into JSON, so no value needs hand-escaping.
if ! printf '%s' "${checks}" | docker run --rm -i --entrypoint jq "${image}" -Rs \
  --arg image "${image}" --arg digest "${digest}" --arg gateway "${gateway_version}" --arg ibc "${ibc_tag}" \
  --arg started "${started}" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg result "${result}" --arg reason "${reason}" --arg login_seconds "${login_seconds}" \
  --argjson twofa "${twofa_prompted}" '
  {
    schema: "brokersre.qualification.v1",
    result: $result,
    reason: (if $reason == "" then null else $reason end),
    image: $image,
    image_digest: (if $digest == "" then null else $digest end),
    gateway_version: $gateway,
    ibc_release: $ibc,
    trading_mode: "paper",
    started: $started,
    finished: $finished,
    login_seconds: (if $login_seconds == "" then null else ($login_seconds | tonumber) end),
    second_factor_prompted: $twofa,
    checks: [split("\n")[] | select(length > 0) | split("\t") | {status: .[0], name: .[1], detail: .[2]}]
  }' >"${out_dir}/result.json"; then
  echo "qualify-paper.sh: could not write ${out_dir}/result.json" >&2
  exit 1
fi

echo
if [ "${result}" = "pass" ]; then
  echo "QUALIFIED: ${image} (result in ${out_dir}/result.json)"
  exit 0
fi
echo "NOT QUALIFIED: ${reason} (result in ${out_dir}/result.json)"
exit 1

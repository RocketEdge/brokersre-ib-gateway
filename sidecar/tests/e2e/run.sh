#!/usr/bin/env bash
# End-to-end check: the real gateway image and the real sidecar image together, wired the
# way the compose files wire them (the sidecar in its own network namespace, the gateway
# reachable as "ib-gateway", the log volume mounted read-only).
#
# Nothing here can reach IBKR: the Docker network is created with --internal (no route
# out), the credentials are dummies, and the gateway therefore stays in phase "login". That
# is enough to check everything short of a logged-in API: the feeds, the status document,
# the metrics, one stalled-login alert, the dead-man ping, payload hygiene, and what the
# sidecar says when the gateway container is stopped.
#
# Usage: sidecar/tests/e2e/run.sh <gateway image> <sidecar image>
# Exit code: the number of failed checks.
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1
GW_IMAGE="${1:?usage: run.sh <gateway image> <sidecar image>}"
SC_IMAGE="${2:?usage: run.sh <gateway image> <sidecar image>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=sidecar-e2e-net
GW=sidecar-e2e-gateway
SC=sidecar-e2e-sidecar
RC=sidecar-e2e-receiver
VOLUMES=(sidecar-e2e-logs sidecar-e2e-settings sidecar-e2e-state)
failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}

work="$(mktemp -d)"
mkdir -p "${work}/secrets"
cp "${here}/receiver.py" "${work}/receiver.py"
host_work="${work}"
if command -v cygpath >/dev/null 2>&1; then host_work="$(cygpath -m "${work}")"; fi

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  docker rm -f "${SC}" "${GW}" "${RC}" >/dev/null 2>&1 || true
  docker volume rm "${VOLUMES[@]}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT
docker rm -f "${SC}" "${GW}" "${RC}" >/dev/null 2>&1 || true
docker volume rm "${VOLUMES[@]}" >/dev/null 2>&1 || true
docker network rm "${NET}" >/dev/null 2>&1 || true

# Obviously fake credentials; the gateway can never use them (no route to IBKR).
printf 'dummyuser' >"${work}/secrets/ib-username"
printf 'dummypassword-not-real' >"${work}/secrets/ib-password"
printf 'http://%s:8080/hook/CANARY_URL_SECRET' "${RC}" >"${work}/secrets/webhook-url"
printf 'http://%s:8080/ping/CANARY_PING_SECRET' "${RC}" >"${work}/secrets/deadman-url"
chmod -R a+rX "${work}"

docker network create --internal "${NET}" >/dev/null
docker run -d --name "${RC}" --network "${NET}" --read-only --cap-drop ALL \
  -v "${host_work}/receiver.py:/receiver.py:ro" --entrypoint python "${SC_IMAGE}" /receiver.py >/dev/null
# The gateway, as in compose/docker-compose.example.yml; the alias is the compose service name.
docker run -d --name "${GW}" --network "${NET}" --network-alias ib-gateway \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=64m --tmpfs /run/brokersre:size=16m,uid=1000,gid=1000,mode=0750 \
  -v sidecar-e2e-settings:/home/ibgateway/Jts/settings -v sidecar-e2e-logs:/var/log/ibgateway \
  -v "${host_work}/secrets:/run/secrets:ro" \
  -e TWS_USERID_FILE=/run/secrets/ib-username -e TWS_PASSWORD_FILE=/run/secrets/ib-password \
  -e TRADING_MODE=paper -e IBGW_INSTANCE=e2e -e SAMPLE_INTERVAL_S=3 -e LOGIN_STALL_S=20 \
  -e AUTO_RESTART_TIME='11:45 PM' -e TIME_ZONE=America/New_York "${GW_IMAGE}" >/dev/null
# The sidecar, as in compose/docker-compose.sidecar.yml: its own network namespace, every
# default (GATEWAY_HOST=ib-gateway, the relay port from TRADING_MODE).
docker run -d --name "${SC}" --network "${NET}" --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --tmpfs /tmp:size=16m -v sidecar-e2e-state:/var/lib/sidecar \
  -v sidecar-e2e-logs:/var/log/ibgateway:ro -v "${host_work}/secrets:/run/secrets:ro" \
  -e TRADING_MODE=paper -e IBGW_INSTANCE=e2e -e TIME_ZONE=America/New_York \
  -e NOTIFY_WEBHOOK_URL_FILE=/run/secrets/webhook-url -e NOTIFY_ALLOW_HTTP=yes \
  -e DEADMAN_PING_URL_FILE=/run/secrets/deadman-url -e DEADMAN_PING_INTERVAL_S=10 \
  "${SC_IMAGE}" >/dev/null

# get <path>: fetch an endpoint of the sidecar from inside its container; prints "<status> <body>".
get() {
  docker exec "${SC}" python -c '
import http.client, sys
try:
    c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
    c.request("GET", sys.argv[1])
    r = c.getresponse()
    print(r.status, r.read().decode())
except Exception as e:
    print("ERR", type(e).__name__)
' "$1" 2>&1
}
# status_check <python expression over d>: true when the expression holds for /status.
status_check() {
  docker exec "${SC}" python -c '
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
d = json.loads(c.getresponse().read())
sys.exit(0 if eval(sys.argv[1]) else 1)
' "$1"
}
wait_for() { # seconds command...
  local t="$1"
  shift
  for _ in $(seq 1 "${t}"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}
# shellcheck disable=SC2329  # the next three are invoked through wait_for
livez_ok() { [[ "$(get /livez)" == 200* ]]; }
# shellcheck disable=SC2329
receiver_got() { docker logs "${RC}" 2>&1 | grep -q "$1"; }
# shellcheck disable=SC2329
gateway_stopped() { [ "$(docker inspect -f '{{.State.Status}}' "${GW}")" = "exited" ]; }
count_received() { docker logs "${RC}" 2>&1 | grep -c "$1"; }

echo "== the sidecar next to a gateway that cannot log in =="
if wait_for 60 livez_ok; then pass "sidecar /livez answers 200"; else fail "livez" "$(get /livez | head -c 200)"; fi
if wait_for 60 status_check 'd["phase"] == "login"'; then pass "the gateway reached phase login"; else fail "phase" "$(get /status | head -c 300)"; fi
ready="$(get /readyz)"
if [[ "${ready}" == "503 not_measured:"* ]]; then pass "/readyz is 503 not_measured while the gateway is not logged in"; else fail "readyz" "${ready:0:200}"; fi
boot="$(docker exec "${GW}" cat /var/log/ibgateway/state/boot_id)"
if status_check "d['boot_id'] == '${boot}' and d['instance'] == 'e2e' and d['status'] == 'not_measured' and d['network_mode'] == 'own_network'"; then
  pass "/status shows the gateway's real boot id, status not_measured and the own-network mode"
else
  fail "status" "$(get /status | head -c 500)"
fi
if status_check 'd["gateway_feed"]["feeds_seen"] and d["close_wait_sockets"] == 0 and all(not t["stalled"] for t in d["tasks"])'; then
  pass "the feeds are followed, the gateway's own socket sample is reported, no task is stalled"
else
  fail "feeds" "$(get /status | head -c 500)"
fi
metrics="$(get /metrics)"
if grep -q '^ibgw_memory_working_set_bytes ' <<<"${metrics}" && grep -q 'ibgw_phase{phase="login"} 1' <<<"${metrics}"; then
  pass "/metrics re-exports the gateway's own memory sample and the phase"
else
  fail "metrics" "$(grep -E '^ibgw_(memory|phase)' <<<"${metrics}" | head -5)"
fi
if grep -q '^ibgw_api_rtt_seconds ' <<<"${metrics}"; then fail "metrics absence" "a round-trip time is reported although nothing was measured"; else pass "an unmeasured value (API round trip) is absent from /metrics, not zero"; fi
if docker logs "${SC}" 2>&1 | grep -q '"event":"api_status_changed".*"status":"down"'; then
  fail "probe" "the probe called the API down although the gateway never logged in"
else
  pass "the closed relay port is not called down while the gateway is not logged in"
fi
if wait_for 30 receiver_got '^PING body=0 query=0$'; then pass "a dead-man ping arrived: a GET without body and without query"; else fail "dead-man" "$(docker logs "${RC}" 2>&1 | grep -v '^POST' | tail -3)"; fi

echo "== one alert for a stalled login =="
if wait_for 90 receiver_got '"class":"login_stalled"'; then
  pass "a login_stalled notification reached the receiver"
else
  fail "notification" "none; receiver saw: $(docker logs "${RC}" 2>&1 | tail -2 | cut -c1-300)"
fi
sleep 25
n="$(count_received '"class":"login_stalled"')"
if [ "${n}" = "1" ]; then pass "exactly one login_stalled notification (the gateway's event pair is the only source)"; else fail "double alert" "${n} login_stalled notifications"; fi
if status_check 'd["deadman"]["withheld"] == "alert active: login_stalled"'; then pass "the dead-man ping is withheld while the alert is active"; else fail "dead-man withheld" "$(get /status | head -c 400)"; fi
if docker logs "${RC}" 2>&1 | grep -q -e dummyuser -e dummypassword -e CANARY_URL_SECRET -e CANARY_PING_SECRET; then fail "payload hygiene" "a credential or a secret URL is in a payload"; else pass "no credential and no secret URL in any payload"; fi
if docker logs "${SC}" 2>&1 | grep -q -e dummyuser -e dummypassword -e CANARY_URL_SECRET -e CANARY_PING_SECRET; then fail "sidecar log hygiene" "a credential or a secret URL is in the sidecar's log"; else pass "no credential and no secret URL in the sidecar's own log"; fi
if docker exec "${GW}" grep -q 'dummy' /var/log/ibgateway/events/events.jsonl; then fail "gateway events" "credential in events"; else pass "the gateway's events hold no credential"; fi

echo "== the gateway container is stopped =="
docker stop -t 90 "${GW}" >/dev/null
if wait_for 30 gateway_stopped; then pass "the gateway container stopped"; else fail "stop" "$(docker inspect -f '{{.State.Status}}' "${GW}")"; fi
if wait_for 60 receiver_got '"class":"gateway_stopped"'; then
  pass "a notification IS delivered after the gateway stopped (gateway_stopped)"
else
  fail "stop notification" "none; receiver saw: $(docker logs "${RC}" 2>&1 | grep -o '"class":"[a-z_]*"' | sort | uniq -c | tr '\n' ' ')"
fi
stopped="$(docker logs "${RC}" 2>&1 | grep '"class":"gateway_stopped"' | head -1)"
if [[ "${stopped}" == *'"kind":"firing"'* && "${stopped}" == *'"severity":"info"'* ]]; then pass "a requested stop is information (the gateway logged shutdown_requested)"; else fail "stop severity" "${stopped:0:300}"; fi
if [ "$(count_received '"class":"gateway_exited"')" = "0" ]; then pass "a requested stop is not reported as an unexpected exit"; else fail "false exit" "gateway_exited was sent for a requested stop"; fi
state="$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "${SC}")"
if [ "${state}" = "running restarts=0" ] && livez_ok && status_check 'd["phase"] == "stopped"'; then
  pass "the sidecar keeps running and answering with the gateway gone (phase stopped)"
else
  fail "sidecar after stop" "${state}; $(get /status | head -c 300)"
fi

echo
echo "--- what the receiver saw:"
docker logs "${RC}" 2>&1 | grep -o '"class":"[a-z_]*","kind":"[a-z]*"\|^PING' | sort | uniq -c
echo
if [ "${failures}" -eq 0 ]; then echo "END-TO-END PASSED"; else echo "${failures} END-TO-END CHECK(S) FAILED"; fi
exit "${failures}"

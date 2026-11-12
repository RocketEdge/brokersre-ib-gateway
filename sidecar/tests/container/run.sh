#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted Python and $VAR are evaluated inside containers
# Container-level tests of the sidecar image: Docker CLI only, no IBKR credentials, no
# gateway. A temporary directory imitates the gateway's log volume (the test writes the
# phase, events and metrics files), and a second container of the same image runs a tiny
# HTTP receiver that stands in for a notification channel.
#
# Usage: IMAGE=brokersre-ib-gateway-sidecar:dev sidecar/tests/container/run.sh
# Exit code: 0 when every test passed. Each test prints PASS/FAIL with its reason.
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1
IMAGE="${IMAGE:?set IMAGE to the image under test}"
SIDECAR=sidecar-test
RECEIVER=sidecar-test-receiver
GATEWAY=sidecar-test-gateway
NETWORK=sidecar-test-net
CANARY=CANARY_WEBHOOK_PATH
failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}

work="$(mktemp -d)"
mkdir -p "${work}/volume/state" "${work}/volume/events" "${work}/volume/metrics" "${work}/secrets" "${work}/receiver"
# mktemp -d creates a 0700 directory; uid 1000 inside the container must be able to traverse
# it (bind mounts keep host permissions on Linux hosts such as the CI runner).
chmod -R 0755 "${work}"
host_work="${work}"
if command -v cygpath >/dev/null 2>&1; then host_work="$(cygpath -m "${work}")"; fi

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  docker rm -f "${SIDECAR}" "${RECEIVER}" "${GATEWAY}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT
cleanup_containers() { docker rm -f "${SIDECAR}" >/dev/null 2>&1 || true; }

# The receiver: prints every POST body on one line, answers 200.
cat >"${work}/receiver/receiver.py" <<'PY'
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        sys.stdout.write("POST " + self.path + " " + body.decode("utf-8", "replace") + "\n")
        sys.stdout.flush()
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY
printf 'http://%s:8080/hook/%s' "${RECEIVER}" "${CANARY}" >"${work}/secrets/webhook-url"
# Written with a BOM and CRLF on purpose: secret files made on Windows must work.
printf '\357\273\277CANARY_USERNAME\r\n' >"${work}/secrets/ib-username"
chmod 0644 "${work}/receiver/receiver.py" "${work}/secrets/webhook-url" "${work}/secrets/ib-username"

now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
set_phase() { # token: written atomically (temporary file + rename), like the gateway
  printf '%s\n' "$1" >"${work}/volume/state/phase.tmp"
  mv -f "${work}/volume/state/phase.tmp" "${work}/volume/state/phase"
}
add_event() { # name
  printf '{"ts":"%s","src":"ibc","level":"info","event":"%s","msg":"CANARY_USERNAME DU7654321","boot_id":"00000000000000aa","seq":%s}\n' \
    "$(now)" "$1" "${RANDOM}" >>"${work}/volume/events/events.jsonl"
}
add_metrics() {
  printf '{"ts":"%s","src":"metrics","boot_id":"00000000000000aa","seq":%s,"phase":"login","mem_working_set_bytes":500000000,"mem_limit_bytes":2000000000,"pids":140,"open_fds":300}\n' \
    "$(now)" "${RANDOM}" >>"${work}/volume/metrics/metrics.jsonl"
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
in_sidecar() { docker exec "${SIDECAR}" "$@"; }
# GET a path from inside the sidecar container with its own interpreter (the image has no curl).
http_get() { # path -> "<status> <body>"
  in_sidecar python -c '
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", sys.argv[1])
r = c.getresponse()
sys.stdout.write(str(r.status) + " " + r.read().decode())
' "$1"
}
status_field() { # key -> value of a top-level key of /status
  in_sidecar python -c '
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
print(json.loads(c.getresponse().read())[sys.argv[1]])
' "$1"
}
# shellcheck disable=SC2329  # the next three are invoked through wait_for
status_is() { [ "$(status_field status 2>/dev/null)" = "$1" ]; }
# shellcheck disable=SC2329
phase_is() { [ "$(status_field phase 2>/dev/null)" = "$1" ]; }
# shellcheck disable=SC2329
receiver_got() { docker logs "${RECEIVER}" 2>&1 | grep -q "$1"; }

run_sidecar() { # extra-docker-args...
  cleanup_containers
  docker run -d --name "${SIDECAR}" --network "${NETWORK}" \
    --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp \
    --health-interval 2s --health-timeout 3s --health-start-period 1s \
    -v "${host_work}/volume:/var/log/ibgateway:ro" \
    -v "${host_work}/secrets:/run/secrets:ro" \
    -e IBGW_INSTANCE=smoke-1 -e TRADING_MODE=paper -e TIME_ZONE=America/New_York \
    -e PROBE_INTERVAL_S=5 -e PROBE_TIMEOUT_S=2 \
    -e NOTIFY_WEBHOOK_URL_FILE=/run/secrets/webhook-url -e NOTIFY_ALLOW_HTTP=yes \
    "$@" "${IMAGE}" >/dev/null
}

echo "== structure =="
if [ "$(docker run --rm --entrypoint id "${IMAGE}" -u)" = "1000" ]; then pass "runs as uid 1000"; else fail "uid" "not 1000"; fi
labels=$(docker inspect "${IMAGE}" --format '{{index .Config.Labels "org.opencontainers.image.licenses"}}|{{index .Config.Labels "org.opencontainers.image.description"}}')
if [[ "${labels}" == MIT\|* && "${labels}" == *"trademarks of Interactive Brokers LLC"* ]]; then pass "OCI labels with licence and trademark sentence"; else fail "labels" "${labels}"; fi
if docker run --rm --entrypoint python "${IMAGE}" -c 'import pip' >/dev/null 2>&1; then fail "no pip" "pip is importable"; else pass "no pip in the runtime image"; fi
if docker run --rm --entrypoint sh "${IMAGE}" -c 'command -v curl || command -v wget || command -v ssh || command -v sudo' >/dev/null 2>&1; then fail "tools" "curl, wget, ssh or sudo present"; else pass "no curl, wget, ssh or sudo"; fi
if [ "$(docker run --rm "${IMAGE}" --version)" = "brokersre-sidecar 0.1.0" ]; then pass "entrypoint is the sidecar CLI"; else fail "entrypoint" "unexpected --version output"; fi
schema_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/schemas"
if docker run --rm "${IMAGE}" print-schema status | diff -q - "${schema_dir}/status.v1.schema.json" >/dev/null; then pass "print-schema status equals the committed schema"; else fail "schema" "image and repository schema differ"; fi
if docker run --rm -e NOTIFY_SLACK_URL=https://hooks.slack.com/"${CANARY}" "${IMAGE}" check-config >"${work}/check.out" 2>&1; then
  fail "plain secret" "a credential in a plain variable was accepted"
elif grep -q "NOTIFY_SLACK_URL_FILE" "${work}/check.out" && ! grep -q "${CANARY}" "${work}/check.out"; then
  pass "a credential in a plain variable is refused without echoing it"
else
  fail "plain secret" "$(cat "${work}/check.out")"
fi

echo "== before login =="
docker network create "${NETWORK}" >/dev/null
docker run -d --name "${RECEIVER}" --network "${NETWORK}" --read-only --cap-drop ALL \
  -v "${host_work}/receiver:/receiver:ro" --entrypoint python "${IMAGE}" /receiver/receiver.py >/dev/null
set_phase starting
add_event container_start
add_metrics
run_sidecar --tmpfs /var/lib/sidecar:uid=1000,gid=1000,mode=0750
if wait_for 30 in_sidecar brokersre-sidecar healthcheck; then pass "healthcheck command succeeds"; else
  fail "healthcheck" "never healthy"
  docker logs "${SIDECAR}" 2>&1 | tail -20
fi
if [ "$(http_get /livez)" = "200 ok" ]; then pass "/livez is 200"; else fail "/livez" "$(http_get /livez 2>&1)"; fi
if wait_for 20 phase_is starting; then pass "phase read from the volume"; else fail "phase" "$(status_field phase 2>&1)"; fi
readyz="$(http_get /readyz)"
if [[ "${readyz}" == "503 not_measured:"* ]]; then pass "/readyz is 503 not_measured before login"; else fail "/readyz" "${readyz}"; fi
if in_sidecar python -c '
import http.client, sys
from brokersre_sidecar.model.status import StatusDocument
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
document = StatusDocument.model_validate_json(c.getresponse().read())
assert document.schema_id == "brokersre.sidecar.status.v1"
assert document.instance == "smoke-1" and document.status == "not_measured"
'; then pass "/status validates against the status model (schema v1)"; else fail "/status" "invalid"; fi
if [ "$(status_field boot_id)" = "00000000000000aa" ]; then pass "events feed followed (boot id seen)"; else fail "events" "$(status_field boot_id 2>&1)"; fi
if in_sidecar python -c '
import http.client, re
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/metrics")
r = c.getresponse()
text = r.read().decode()
assert r.status == 200 and r.getheader("Content-Type").startswith("text/plain; version=0.0.4")
line = re.compile(r"^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^{}]*\})? -?[0-9.e+-]+$")
samples = [l for l in text.splitlines() if not l.startswith("#")]
assert samples and all(line.match(l) for l in samples), samples
assert "ibgw_phase{phase=\"starting\"} 1" in samples
assert "ibgw_pids 140" in samples
assert not any(l.startswith("ibgw_api_ready") for l in samples)
'; then pass "/metrics is parseable; unmeasured values are omitted"; else fail "/metrics" "unexpected content"; fi
if [ "$(http_get /nope | cut -d' ' -f1)" = "404" ]; then pass "unknown path is 404"; else fail "404" "$(http_get /nope)"; fi
if wait_for 20 bash -c "docker inspect -f '{{.State.Health.Status}}' ${SIDECAR} | grep -q '^healthy$'"; then pass "Docker reports the container healthy"; else fail "health" "$(docker inspect -f '{{.State.Health.Status}}' "${SIDECAR}")"; fi

echo "== hardening =="
if [ "$(in_sidecar id -u)" = "1000" ]; then pass "process runs as uid 1000"; else fail "uid" "$(in_sidecar id -u)"; fi
if [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${SIDECAR}")" = "true" ] && ! in_sidecar sh -c 'touch /probe-file' 2>/dev/null; then pass "root file system is read-only"; else fail "read-only" "a file could be created"; fi
if in_sidecar sh -c 'touch /var/log/ibgateway/state/x' 2>/dev/null; then fail "volume" "log volume is writable"; else pass "gateway log volume is read-only"; fi
if in_sidecar sh -c 'grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/1/status'; then pass "no effective capabilities"; else fail "capabilities" "$(in_sidecar grep Cap /proc/1/status)"; fi
if in_sidecar sh -c 'tr "\0" "\n" < /proc/1/environ' | grep -q "${CANARY}"; then fail "env hygiene" "secret in the environment"; else pass "no credential in PID 1 environment"; fi

echo "== notification on 2fa-pending =="
set_phase login
add_event twofa_initiated
set_phase 2fa-pending
if wait_for 30 receiver_got '"class":"twofa_pending"'; then pass "a notification reached the receiver when the phase became 2fa-pending"; else
  fail "notify" "nothing received"
  docker logs "${SIDECAR}" 2>&1 | tail -20
fi
received="$(docker logs "${RECEIVER}" 2>&1 | grep '"class":"twofa_pending"' | head -1)"
if [[ "${received}" == *'"kind":"firing"'* && "${received}" == *'"severity":"critical"'* && "${received}" == *'"instance":"smoke-1"'* && "${received}" == *'Approve the IBKR Mobile prompt now'* ]]; then pass "the message carries class, severity, instance and the instruction"; else fail "message" "${received}"; fi
# The receiver logs "POST <path> <body>"; the path is the secret URL itself, the body must not repeat it.
body="${received#POST /hook/"${CANARY}" }"
if [[ "${body}" == *CANARY* || "${body}" == *DU7654321* || "${body}" == *"${RECEIVER}"* ]]; then fail "payload hygiene" "${body}"; else pass "no username, account id or URL in the payload"; fi
if in_sidecar python -c '
import http.client, json
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
n = json.loads(c.getresponse().read())["notifier"]
assert n["enabled"] and n["state_persistence"] == "file", n
assert n["channels"][0]["name"] == "webhook" and n["channels"][0]["sent_total"] >= 1, n
assert n["active_alerts"][0]["class"] == "twofa_pending", n
'; then pass "/status shows the delivery, the active alert and file-backed state"; else fail "notifier status" "unexpected"; fi

echo "== login: the real API client meets a port nobody listens on =="
add_event login_completed
set_phase logged-in
if wait_for 30 receiver_got '"kind":"resolved"'; then pass "the alert is resolved when the phase leaves 2fa-pending"; else fail "resolved" "not received"; fi
if wait_for 30 status_is down; then pass "status is down (ib_async loaded; no gateway on 127.0.0.1:4002)"; else fail "probe" "status=$(status_field status 2>&1)"; fi
readyz="$(http_get /readyz)"
if [[ "${readyz}" == "503 down: no API handshake on 127.0.0.1:4002"* ]]; then pass "/readyz explains why"; else fail "/readyz" "${readyz}"; fi
if in_sidecar brokersre-sidecar status >/dev/null 2>&1; then fail "status command" "exit 0 while not ready"; else pass "status command exits non-zero while not ready"; fi

echo "== logs and shutdown =="
if docker logs "${SIDECAR}" 2>&1 | docker run --rm -i --entrypoint python "${IMAGE}" -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l]
assert lines
for l in lines:
    record = json.loads(l)
    assert {"ts", "src", "level", "event", "msg"} <= set(record), record
    assert record["src"] == "sidecar"
'; then pass "every stdout line is a JSON log record"; else
  fail "log format" "non-JSON or incomplete lines"
  docker logs "${SIDECAR}" 2>&1 | head -5
fi
if docker logs "${SIDECAR}" 2>&1 | grep -Eq "${CANARY}|CANARY_USERNAME|DU7654321"; then fail "log leak" "secret, username or account id in the log"; else pass "no secret, username or account id in the log"; fi
started=$(date +%s)
docker stop -t 10 "${SIDECAR}" >/dev/null 2>&1
elapsed=$(($(date +%s) - started))
code="$(docker inspect -f '{{.State.ExitCode}}' "${SIDECAR}")"
if [ "${code}" = "0" ] && [ "${elapsed}" -lt 10 ] && docker logs "${SIDECAR}" 2>&1 | grep -q '"event":"sidecar_stopped"'; then pass "SIGTERM stops it gracefully in ${elapsed}s with exit code 0"; else fail "shutdown" "exit=${code} after ${elapsed}s"; fi

echo "== without a writable state directory =="
set_phase starting
run_sidecar
if wait_for 30 in_sidecar brokersre-sidecar healthcheck && wait_for 20 phase_is starting; then pass "starts with nothing writable but /tmp"; else
  fail "read-only start" "not healthy"
  docker logs "${SIDECAR}" 2>&1 | tail -10
fi
if in_sidecar python -c '
import http.client, json
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
n = json.loads(c.getresponse().read())["notifier"]
assert n["state_persistence"] == "memory" and "not writable" in n["state_persistence_reason"], n
'; then pass "/status says the notifier state is kept in memory"; else fail "memory state" "unexpected"; fi

echo "== bundle =="
# The username is known to the operator, not to the sidecar: --redact-file scrubs it.
if in_sidecar brokersre-sidecar support-bundle --out /tmp --redact-file /run/secrets/ib-username >"${work}/bundle.out" 2>&1 && in_sidecar python -c '
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    text = "".join(archive.extractfile(m).read().decode() for m in archive.getmembers())
assert "CANARY_USERNAME" not in text and "DU7654321" not in text, "leak"
assert "***321" in text
' "$(tr -d '\r' <"${work}/bundle.out")"; then pass "support bundle is written and redacted"; else fail "bundle" "$(cat "${work}/bundle.out")"; fi

echo "== gateway container restart: the sidecar rejoins the new network namespace =="
# A stand-in gateway: any listener in the namespace, plus a live log volume. The sidecar
# joins its network namespace exactly as with network_mode: "service:ib-gateway".
cleanup_containers
docker run -d --name "${GATEWAY}" --network "${NETWORK}" --read-only --cap-drop ALL \
  --entrypoint python "${IMAGE}" -m http.server 4004 --bind 127.0.0.1 >/dev/null
set_phase logged-in
add_metrics
docker run -d --name "${SIDECAR}" --network "container:${GATEWAY}" --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp \
  -v "${host_work}/volume:/var/log/ibgateway:ro" \
  -e PROBE_ENABLED=no "${IMAGE}" >/dev/null
livez_from_gateway() {
  docker exec "${GATEWAY}" python -c '
import http.client
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=3)
c.request("GET", "/livez")
assert c.getresponse().status == 200
'
}
restarted() { [ "$(docker inspect -f '{{.RestartCount}}' "${SIDECAR}")" -ge 1 ]; }
if wait_for 30 livez_from_gateway; then pass "the sidecar answers inside the gateway's network namespace"; else
  fail "shared namespace" "no answer on 127.0.0.1:9810"
  docker logs "${SIDECAR}" 2>&1 | tail -10
fi
sleep 8 # at least one sample of the socket table while the gateway's listener exists
docker restart "${GATEWAY}" >/dev/null
rejoined=no
for _ in $(seq 1 150); do
  add_metrics # the gateway keeps writing: it is alive, only the namespace changed
  if restarted && livez_from_gateway >/dev/null 2>&1; then
    rejoined=yes
    break
  fi
  sleep 1
done
if [ "${rejoined}" = "yes" ]; then pass "after a gateway container restart the sidecar exits, is restarted and answers again"; else
  fail "rejoin" "restarts=$(docker inspect -f '{{.RestartCount}}' "${SIDECAR}") logs: $(docker logs "${SIDECAR}" 2>&1 | tail -3)"
fi
if docker logs "${SIDECAR}" 2>&1 | grep -q '"event":"network_namespace_orphaned"'; then pass "the reason is logged (network_namespace_orphaned)"; else fail "orphan log" "event missing"; fi
docker rm -f "${SIDECAR}" "${GATEWAY}" >/dev/null 2>&1 || true

echo
if [ "${failures}" -eq 0 ]; then
  echo "ALL SIDECAR CONTAINER TESTS PASSED"
  exit 0
fi
echo "${failures} sidecar container test(s) FAILED"
exit 1

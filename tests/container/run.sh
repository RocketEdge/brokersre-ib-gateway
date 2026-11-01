#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $(...) and $VAR are evaluated inside the container by in_container
# Container-level tests: run against a built image with the Docker CLI, no IBKR credentials,
# never contacting IBKR's login servers (the IBC smoke test runs with --network none).
#
# Usage: IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh
# Exit code: 0 when every test passed. Each test prints PASS/FAIL with its reason.
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1
IMAGE="${IMAGE:?set IMAGE to the image under test}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}

secrets_dir="$(mktemp -d)"
printf 'dummyuser' >"${secrets_dir}/ib-username"
printf 'dummypassword-not-real' >"${secrets_dir}/ib-password"
# mktemp -d creates a 0700 directory; uid 1000 inside the container must be able to traverse it
# (bind mounts keep host permissions on Linux hosts such as the CI runner).
chmod 0755 "${secrets_dir}" && chmod 0644 "${secrets_dir}"/*
host_secrets="${secrets_dir}"
if command -v cygpath >/dev/null 2>&1; then host_secrets="$(cygpath -m "${secrets_dir}")"; fi
# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  docker rm -f ibgw-test >/dev/null 2>&1 || true
  rm -rf "${secrets_dir}"
}
trap cleanup EXIT

run_container() { # extra-docker-args...
  docker rm -f ibgw-test >/dev/null 2>&1 || true
  docker run -d --name ibgw-test \
    -v "${host_secrets}:/run/secrets:ro" \
    -e TWS_USERID_FILE=/run/secrets/ib-username \
    -e TWS_PASSWORD_FILE=/run/secrets/ib-password \
    -e TRADING_MODE=paper \
    "$@" "${IMAGE}" >/dev/null
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
in_container() { docker exec ibgw-test bash -c "$1"; }
port_open() { in_container "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$1'"; }

echo "== structure =="
if [ "$(docker run --rm --entrypoint id "${IMAGE}" -u)" = "1000" ]; then pass "runs as uid 1000"; else fail "uid" "not 1000"; fi
if docker run --rm --entrypoint bash "${IMAGE}" -c 'command -v sudo' >/dev/null 2>&1; then fail "no sudo" "sudo present"; else pass "no sudo binary"; fi
if docker run --rm --entrypoint bash "${IMAGE}" -c 'command -v telnet || command -v ssh' >/dev/null 2>&1; then fail "no telnet/ssh" "present"; else pass "no telnet or ssh client"; fi
if docker run --rm --entrypoint test "${IMAGE}" -x /usr/bin/tini; then pass "tini present"; else fail "tini" "missing"; fi
if docker run --rm --entrypoint test "${IMAGE}" -f /usr/share/doc/ibc/LICENSE.txt; then pass "IBC GPL licence text shipped"; else fail "ibc licence" "missing"; fi
if docker run --rm --entrypoint bash "${IMAGE}" -c 'test -x "/home/ibgateway/Jts/ibgateway/${IB_GATEWAY_VERSION}/ibgateway" && test -f /opt/ibc/IBC.jar'; then pass "Gateway and IBC installed"; else fail "install" "gateway launcher or IBC.jar missing"; fi
labels=$(docker inspect "${IMAGE}" --format '{{index .Config.Labels "org.opencontainers.image.licenses"}} {{index .Config.Labels "com.rocketedge.brokersre.ibc.version"}}')
if [[ "${labels}" == MIT\ 3.* ]]; then pass "OCI labels present (${labels})"; else fail "labels" "${labels}"; fi

echo "== render + relay without IBC (IBC_LAUNCH=no) =="
run_container -e IBC_LAUNCH=no
if wait_for 30 port_open 4004; then pass "socat relay listening on 4004"; else
  fail "relay" "4004 not listening"
  docker logs ibgw-test | tail -20
fi
if in_container 'test "$(stat -c %a /run/brokersre/config.ini)" = 600 && grep -q "^IbLoginId=dummyuser$" /run/brokersre/config.ini'; then pass "config.ini rendered with mode 0600"; else fail "config" "not rendered or wrong mode"; fi
if in_container 'tr "\0" "\n" < /proc/1/environ | grep -q "TWS_PASSWORD="'; then fail "env hygiene" "TWS_PASSWORD present in PID 1 environment"; else pass "no credential in PID 1 environment"; fi
if in_container 'pgrep -x Xvfb >/dev/null && test -S /tmp/.X11-unix/X1'; then pass "Xvfb up with socket"; else fail "xvfb" "not running"; fi
if in_container 'test "$(cat /var/log/ibgateway/state/phase)" = test-mode'; then pass "phase file written to the shared log volume"; else fail "phase" "unexpected: $(in_container 'cat /var/log/ibgateway/state/phase' 2>/dev/null)"; fi
if in_container 'test -f /var/log/ibgateway/jts/.keep || true; TRADING_MODE=paper IBC_LAUNCH=no /usr/local/lib/brokersre/healthcheck.sh'; then pass "healthcheck healthy in test mode"; else fail "healthcheck" "unhealthy in test mode"; fi
# The image ships jq; the host may not (Windows), so validate with the image's jq. Slurp mode
# makes any non-JSON line a parse error and `all(...)` checks the five contract keys.
if docker logs ibgw-test 2>&1 | docker run --rm -i --entrypoint jq "${IMAGE}" -es 'all(has("ts") and has("src") and has("level") and has("event") and has("msg"))' >/dev/null 2>&1; then
  pass "every stdout line is a log-contract JSON event"
else
  fail "log contract" "non-JSON or incomplete lines on stdout"
  docker logs ibgw-test 2>&1 | head -20
fi
if in_container 'grep -rq "dummypassword-not-real" /var/log/ibgateway'; then fail "log leak" "password found under the log volume"; else pass "password absent from the log volume"; fi

echo "== read-only root filesystem =="
# A tmpfs is root-owned 0755 unless the mount says otherwise, and the gateway runs as uid 1000;
# the reference compose passes uid=1000,gid=1000 on every tmpfs and the harness does the same.
run_container -e IBC_LAUNCH=no --read-only --tmpfs /tmp --tmpfs /run/brokersre:uid=1000,gid=1000,mode=0750 --tmpfs /home/ibgateway/Jts/settings:uid=1000,gid=1000,mode=0750 -v ibgw-test-logs:/var/log/ibgateway
if wait_for 30 port_open 4004; then pass "starts read-only with uid-1000 tmpfs for /tmp, /run/brokersre and the settings dir"; else
  fail "read-only" "relay never listened"
  docker logs ibgw-test | tail -20
fi
docker rm -f ibgw-test >/dev/null 2>&1 || true
docker volume rm ibgw-test-logs >/dev/null 2>&1 || true
# Negative: a root-owned tmpfs must fail fast with a structured event, never a bare mkdir error.
run_container -e IBC_LAUNCH=no --read-only --tmpfs /tmp --tmpfs /run/brokersre -v ibgw-test-logs:/var/log/ibgateway
if wait_for 30 bash -c '! docker inspect -f "{{.State.Running}}" ibgw-test 2>/dev/null | grep -q true' \
  && [ "$(docker inspect -f '{{.State.ExitCode}}' ibgw-test)" != "0" ] \
  && docker logs ibgw-test 2>&1 | grep -q '"event":"dirs_not_writable"'; then
  pass "root-owned tmpfs fails fast with a structured dirs_not_writable event"
else
  fail "read-only negative" "exit=$(docker inspect -f '{{.State.ExitCode}}' ibgw-test 2>/dev/null) logs: $(docker logs ibgw-test 2>&1 | tail -3)"
fi
docker rm -f ibgw-test >/dev/null 2>&1 || true
docker volume rm ibgw-test-logs >/dev/null 2>&1 || true

echo "== IBC smoke (offline, --network none) =="
run_container --network none
if wait_for "${SMOKE_TIMEOUT}" port_open 7462; then pass "IBC command server listening on 7462 within ${SMOKE_TIMEOUT}s"; else
  fail "ibc smoke" "7462 never listened"
  docker logs ibgw-test | tail -30
fi
if in_container 'pgrep -f ibcalpha.ibc >/dev/null'; then pass "IBC/Gateway Java process running"; else fail "ibc process" "not running"; fi
if in_container 'test -s /var/log/ibgateway/ibc/ibc.log'; then pass "raw IBC log captured to the volume"; else fail "ibc log" "empty"; fi
if in_container 'TRADING_MODE=paper /usr/local/lib/brokersre/healthcheck.sh'; then fail "healthcheck" "reported healthy without a login"; else pass "healthcheck honestly unhealthy before login"; fi
docker stop -t 90 ibgw-test >/dev/null 2>&1 &
stop_pid=$!
if wait_for 95 bash -c '! docker inspect -f "{{.State.Running}}" ibgw-test 2>/dev/null | grep -q true'; then pass "SIGTERM stops the container (IBC STOP path)"; else fail "shutdown" "container still running after 95 s"; fi
wait "${stop_pid}" 2>/dev/null || true
if docker logs ibgw-test 2>&1 | grep -q '"event":"shutdown_complete"'; then pass "shutdown_complete event emitted"; else
  fail "shutdown event" "missing"
  docker logs ibgw-test 2>&1 | tail -5
fi

echo "== command server disabled =="
run_container --network none -e IBC_COMMAND_SERVER_PORT=0
sleep 45
if port_open 7462; then fail "command server off" "7462 is listening with port 0"; else pass "IBC_COMMAND_SERVER_PORT=0 keeps 7462 closed"; fi
if in_container 'ibc-cmd STOP; test $? -eq 2'; then pass "ibc-cmd reports the disabled server"; else fail "ibc-cmd" "unexpected exit"; fi

echo
if [ "${failures}" -eq 0 ]; then
  echo "ALL CONTAINER TESTS PASSED"
  exit 0
fi
echo "${failures} container test(s) FAILED"
exit 1

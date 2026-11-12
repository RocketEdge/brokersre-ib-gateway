#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $(...) and $VAR are evaluated inside the container by in_container
# Container-level tests: run against a built image with the Docker CLI, no IBKR credentials,
# never contacting IBKR's login servers (the IBC smoke test runs with --network none).
#
# Usage: IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh
# Exit code: 0 when every test passed. Each test prints PASS/FAIL with its reason.
set -uo pipefail

# quiet_grep <grep arguments...>: grep that says only yes or no, reading ALL of its input.
# Not `grep -q`: under pipefail a quiet grep exits at its first match, the writer in front of
# it dies of SIGPIPE (exit 141) and the pipeline is false although the text was found. In a
# check of the form "if a credential is in the log, fail; else pass" that is a false pass.
quiet_grep() { grep "$@" >/dev/null; }
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
  docker volume rm ibgw-test-settings ibgw-test-logs >/dev/null 2>&1 || true
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
# gateway_jvm_running: true when a process named exactly `java` runs IBC's main class.
# Not `pgrep -f ibcalpha.ibc`: inside `bash -c` that pattern matches the very shell that runs
# it, so such a check passes whether or not the Gateway is there.
gateway_jvm_running() {
  # shellcheck disable=SC2016  # evaluated inside the container
  in_container 'for p in $(pgrep -x java); do if tr "\0" " " <"/proc/${p}/cmdline" | grep -q "ibcalpha\.ibc"; then exit 0; fi; done; exit 1'
}

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
run_container -e IBC_LAUNCH=no -e SAMPLE_INTERVAL_S=2
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
# Log contract v2: the events file on the volume holds exactly the lines of the container's
# stdout, each with this start's boot id and a gap-free sequence number.
if [ "$(docker logs ibgw-test 2>&1)" = "$(in_container 'cat /var/log/ibgateway/events/events.jsonl')" ]; then
  pass "events/events.jsonl on the volume is identical to the container's stdout"
else
  fail "events file" "differs from stdout"
fi
if in_container 'b=$(cat /var/log/ibgateway/state/boot_id); [[ "${b}" =~ ^[0-9a-f]{16}$ ]] && jq -es --arg b "${b}" "all(.boot_id == \$b) and ([.[].seq] == [range(1; length + 1)])" /var/log/ibgateway/events/events.jsonl >/dev/null'; then
  pass "every event carries the boot id and the sequence 1..n without a gap"
else
  fail "boot id / seq" "missing boot id or a gap in seq"
fi
# The resource sampler reads this container's own cgroup and /proc (no Docker socket): a real
# kernel must give it plausible numbers, and the sample carries this start's boot id.
if wait_for 20 in_container 'b=$(cat /var/log/ibgateway/state/boot_id); tail -1 /var/log/ibgateway/metrics/metrics.jsonl | jq -e --arg b "${b}" ".src == \"metrics\" and .boot_id == \$b and .seq >= 1 and .phase == \"test-mode\" and .mem_working_set_bytes > 0 and .pids > 0" >/dev/null'; then
  pass "metrics/metrics.jsonl has a sample with real memory and process numbers"
else
  fail "sampler" "no valid sample: $(in_container 'tail -1 /var/log/ibgateway/metrics/metrics.jsonl 2>/dev/null | cut -c1-200')"
fi
if in_container 'p=$(pgrep -f "[s]ampler.sh" | head -1); test -n "${p}" && ! tr "\0" "\n" <"/proc/${p}/environ" | grep -q -e "^TWS_PASSWORD=" -e "^TWS_USERID="'; then
  pass "the sampler runs without any credential in its environment"
else
  fail "sampler environment" "sampler not running or a credential is in its environment"
fi
# Screenshots are opt-in: by default Xvfb keeps no framebuffer file and nothing can be saved.
if in_container 'test ! -e /run/brokersre/xvfb && ! /usr/local/lib/brokersre/screenshot.sh >/dev/null 2>&1 && test ! -e /var/log/ibgateway/screens'; then
  pass "screenshots are off by default: no framebuffer file, nothing saved"
else
  fail "screenshots default" "a framebuffer file or a screenshot exists without SCREENSHOTS=yes"
fi

echo "== screenshots (SCREENSHOTS=yes, the image's real Xvfb) =="
# The image has no screenshot tool: Xvfb keeps its framebuffer in a file and a screenshot is a
# copy of it. This proves it with the real Xvfb of the image, without IBC.
run_container -e IBC_LAUNCH=no -e SCREENSHOTS=yes
wait_for 30 port_open 4004 || true
if in_container 'test -s /run/brokersre/xvfb/Xvfb_screen0 && test "$(stat -c %a /run/brokersre/xvfb)" = 700'; then
  pass "Xvfb keeps its framebuffer in a private directory on the run tmpfs"
else
  fail "framebuffer" "no framebuffer file under /run/brokersre/xvfb"
  docker logs ibgw-test 2>&1 | tail -5
fi
if in_container '/usr/local/lib/brokersre/screenshot.sh container_test >/dev/null'; then pass "screenshot.sh takes a screenshot on request"; else fail "screenshot" "screenshot.sh failed"; fi
# An XWD file starts with its header size and the format version 7, both big-endian 32-bit;
# a 1024x768 screen at 16 bits per pixel is about 1.5 MB.
if in_container 'f="$(ls /var/log/ibgateway/screens/*-container_test.xwd | head -1)"; test "$(od -A n -t x1 -j 4 -N 4 "$f" | tr -d " ")" = 00000007 && test "$(stat -c %s "$f")" -gt 1000000 && test "$(stat -c %a "$f")" = 600'; then
  pass "the screenshot is an XWD image of the whole screen, readable by its owner only"
else
  fail "screenshot file" "$(in_container 'ls -la /var/log/ibgateway/screens 2>&1 | tail -3')"
fi
if in_container 'jq -e -s "map(select(.event == \"screenshot_saved\")) | length == 1 and (.[0].data.reason == \"container_test\") and (.[0].data.file | startswith(\"screens/\"))" /var/log/ibgateway/events/events.jsonl >/dev/null'; then
  pass "the screenshot is announced on the events file (screenshot_saved)"
else
  fail "screenshot event" "no screenshot_saved event"
fi

echo "== preflight (doctor) =="
# `doctor` as a command: the entrypoint runs it instead of the gateway and passes its exit code.
doctor_run() { # extra-docker-args... ; prints stdout, returns doctor's exit code
  docker run --rm -v "${host_secrets}:/run/secrets:ro" -e TWS_USERID_FILE=/run/secrets/ib-username \
    -e TWS_PASSWORD_FILE=/run/secrets/ib-password -e TRADING_MODE=paper "$@" "${IMAGE}" doctor --json 2>/dev/null
}
doctor_json="$(doctor_run -e AUTO_RESTART_TIME='11:45 PM' -e TIME_ZONE=America/New_York)"
doctor_rc=$?
if [ "${doctor_rc}" -eq 0 ] && printf '%s' "${doctor_json}" | docker run --rm -i --entrypoint jq "${IMAGE}" -e '.schema == "brokersre.doctor.v1" and (.result == "pass" or .result == "warn") and (.checks | length >= 10) and (.checks | all(has("name") and has("status") and has("detail") and has("fix")))' >/dev/null 2>&1; then
  pass "doctor: a sound configuration passes and prints one valid JSON document"
else
  fail "doctor ok" "exit ${doctor_rc}: $(printf '%s' "${doctor_json}" | head -c 300)"
fi
doctor_json="$(doctor_run -e AUTO_RESTART_TIME='9:30 PM')"
doctor_rc=$?
if [ "${doctor_rc}" -eq 1 ] && printf '%s' "${doctor_json}" | docker run --rm -i --entrypoint jq "${IMAGE}" -e '.result == "fail" and ([.checks[] | select(.name == "auto_restart_time" and .status == "fail")] | length == 1)' >/dev/null 2>&1; then
  pass "doctor: a restart time IBC would not apply fails the preflight (exit 1) and names the check"
else
  fail "doctor restart time" "exit ${doctor_rc}: $(printf '%s' "${doctor_json}" | head -c 300)"
fi
if printf '%s' "${doctor_json}" | quiet_grep -e 'dummyuser' -e 'dummypassword-not-real'; then fail "doctor leak" "a credential appears in doctor's output"; else pass "doctor: no credential in its output"; fi
# At container start a failed preflight stops everything before IBC, with an event that names
# the problem; a wrong restart time must not lead to a login that then runs without restarts.
run_container -e AUTO_RESTART_TIME='9:30 PM'
if wait_for 30 bash -c '! docker inspect -f "{{.State.Running}}" ibgw-test 2>/dev/null | grep -q true' \
  && [ "$(docker inspect -f '{{.State.ExitCode}}' ibgw-test)" = "1" ] \
  && docker logs ibgw-test 2>&1 | quiet_grep '"event":"doctor_failed"' \
  && ! docker logs ibgw-test 2>&1 | quiet_grep '"event":"ibc_starting"'; then
  pass "a failed preflight stops the container before IBC starts (doctor_failed, exit 1)"
else
  fail "preflight stop" "exit=$(docker inspect -f '{{.State.ExitCode}}' ibgw-test 2>/dev/null) logs: $(docker logs ibgw-test 2>&1 | tail -3 | cut -c1-300)"
fi
run_container -e IBC_LAUNCH=no -e AUTO_RESTART_TIME='9:30 PM' -e DOCTOR_STRICT=no -e JAVA_HEAP_SIZE=1024
if wait_for 30 port_open 4004 \
  && docker logs ibgw-test 2>&1 | grep '"event":"doctor_failed"' | quiet_grep '"level":"warn"' \
  && docker logs ibgw-test 2>&1 | grep '"event":"config_deprecated"' | quiet_grep 'JAVA_HEAP_SIZE'; then
  pass "DOCTOR_STRICT=no starts anyway; an ignored gnzsnz variable is reported by name (config_deprecated)"
else
  fail "preflight non-strict" "$(docker logs ibgw-test 2>&1 | tail -4 | cut -c1-300)"
fi

# A defect of the preflight itself must never stop a gateway. A stand-in doctor that ends with
# status 1 but leaves no verdict (as an aborted script would) is mounted over the real one: the
# container must start anyway and say that the preflight ended abnormally.
fake_doctor="$(mktemp -d)"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${fake_doctor}/doctor.sh"
chmod 0755 "${fake_doctor}" "${fake_doctor}/doctor.sh"
host_fake_doctor="${fake_doctor}"
if command -v cygpath >/dev/null 2>&1; then host_fake_doctor="$(cygpath -m "${fake_doctor}")"; fi
run_container -e IBC_LAUNCH=no -v "${host_fake_doctor}/doctor.sh:/usr/local/lib/brokersre/doctor.sh:ro"
if wait_for 30 port_open 4004 \
  && docker logs ibgw-test 2>&1 | grep '"event":"doctor_warning"' | quiet_grep 'ended abnormally (exit status 1)'; then
  pass "a preflight that aborts (status 1, no verdict) does not stop the start; it is reported"
else
  fail "preflight abort" "exit=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' ibgw-test 2>/dev/null) logs: $(docker logs ibgw-test 2>&1 | tail -3 | cut -c1-300)"
fi
docker rm -f ibgw-test >/dev/null 2>&1 || true
rm -rf "${fake_doctor}"
# The real preflight leaves its verdict where the entrypoint looks for it.
run_container -e IBC_LAUNCH=no -e AUTO_RESTART_TIME='11:45 PM'
if wait_for 30 port_open 4004 && in_container 'v=$(cat /run/brokersre/doctor.result); test "${v}" = pass || test "${v}" = warn'; then
  pass "the preflight's verdict file holds pass or warn after a start that went ahead"
else
  fail "verdict file" "$(in_container 'cat /run/brokersre/doctor.result' 2>&1 | head -c 200)"
fi

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
  && docker logs ibgw-test 2>&1 | quiet_grep '"event":"dirs_not_writable"'; then
  pass "root-owned tmpfs fails fast with a structured dirs_not_writable event"
else
  fail "read-only negative" "exit=$(docker inspect -f '{{.State.ExitCode}}' ibgw-test 2>/dev/null) logs: $(docker logs ibgw-test 2>&1 | tail -3)"
fi
docker rm -f ibgw-test >/dev/null 2>&1 || true
docker volume rm ibgw-test-logs >/dev/null 2>&1 || true

echo "== IBC smoke (offline, --network none, hardened: read-only root, no capabilities) =="
# The reference compose runs read-only with every capability dropped, so the smoke test does
# too: IBC and the Gateway JVM must start in exactly that configuration.
docker volume rm ibgw-test-settings >/dev/null 2>&1 || true
run_container --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true -e JAVA_HEAP_MB=1024 \
  --tmpfs /tmp --tmpfs /run/brokersre:uid=1000,gid=1000,mode=0750 -v ibgw-test-settings:/home/ibgateway/Jts/settings
if wait_for "${SMOKE_TIMEOUT}" port_open 7462; then pass "IBC command server listening on 7462 within ${SMOKE_TIMEOUT}s"; else
  fail "ibc smoke" "7462 never listened"
  docker logs ibgw-test | tail -30
fi
if gateway_jvm_running; then pass "IBC/Gateway Java process running"; else fail "ibc process" "not running"; fi
# A real login writes .hwid into the JVM's user.home; when that is the read-only image home the
# Gateway blocks behind a dialog nobody sees. The JVM must be told a writable home.
if in_container 'j=$(pgrep -x java | head -1); tr "\0" "\n" <"/proc/${j}/environ" | grep -q "^_JAVA_OPTIONS=-Duser.home=/home/ibgateway/Jts/settings/.java-home "'; then
  pass "Gateway JVM gets a user.home on the settings volume"
else
  fail "java home" "_JAVA_OPTIONS missing from the JVM environment"
fi
# JAVA_HEAP_MB=1024 above: the Gateway reports its real maximum heap in launcher.log a few
# seconds after start. 1,048,576 KB proves the run-time value won over the image's 768 MB.
if wait_for 60 in_container 'grep -q "HeapUsage: Max=1,048,576KB" /home/ibgateway/Jts/settings/launcher.log'; then
  pass "JAVA_HEAP_MB sets the Gateway heap at run time (1024 MB in effect)"
else
  fail "runtime heap" "launcher.log does not show a 1024 MB heap: $(in_container 'grep -o "HeapUsage: Max=[0-9,]*KB" /home/ibgateway/Jts/settings/launcher.log | tail -1' 2>/dev/null)"
fi
# The relay follows the login: before a login it must refuse connections instead of accepting
# and dropping them.
if port_open 4004; then fail "relay gate" "relay listens on 4004 before any login"; else pass "relay closed while the Gateway is not logged in"; fi
if in_container 'test -d /home/ibgateway/Jts/settings/.java-home && test -w /home/ibgateway/Jts/settings/.java-home && test "$(stat -c %a /home/ibgateway/Jts/settings/.java-home)" = 700'; then
  pass "Java home exists, is writable and private (0700) under a read-only root"
else
  fail "java home dir" "missing, not writable or not 0700"
fi
if in_container 'test -s /var/log/ibgateway/ibc/ibc.log'; then pass "raw IBC log captured to the volume"; else fail "ibc log" "empty"; fi
if in_container 'TRADING_MODE=paper /usr/local/lib/brokersre/healthcheck.sh'; then fail "healthcheck" "reported healthy without a login"; else pass "healthcheck honestly unhealthy before login"; fi
docker stop -t 90 ibgw-test >/dev/null 2>&1 &
stop_pid=$!
if wait_for 95 bash -c '! docker inspect -f "{{.State.Running}}" ibgw-test 2>/dev/null | grep -q true'; then pass "SIGTERM stops the container (IBC STOP path)"; else fail "shutdown" "container still running after 95 s"; fi
wait "${stop_pid}" 2>/dev/null || true
if docker logs ibgw-test 2>&1 | quiet_grep '"event":"shutdown_complete"'; then pass "shutdown_complete event emitted"; else
  fail "shutdown event" "missing"
  docker logs ibgw-test 2>&1 | tail -5
fi

echo "== rejected-login latch (offline, --network none) =="
# After IBKR has rejected the credentials, a later start with the same secret files must not
# send them again: a restart policy or a reboot would repeat the login until IBKR locks the
# account. The record of a rejection is written here by hand, for exactly the secret files of
# this suite, as the classifier writes it; then the image is started as usual (IBC enabled).
latch_env=(-e TWS_USERID_FILE=/run/secrets/ib-username -e TWS_PASSWORD_FILE=/run/secrets/ib-password)
docker volume rm ibgw-test-logs >/dev/null 2>&1 || true
fingerprint="$(docker run --rm -v "${host_secrets}:/run/secrets:ro" "${latch_env[@]}" --entrypoint bash "${IMAGE}" \
  -c 'source /usr/local/lib/brokersre/log.sh; source /usr/local/lib/brokersre/login-latch.sh; credential_fingerprint' 2>/dev/null || true)"
if [[ "${fingerprint}" =~ ^files:[0-9a-f]{16}$ ]]; then pass "the image computes a fingerprint for the mounted secret files"; else fail "latch fingerprint" "got '${fingerprint}'"; fi
docker run --rm -v ibgw-test-logs:/var/log/ibgateway --entrypoint bash "${IMAGE}" \
  -c "mkdir -p /var/log/ibgateway/state && printf 'v1 %s 2026-11-11T23:23:04.155Z\n' '${fingerprint}' >/var/log/ibgateway/state/login-rejected" || true
run_container --network none -e SAMPLE_INTERVAL_S=2 -v ibgw-test-logs:/var/log/ibgateway
if wait_for 30 bash -c 'docker logs ibgw-test 2>&1 | grep -q "\"event\":\"login_rejected_latched\""'; then
  pass "a recorded rejection for unchanged secret files is announced (login_rejected_latched)"
else
  fail "latch event" "no login_rejected_latched event"
  docker logs ibgw-test 2>&1 | tail -5
fi
if in_container 'test "$(cat /var/log/ibgateway/state/phase)" = needs-human'; then pass "latched start: phase needs-human"; else fail "latch phase" "phase is $(in_container 'cat /var/log/ibgateway/state/phase' 2>/dev/null)"; fi
# Give IBC the time it would need to appear if the latch had not held, then look for it.
sleep 10
if in_container 'pgrep -x java >/dev/null'; then fail "latch holds" "a Java process runs: a login was attempted"; else pass "latched start: no IBC, no Gateway, no login"; fi
if docker logs ibgw-test 2>&1 | quiet_grep '"event":"ibc_starting"'; then fail "latch holds" "ibc_starting was emitted"; else pass "latched start: IBC was never started"; fi
if [ "$(docker inspect -f '{{.State.Running}}' ibgw-test 2>/dev/null)" = "true" ]; then pass "latched start: the container stays up (no restart loop)"; else fail "latch hold" "the container exited"; fi
if in_container 'TRADING_MODE=paper /usr/local/lib/brokersre/healthcheck.sh >/dev/null 2>&1'; then fail "latch health" "reported healthy"; else pass "latched start: unhealthy"; fi
if in_container 'test -s /var/log/ibgateway/state/login-rejected'; then pass "latched start: the record is kept"; else fail "latch record" "the record was removed"; fi
if wait_for 20 in_container 'jq -e -s "length > 0 and (.[-1].phase == \"needs-human\")" /var/log/ibgateway/metrics/metrics.jsonl'; then pass "latched start: resource samples go on (a waiting gateway is not a silent one)"; else fail "latch samples" "no sample in phase needs-human"; fi
if docker logs ibgw-test 2>&1 | quiet_grep -e dummyuser -e dummypassword; then fail "latch secrecy" "a credential appears in the events"; else pass "latched start: no credential in the events"; fi
docker stop -t 30 ibgw-test >/dev/null 2>&1 &
stop_pid=$!
if wait_for 20 bash -c '! docker inspect -f "{{.State.Running}}" ibgw-test 2>/dev/null | grep -q true'; then pass "latched start: SIGTERM stops the container at once"; else fail "latch stop" "still running after 20 s"; fi
wait "${stop_pid}" 2>/dev/null || true
# The operator corrects the credentials: rewriting a secret file gives it a new modification
# time, which releases the latch, and the next start launches IBC again.
sleep 1
printf 'dummypassword-not-real' >"${secrets_dir}/ib-password"
chmod 0644 "${secrets_dir}/ib-password"
run_container --network none -v ibgw-test-logs:/var/log/ibgateway
if wait_for 30 bash -c 'docker logs ibgw-test 2>&1 | grep -q "\"event\":\"login_latch_cleared\""'; then pass "a rewritten secret file releases the latch (login_latch_cleared)"; else
  fail "latch release" "no login_latch_cleared event"
  docker logs ibgw-test 2>&1 | tail -5
fi
if wait_for "${SMOKE_TIMEOUT}" gateway_jvm_running; then pass "after the release IBC starts again"; else fail "latch release" "IBC did not start"; fi
if in_container 'test ! -e /var/log/ibgateway/state/login-rejected'; then pass "after the release the record is gone"; else fail "latch release" "the record is still there"; fi
docker rm -f ibgw-test >/dev/null 2>&1 || true
docker volume rm ibgw-test-logs >/dev/null 2>&1 || true

echo "== reference compose (compose/docker-compose.example.yml) =="
# The example is what users copy, so it is tested as shipped: its hardening settings are
# asserted on the rendered configuration and the stack is started from it (without IBC).
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
compose_file="${repo_root}/compose/docker-compose.example.yml"
if command -v cygpath >/dev/null 2>&1; then compose_file="$(cygpath -m "${compose_file}")"; fi
compose_ref() { IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no docker compose -p ibgw-ref-test -f "${compose_file}" "$@"; }
rendered="$(compose_ref config --format json 2>/dev/null)"
compose_has() { # description jq-filter
  if printf '%s' "${rendered}" | docker run --rm -i --entrypoint jq "${IMAGE}" -e ".services[\"ib-gateway\"] | $2" >/dev/null 2>&1; then pass "compose: $1"; else fail "compose" "$1"; fi
}
compose_has "read-only root filesystem" '.read_only == true'
compose_has "every capability dropped" '.cap_drop == ["ALL"]'
compose_has "no-new-privileges" '.security_opt | index("no-new-privileges:true") != null'
compose_has "stop_grace_period of at least 90 s (the entrypoint waits 60 s for IBC to log out)" '.stop_grace_period | test("^(1m30s|[2-9]m|1m[3-5][0-9]s)")'
compose_has "open-file limit raised to 65536" '.ulimits.nofile.soft == 65536 and .ulimits.nofile.hard == 65536'
compose_has "process limit set" '.pids_limit > 0'
compose_has "container log size capped" '.logging.options["max-size"] != null and .logging.options["max-file"] != null'
compose_has "API ports published on loopback by default" '[.ports[] | .host_ip] | all(. == "127.0.0.1")'
compose_ref down -v >/dev/null 2>&1 || true
if compose_ref up -d >/dev/null 2>&1 \
  && wait_for 60 bash -c "docker inspect -f '{{.State.Health.Status}}' ibgw-ref-test-ib-gateway-1 2>/dev/null | grep -qx healthy \
    || docker exec ibgw-ref-test-ib-gateway-1 bash -c 'TRADING_MODE=paper IBC_LAUNCH=no /usr/local/lib/brokersre/healthcheck.sh'"; then
  pass "compose: the example starts as shipped (hardened, test mode) and is healthy"
else
  fail "compose up" "$(compose_ref logs 2>&1 | tail -5)"
fi
s_start=${SECONDS}
compose_ref down -v >/dev/null 2>&1 || true
if [ $((SECONDS - s_start)) -lt 60 ]; then pass "compose: down completes inside the grace period"; else fail "compose down" "took $((SECONDS - s_start)) s"; fi

echo "== qualification script (offline: the login cannot complete, the script must say so) =="
# scripts/qualify-paper.sh is what a person or the reviewer-gated workflow runs against a real
# paper account. Here it runs without a network, so no login server is contacted: it must make
# its one attempt, report "not qualified" with a valid result document, and leave nothing behind.
qualify="${repo_root}/scripts/qualify-paper.sh"
qualify_out="$(mktemp -d)"
if "${qualify}" --image "${IMAGE}" >/dev/null 2>&1; then fail "qualify usage" "accepted a call without --secrets-dir"; else
  if [ $? -eq 2 ]; then pass "qualify: a call without the secrets directory is a usage error"; else fail "qualify usage" "wrong exit code"; fi
fi
empty_secrets="$(mktemp -d)"
: >"${empty_secrets}/ib-username"
: >"${empty_secrets}/ib-password"
"${qualify}" --image "${IMAGE}" --secrets-dir "${empty_secrets}" --out "${qualify_out}" >/dev/null 2>&1
if [ $? -eq 2 ] && [ -z "$(docker ps -aq --filter name=ibgw-qualify-)" ]; then pass "qualify: empty secret files are refused before any container starts"; else fail "qualify secrets" "empty secrets were not refused"; fi
rm -rf "${empty_secrets}"
QUALIFY_DOCKER_ARGS="--network none" "${qualify}" --image "${IMAGE}" --secrets-dir "${secrets_dir}" --out "${qualify_out}" --login-timeout 40 >"${qualify_out}/stdout.txt" 2>&1
qualify_rc=$?
if [ "${qualify_rc}" -eq 1 ]; then pass "qualify: a login that cannot complete is 'not qualified' (exit 1)"; else
  fail "qualify exit" "exit ${qualify_rc}: $(tail -3 "${qualify_out}/stdout.txt")"
fi
if docker run --rm -i --entrypoint jq "${IMAGE}" -e '.schema == "brokersre.qualification.v1" and .result == "fail" and (.reason | type == "string" and length > 0) and .trading_mode == "paper" and .second_factor_prompted == false and .login_seconds == null and (.checks | type == "array" and length >= 1) and (.checks | all(has("status") and has("name") and has("detail")))' <"${qualify_out}/result.json" >/dev/null 2>&1; then
  pass "qualify: result.json is a complete, valid record of the failure"
else
  fail "qualify result" "$(cat "${qualify_out}/result.json" 2>/dev/null | head -c 400)"
fi
if grep -q -e 'dummyuser' -e 'dummypassword-not-real' "${qualify_out}/result.json" "${qualify_out}/stdout.txt" "${qualify_out}/events.jsonl" 2>/dev/null; then
  fail "qualify leak" "a credential appears in the qualification output"
else
  pass "qualify: no credential in the result, the output or the collected events"
fi
if [ -z "$(docker ps -aq --filter name=ibgw-qualify-)" ] && [ -z "$(docker volume ls -q --filter name=ibgw-qualify-)" ]; then
  pass "qualify: the container and its volumes are removed afterwards"
else
  fail "qualify cleanup" "left behind: $(docker ps -aq --filter name=ibgw-qualify- | tr '\n' ' ') $(docker volume ls -q --filter name=ibgw-qualify- | tr '\n' ' ')"
fi
if [ "$(grep -c '"event":"ibc_starting"' "${qualify_out}/events.jsonl" 2>/dev/null)" = "1" ]; then
  pass "qualify: exactly one login attempt was started"
else
  fail "qualify attempts" "expected one ibc_starting event"
fi
rm -rf "${qualify_out}"

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

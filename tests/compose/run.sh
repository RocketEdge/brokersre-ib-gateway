#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $(...) and $VAR are evaluated by jq or inside a container
# Compose-level tests for the files users copy: compose/docker-compose.multi.yml (several
# gateways on one host), examples/compose-with-client.yml (a gateway and a strategy on a
# private network) and compose/docker-compose.console.yml (the break-glass console on top of
# the reference compose). They run against a built image with the Docker CLI, need no IBKR
# credentials and never contact IBKR: every container runs with IBC_LAUNCH=no.
#
# Usage: IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/compose/run.sh
# Environment (optional):
#   COMPOSE_TEST_PROJECT     compose project name prefix (default ibgw-compose-test); the
#                            stacks are <prefix>-multi, <prefix>-client and <prefix>-console
#   COMPOSE_TEST_LIVE_PORT   host port for the live gateway while the stack runs (default 14001)
#   COMPOSE_TEST_PAPER_PORT  the same for the paper gateway (default 14002)
#   COMPOSE_TEST_CONSOLE_PORT  host port of the console bridge while the stack runs (default 15901)
#   The defaults of the shipped file (4001/4002) are asserted on the rendered configuration;
#   other ports are used for the running stack so that a gateway already running on this host
#   does not fail the test.
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
PROJECT="${COMPOSE_TEST_PROJECT:-ibgw-compose-test}"
LIVE_PORT="${COMPOSE_TEST_LIVE_PORT:-14001}"
PAPER_PORT="${COMPOSE_TEST_PAPER_PORT:-14002}"
CONSOLE_PORT="${COMPOSE_TEST_CONSOLE_PORT:-15901}"
failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}

# host_path PATH: PATH as the Docker CLI on this host wants it (C:/... under Git Bash).
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
multi_file="$(host_path "${repo_root}/compose/docker-compose.multi.yml")"
reference_file="$(host_path "${repo_root}/compose/docker-compose.example.yml")"
client_file="$(host_path "${repo_root}/examples/compose-with-client.yml")"
console_file="$(host_path "${repo_root}/compose/docker-compose.console.yml")"
check_usernames="${repo_root}/scripts/check-compose-usernames.sh"

# Obviously fake credentials, one set per instance. mktemp -d creates a 0700 directory; uid
# 1000 inside the container must be able to traverse it (bind mounts keep host permissions on
# Linux hosts such as the CI runner).
secrets_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
for instance in live paper desk-a; do
  mkdir -p "${secrets_dir}/${instance}"
  printf 'dummy%s' "${instance}" >"${secrets_dir}/${instance}/ib-username"
  printf 'dummypassword-not-real-%s' "${instance}" >"${secrets_dir}/${instance}/ib-password"
done
# The single-gateway layout, for the client example.
printf 'dummysingle' >"${secrets_dir}/ib-username"
printf 'dummypassword-not-real-single' >"${secrets_dir}/ib-password"
# The break-glass console's password: an obvious fake, assembled so no scanner objects.
printf '%s\n' "dummy""vnc" >"${secrets_dir}/vnc-password"
chmod -R a+rX "${secrets_dir}"
host_secrets="$(host_path "${secrets_dir}")"

multi_project="${PROJECT}-multi"
client_project="${PROJECT}-client"
console_project="${PROJECT}-console"
# compose_multi ARGS...: docker compose on the multi-gateway file as shipped, in test mode.
compose_multi() {
  IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no \
    docker compose -p "${multi_project}" -f "${multi_file}" "$@"
}
# compose_client ARGS...: docker compose on the gateway-plus-strategy example, in test mode.
compose_client() {
  IBGW_IMAGE="${IMAGE}" STRATEGY_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no \
    docker compose -p "${client_project}" -f "${client_file}" "$@"
}
# compose_console ARGS...: the reference compose with the console override, as the console
# guide starts it, in test mode and on a test port for the bridge.
compose_console() {
  IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no IBGW_CONSOLE_PORT="${CONSOLE_PORT}" \
    PRIVATE_IP=127.0.0.1 docker compose -p "${console_project}" -f "${reference_file}" -f "${console_file}" "$@"
}
# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  compose_multi --profile live --profile paper down -v --remove-orphans >/dev/null 2>&1 || true
  compose_client down -v --remove-orphans >/dev/null 2>&1 || true
  compose_console down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${secrets_dir}" "${work_dir}"
}
trap cleanup EXIT

# jq_image ARGS...: the image's jq on stdin (the host may have none, e.g. Windows).
jq_image() { docker run --rm -i --entrypoint jq "${IMAGE}" "$@"; }
# check DESCRIPTION JSON FILTER: PASS when the jq FILTER is true for the JSON text.
check() {
  if printf '%s' "$2" | jq_image -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1" "jq filter not true: $3"; fi
}
# check_pair DESCRIPTION JSON_A JSON_B FILTER: FILTER sees the two documents as .[0] and .[1].
check_pair() {
  if printf '%s\n%s\n' "$2" "$3" | jq_image -es "$4" >/dev/null 2>&1; then pass "$1"; else fail "$1" "jq filter not true: $4"; fi
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
container_healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]; }
in_container() { docker exec "$1" bash -c "$2"; }
# project_leftovers PROJECT: names of containers, volumes and networks the project still owns.
project_leftovers() {
  docker ps -a --filter "label=com.docker.compose.project=$1" --format '{{.Names}}'
  docker volume ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}'
  docker network ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}'
}

# The settings that make a gateway service hardened; they must be the same in every service.
hardening='def hardening: {image, restart, read_only, tmpfs, security_opt, cap_drop, stop_grace_period, ulimits, pids_limit, mem_limit, logging, healthcheck};'

echo "== multi-gateway compose: rendering =="
rendered_live="$(compose_multi --profile live config --format json 2>/dev/null)"
rendered_paper="$(compose_multi --profile paper config --format json 2>/dev/null)"
rendered="$(compose_multi --profile live --profile paper config --format json 2>/dev/null)"
rendered_none="$(compose_multi config --format json 2>/dev/null)"
reference="$(IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no docker compose -p "${PROJECT}-reference" -f "${reference_file}" config --format json 2>/dev/null)"
check "profile live renders exactly the live gateway" "${rendered_live}" '(.services | keys) == ["ib-gateway-live"]'
check "profile paper renders exactly the paper gateway" "${rendered_paper}" '(.services | keys) == ["ib-gateway-paper"]'
check "both profiles render both gateways" "${rendered}" '(.services | keys) == ["ib-gateway-live", "ib-gateway-paper"]'
check "without a profile nothing is selected (a gateway never starts by accident)" "${rendered_none}" '((.services // {}) | length) == 0'

echo "== multi-gateway compose: both services are hardened alike, and like the reference compose =="
check "live and paper have identical hardening settings" "${rendered}" \
  "${hardening}"' (.services["ib-gateway-live"] | hardening) == (.services["ib-gateway-paper"] | hardening)'
check_pair "the hardening settings equal those of compose/docker-compose.example.yml" "${reference}" "${rendered}" \
  "${hardening}"' (.[0].services["ib-gateway"] | hardening) == (.[1].services["ib-gateway-live"] | hardening)'
for service in ib-gateway-live ib-gateway-paper; do
  check "${service}: read-only root, no capabilities, no-new-privileges" "${rendered}" \
    ".services[\"${service}\"] | .read_only == true and .cap_drop == [\"ALL\"] and (.security_opt | index(\"no-new-privileges:true\") != null)"
  check "${service}: tmpfs for /run/brokersre owned by uid and gid 1000" "${rendered}" \
    ".services[\"${service}\"].tmpfs | any(test(\"^/run/brokersre:.*uid=1000,gid=1000\"))"
  check "${service}: stop_grace_period of at least 90 s" "${rendered}" \
    ".services[\"${service}\"].stop_grace_period | test(\"^(1m30s|[2-9]m|1m[3-5][0-9]s)\")"
  check "${service}: open-file, process, memory and log-size limits" "${rendered}" \
    ".services[\"${service}\"] | .ulimits.nofile.soft == 65536 and .ulimits.nofile.hard == 65536 and .pids_limit > 0 and ((.mem_limit | tonumber) > 0) and .logging.options[\"max-size\"] != null and .logging.options[\"max-file\"] != null"
  check "${service}: healthcheck is the image's own and the restart policy is unless-stopped" "${rendered}" \
    ".services[\"${service}\"] | (.healthcheck.test | index(\"/usr/local/lib/brokersre/healthcheck.sh\") != null) and .restart == \"unless-stopped\""
done

echo "== multi-gateway compose: nothing is shared between the two sessions =="
check "TRADING_MODE and IBGW_INSTANCE are fixed per service" "${rendered}" \
  '(.services["ib-gateway-live"].environment | .TRADING_MODE == "live" and .IBGW_INSTANCE == "live") and (.services["ib-gateway-paper"].environment | .TRADING_MODE == "paper" and .IBGW_INSTANCE == "paper")'
check "every other environment variable is the same in both services" "${rendered}" \
  '(.services["ib-gateway-live"].environment | del(.TRADING_MODE, .IBGW_INSTANCE)) == (.services["ib-gateway-paper"].environment | del(.TRADING_MODE, .IBGW_INSTANCE))'
check "each service has its own two named volumes (settings and logs)" "${rendered}" \
  '[.services["ib-gateway-live"].volumes[].source] as $l | [.services["ib-gateway-paper"].volumes[].source] as $p | ($l | length) == 2 and ($p | length) == 2 and (($l - $p) | length) == 2 and ([.services[].volumes[].target] | unique) == ["/home/ibgateway/Jts/settings", "/var/log/ibgateway"]'
check "each service has its own secrets, mounted under the same names" "${rendered}" \
  '[.services["ib-gateway-live"].secrets[].source] as $l | [.services["ib-gateway-paper"].secrets[].source] as $p | ($l | length) == 2 and (($l - $p) | length) == 2 and ([.services[].secrets[].target] | unique) == ["ib-password", "ib-username"]'
# The path separator is matched as "any character that cannot be part of a name": compose
# prints C:\...\live\ib-username on Windows and /.../live/ib-username elsewhere.
check "the secret files come from <secrets>/live and <secrets>/paper" "${rendered}" \
  '. as $c | ([.services["ib-gateway-live"].secrets[].source | $c.secrets[.].file] | all(test("[^A-Za-z0-9._-]live[^A-Za-z0-9._-]ib-(username|password)$"))) and ([.services["ib-gateway-paper"].secrets[].source | $c.secrets[.].file] | all(test("[^A-Za-z0-9._-]paper[^A-Za-z0-9._-]ib-(username|password)$")))'
check "host ports are deterministic: live 4001 -> relay 4003, paper 4002 -> relay 4004" "${rendered}" \
  '(.services["ib-gateway-live"].ports | length == 1 and (.[0].published | tostring) == "4001" and .[0].target == 4003) and (.services["ib-gateway-paper"].ports | length == 1 and (.[0].published | tostring) == "4002" and .[0].target == 4004)'
check "the relays are published on loopback by default" "${rendered}" '[.services[].ports[].host_ip] | all(. == "127.0.0.1")'
rendered_private="$(PRIVATE_IP=10.1.2.3 compose_multi --profile live --profile paper config --format json 2>/dev/null)"
check "PRIVATE_IP moves both relays to that address" "${rendered_private}" '[.services[].ports[].host_ip] | all(. == "10.1.2.3")'

echo "== multi-gateway compose: the documented block for one more username =="
# The file carries a third gateway as comments between '# >>>' and '# <<<' markers. A user
# removes the comment signs; so does this test, and the result must be a hardened service too.
three_file="${work_dir}/docker-compose.three.yml"
awk '/^ *# >>> /{inside=1; print; next} /^ *# <<< /{inside=0; print; next} inside{sub(/# ?/, ""); print; next} {print}' \
  "${repo_root}/compose/docker-compose.multi.yml" >"${three_file}"
rendered_three="$(IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" IBC_LAUNCH=no docker compose -p "${PROJECT}-three" -f "$(host_path "${three_file}")" --profile live --profile paper --profile desk-a config --format json 2>/dev/null)"
check "uncommented, the block adds the service ib-gateway-desk-a" "${rendered_three}" '(.services | keys) == ["ib-gateway-desk-a", "ib-gateway-live", "ib-gateway-paper"]'
check "the added gateway has the same hardening settings" "${rendered_three}" \
  "${hardening}"' (.services["ib-gateway-desk-a"] | hardening) == (.services["ib-gateway-live"] | hardening)'
check "the added gateway has its own instance name, port 4011, secrets and volumes" "${rendered_three}" \
  '. as $c | .services["ib-gateway-desk-a"] | .environment.IBGW_INSTANCE == "desk-a" and (.ports | length == 1 and (.[0].published | tostring) == "4011" and .[0].host_ip == "127.0.0.1") and ([.secrets[].source | $c.secrets[.].file] | all(test("[^A-Za-z0-9._-]desk-a[^A-Za-z0-9._-]ib-(username|password)$"))) and ([.volumes[].source] | all(test("desk-a")))'
check "the added gateway's relay port matches its trading mode (live 4003, paper 4004)" "${rendered_three}" \
  '.services["ib-gateway-desk-a"] | (.environment.TRADING_MODE == "live" and .ports[0].target == 4003) or (.environment.TRADING_MODE == "paper" and .ports[0].target == 4004)'
# compose/README.md shows the same block; the two must not drift apart.
readme_block="$(awk '/<!-- third-gateway:start -->/{inside=1; next} /<!-- third-gateway:end -->/{inside=0} inside && !/^```/ && NF' "${repo_root}/compose/README.md" 2>/dev/null)"
file_block="$(awk '/^ *# >>> /{n++; next} /^ *# <<< /{n++; next} n==1 && NF' "${three_file}" 2>/dev/null)"
if [ -n "${readme_block}" ] && [ "${readme_block}" = "${file_block}" ]; then
  pass "compose/README.md shows the service block exactly as the file carries it"
else
  fail "README block" "the block between the third-gateway markers of compose/README.md differs from the commented block of the compose file"
fi

echo "== multi-gateway compose: start live and paper together (test mode) =="
live_container="${multi_project}-ib-gateway-live-1"
paper_container="${multi_project}-ib-gateway-paper-1"
up_multi() { IBGW_LIVE_PORT="${LIVE_PORT}" IBGW_PAPER_PORT="${PAPER_PORT}" compose_multi --profile live --profile paper "$@"; }
up_multi down -v >/dev/null 2>&1 || true
if up_multi up -d >/dev/null 2>&1 && wait_for 180 container_healthy "${live_container}" && wait_for 180 container_healthy "${paper_container}"; then
  pass "both gateways start from the file as shipped and become healthy (test mode)"
else
  fail "compose up" "$(up_multi logs 2>&1 | tail -5)"
fi
for instance in live paper; do
  container="${multi_project}-ib-gateway-${instance}-1"
  relay_port=4003
  if [ "${instance}" = "paper" ]; then relay_port=4004; fi
  if in_container "${container}" 'test "$(cat /var/log/ibgateway/state/phase)" = test-mode'; then
    pass "${instance}: phase file says test-mode"
  else
    fail "${instance} phase" "unexpected: $(in_container "${container}" 'cat /var/log/ibgateway/state/phase' 2>/dev/null)"
  fi
  if in_container "${container}" "jq -es --arg i ${instance} '[.[] | select(.event == \"container_start\")] | length == 1 and .[0].data.instance == \$i and .[0].data.trading_mode == \$i' /var/log/ibgateway/events/events.jsonl >/dev/null"; then
    pass "${instance}: the container_start event carries its own instance in .data.instance"
  else
    fail "${instance} instance" "$(in_container "${container}" 'head -1 /var/log/ibgateway/events/events.jsonl | cut -c1-300' 2>/dev/null)"
  fi
  if in_container "${container}" "grep -q '^IbLoginId=dummy${instance}\$' /run/brokersre/config.ini"; then
    pass "${instance}: the gateway reads its own username, not the other one's"
  else
    fail "${instance} secrets" "config.ini does not hold this instance's username"
  fi
  if in_container "${container}" "timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${relay_port}'"; then
    pass "${instance}: the relay listens on ${relay_port}, the port the host port maps to"
  else
    fail "${instance} relay" "${relay_port} not listening"
  fi
  if [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "${container}" 2>/dev/null)" = "true [ALL]" ]; then
    pass "${instance}: runs with a read-only root filesystem and without capabilities"
  else
    fail "${instance} hardening" "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "${container}" 2>&1)"
  fi
done
if [ "$(docker port "${live_container}" 4003/tcp 2>/dev/null)" = "127.0.0.1:${LIVE_PORT}" ] && [ "$(docker port "${paper_container}" 4004/tcp 2>/dev/null)" = "127.0.0.1:${PAPER_PORT}" ]; then
  pass "IBGW_LIVE_PORT and IBGW_PAPER_PORT move the host ports; both stay on loopback"
else
  fail "host ports" "live: $(docker port "${live_container}" 2>&1 | tr '\n' ' ') paper: $(docker port "${paper_container}" 2>&1 | tr '\n' ' ')"
fi
if [ "$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "${live_container}" 2>/dev/null | tr ' ' '\n' | grep -c .)" = "2" ] \
  && ! docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "${live_container}" "${paper_container}" 2>/dev/null | tr ' ' '\n' | grep . | sort | uniq -d | quiet_grep .; then
  pass "the two running gateways mount four different volumes"
else
  fail "volumes" "$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "${live_container}" "${paper_container}" 2>&1 | tr '\n' ' ')"
fi
s_start=${SECONDS}
if up_multi down -v >/dev/null 2>&1 && [ $((SECONDS - s_start)) -lt 90 ] && [ -z "$(project_leftovers "${multi_project}")" ]; then
  pass "down -v stops both inside the grace period and leaves no container, volume or network"
else
  fail "compose down" "took $((SECONDS - s_start)) s; left: $(project_leftovers "${multi_project}" | tr '\n' ' ')"
fi

echo "== two services must never use the same username =="
if out="$("${check_usernames}" "${secrets_dir}" 2>&1)"; then
  pass "check-compose-usernames.sh accepts different usernames"
else
  fail "username check" "different usernames were refused: ${out}"
fi
cp "${secrets_dir}/live/ib-username" "${secrets_dir}/paper/ib-username"
out="$("${check_usernames}" "${secrets_dir}" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && [[ "${out}" == *"live and paper hold the same IBKR username"* ]] && [[ "${out}" != *dummylive* ]]; then
  pass "check-compose-usernames.sh detects the same username in live and paper (exit 1) without printing it"
else
  fail "username check" "exit ${rc}: ${out}"
fi
printf 'dummypaper' >"${secrets_dir}/paper/ib-username"

echo "== gateway and strategy on a private network (examples/compose-with-client.yml) =="
rendered_client="$(compose_client config --format json 2>/dev/null)"
check "the example renders a gateway and a strategy" "${rendered_client}" '(.services | keys) == ["ib-gateway", "strategy"]'
check "the relay is not published on the host at all" "${rendered_client}" '[.services[] | (.ports // []) | length] | add == 0'
check "the strategy starts only after the gateway is healthy" "${rendered_client}" '.services.strategy.depends_on["ib-gateway"].condition == "service_healthy"'
check "the strategy is attached to one network only, and that network is internal" "${rendered_client}" \
  '. as $c | (.services.strategy.networks | keys) as $n | ($n | length) == 1 and $c.networks[$n[0]].internal == true and (.services["ib-gateway"].networks | has($n[0]))'
check "the gateway also has a network with a way out (to IBKR)" "${rendered_client}" \
  '. as $c | [.services["ib-gateway"].networks | keys[] | select($c.networks[.].internal != true)] | length >= 1'
check_pair "the example's gateway is hardened like the reference compose" "${reference}" "${rendered_client}" \
  "${hardening}"' (.[0].services["ib-gateway"] | hardening) == (.[1].services["ib-gateway"] | hardening)'
check "the strategy placeholder is hardened too (read-only, no capabilities, no-new-privileges)" "${rendered_client}" \
  '.services.strategy | .read_only == true and .cap_drop == ["ALL"] and (.security_opt | index("no-new-privileges:true") != null)'
gateway_container="${client_project}-ib-gateway-1"
strategy_container="${client_project}-strategy-1"
compose_client down -v >/dev/null 2>&1 || true
if compose_client up -d >/dev/null 2>&1 && container_healthy "${gateway_container}"; then
  pass "up returns once the gateway is healthy, then starts the strategy"
else
  fail "client up" "$(compose_client ps 2>&1 | tail -3)"
fi
# In test mode nothing answers the API behind the relay, so the strategy must wait.
if wait_for 30 bash -c "docker logs ${strategy_container} 2>&1 | grep -q 'not ready'" && ! docker logs "${strategy_container}" 2>&1 | quiet_grep 'strategy placeholder'; then
  pass "the strategy waits while the gateway's API does not answer (it has not started its command)"
else
  fail "strategy wait" "$(docker logs "${strategy_container}" 2>&1 | tail -3)"
fi
# A stand-in for the Gateway's API inside the gateway container: it answers the handshake on
# the loopback port the relay forwards to. /tmp is a noexec tmpfs, hence `bash <file>`.
docker exec -i "${gateway_container}" bash -c 'cat >/tmp/fake-api.sh' <"${repo_root}/tests/compose/fake-api.sh"
docker exec -d "${gateway_container}" socat TCP-LISTEN:4002,bind=127.0.0.1,reuseaddr,fork "EXEC:bash /tmp/fake-api.sh"
if wait_for 60 bash -c "docker logs ${strategy_container} 2>&1 | grep -q 'strategy placeholder'" && docker logs "${strategy_container}" 2>&1 | quiet_grep 'ready: ib-gateway:4004 answered the API handshake'; then
  pass "once the API answers through the relay, the strategy reaches it by service name and starts its command"
else
  fail "strategy start" "$(docker logs "${strategy_container}" 2>&1 | tail -3)"
fi
# `docker port` prints nothing for a container that does not exist, so both must be running
# for the empty answer to mean anything.
if [ "$(docker inspect -f '{{.State.Running}}' "${gateway_container}" 2>/dev/null)" = "true" ] \
  && [ "$(docker inspect -f '{{.State.Running}}' "${strategy_container}" 2>/dev/null)" = "true" ] \
  && [ -z "$(docker port "${gateway_container}" 2>/dev/null)" ] && [ -z "$(docker port "${strategy_container}" 2>/dev/null)" ]; then
  pass "neither running container publishes a port on the host"
else
  fail "published ports" "$(docker port "${gateway_container}" 2>&1 | tr '\n' ' ')"
fi
s_start=${SECONDS}
if compose_client down -v >/dev/null 2>&1 && [ $((SECONDS - s_start)) -lt 90 ] && [ -z "$(project_leftovers "${client_project}")" ]; then
  pass "down -v stops both and leaves no container, volume or network"
else
  fail "client down" "took $((SECONDS - s_start)) s; left: $(project_leftovers "${client_project}" | tr '\n' ' ')"
fi

echo "== break-glass console on top of the reference compose (compose/docker-compose.console.yml) =="
# docs/console.md tells a person to add this file with a second -f, open a bridge with
# `docker compose exec`, and point a VNC viewer at the host's loopback port. The test does the
# same, the bash client of the container suite standing in for the viewer on the host.
rendered_console="$(compose_console config --format json 2>/dev/null)"
rendered_console_default="$(IBGW_IMAGE="${IMAGE}" IBGW_SECRETS_DIR="${host_secrets}" docker compose -p "${console_project}" -f "${reference_file}" -f "${console_file}" config --format json 2>/dev/null)"
rendered_console_input="$(VNC_VIEW_ONLY=no compose_console config --format json 2>/dev/null)"
check "console: the VNC password comes from a secret file and the console is view-only by default" "${rendered_console}" \
  '.services["ib-gateway"] | .environment.VNC_SERVER_PASSWORD_FILE == "/run/secrets/vnc-password" and .environment.VNC_VIEW_ONLY == "yes" and ([.secrets[].source] | index("vnc-password") != null) and (.environment | has("VNC_SERVER_PASSWORD") | not)'
check "console: VNC_VIEW_ONLY=no in the environment of docker compose is passed on" "${rendered_console_input}" \
  '.services["ib-gateway"].environment.VNC_VIEW_ONLY == "no"'
check "console: the bridge port is published on the host's loopback only (5901 by default), the VNC port 5900 never" "${rendered_console_default}" \
  '.services["ib-gateway"].ports | ([.[] | select(.target == 5901)] | length == 1 and .[0].host_ip == "127.0.0.1" and (.[0].published | tostring) == "5901") and ([.[] | select(.target == 5900)] | length == 0)'
check "console: IBGW_CONSOLE_PORT moves the host port" "${rendered_console}" \
  ".services[\"ib-gateway\"].ports | [.[] | select(.target == 5901)] | .[0].host_ip == \"127.0.0.1\" and (.[0].published | tostring) == \"${CONSOLE_PORT}\""
check_pair "console: the hardening settings of the reference compose are unchanged" "${reference}" "${rendered_console}" \
  "${hardening}"' (.[0].services["ib-gateway"] | hardening) == (.[1].services["ib-gateway"] | hardening)'
# The reference file publishes 4001 and 4002; the running stack uses the test ports instead, so
# that a gateway already running on this host does not fail the test.
printf '%s\n' 'services:' '  ib-gateway:' '    ports: !override' \
  "      - \"127.0.0.1:${LIVE_PORT}:4003\"" "      - \"127.0.0.1:${PAPER_PORT}:4004\"" "      - \"127.0.0.1:${CONSOLE_PORT}:5901\"" >"${work_dir}/console-test-ports.yml"
up_console() { compose_console -f "$(host_path "${work_dir}/console-test-ports.yml")" "$@"; }
console_container="${console_project}-ib-gateway-1"
console_logs() { docker logs "${console_container}" 2>&1; }
# shellcheck disable=SC2329  # invoked through wait_for
console_has_event() { console_logs | grep -q "\"event\":\"$1\""; }
bridge_open() { in_container "${console_container}" 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/5901" 2>/dev/null'; }
bridge_closed() { [ "$(docker inspect -f '{{.State.Running}}' "${console_container}" 2>/dev/null)" = "true" ] && ! bridge_open; }
up_console down -v --remove-orphans >/dev/null 2>&1 || true
if up_console up -d >/dev/null 2>&1 && wait_for 60 console_has_event vnc_enabled \
  && console_logs | jq_image -es 'map(select(.event == "vnc_enabled")) | length == 1 and .[0].data.view_only == "yes"' >/dev/null 2>&1; then
  pass "console: the reference compose with the override starts (hardened, test mode) with the console on, view-only"
else
  fail "console up" "$(console_logs | tail -3 | cut -c1-300)"
fi
if bridge_closed; then
  pass "console: until a person opens the bridge nothing listens on the bridge port"
else
  fail "console bridge" "5901 listens inside the container before the bridge was opened"
fi
# The two commands of docs/console.md, word for word after the compose options.
up_console exec -d ib-gateway socat TCP-LISTEN:5901,fork,reuseaddr TCP:127.0.0.1:5900 >/dev/null 2>&1
wait_for 15 bridge_open
viewer_out="$(bash "${repo_root}/tests/container/vnc-client.sh" --host 127.0.0.1 --port "${CONSOLE_PORT}" --password-file "${secrets_dir}/vnc-password" --hold 1 2>&1)"
viewer_rc=$?
if [ "${viewer_rc}" -eq 0 ] && wait_for 15 console_has_event vnc_client_disconnected \
  && console_logs | jq_image -es 'map(select(.event == "vnc_client_connected")) | length == 1 and .[0].level == "warn" and .[0].data.view_only == "yes"' >/dev/null 2>&1; then
  pass "console: a viewer on the host reaches the console through the bridge, and the visit is two events"
else
  fail "console viewer" "exit ${viewer_rc} (${viewer_out}); logs: $(console_logs | tail -2 | cut -c1-300)"
fi
if console_logs | grep -qF -- "$(cat "${secrets_dir}/vnc-password")"; then
  fail "console leak" "the VNC password appears in the container's output"
else
  pass "console: the VNC password is not in the container's output"
fi
up_console exec -T ib-gateway pkill -f TCP-LISTEN:5901 >/dev/null 2>&1
if wait_for 10 bridge_closed && [ "$(docker inspect -f '{{.State.Running}}' "${console_container}" 2>/dev/null)" = "true" ] \
  && in_container "${console_container}" 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/4004"'; then
  pass "console: closing the bridge leaves the gateway and its API relay running"
else
  fail "console bridge close" "bridge still open, the container stopped, or the API relay is gone"
fi
if up_console down -v >/dev/null 2>&1 && [ -z "$(project_leftovers "${console_project}")" ]; then
  pass "console: down -v leaves no container, volume or network"
else
  fail "console down" "left: $(project_leftovers "${console_project}" | tr '\n' ' ')"
fi

echo
if [ "${failures}" -eq 0 ]; then
  echo "ALL COMPOSE TESTS PASSED"
  exit 0
fi
echo "${failures} compose test(s) FAILED"
exit 1

#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ and ${ are literal text for grep or run inside a container
# Tests for docs/recipes: Vector configurations that ship the gateway's events and resource
# samples to Grafana Loki, an OpenTelemetry collector and Datadog.
#
# What is proved, offline and without the gateway image:
#   1. the Vector image is pinned by digest, in exactly one place (docker-compose.vector.yml);
#   2. every recipe passes `vector validate` in that image as shipped (placeholder endpoints,
#      fake secrets, no network) and reads no environment variable;
#   3. every recipe reads events/events.jsonl and metrics/metrics.jsonl only, never the raw
#      IBC and Gateway logs;
#   4. the compose file runs Vector as a non-root user on a read-only root filesystem without
#      capabilities, the log volume read-only;
#   5. started from that compose file as shipped, every recipe delivers the sample lines to a
#      stand-in receiver, drops a line cut short, does not send anything twice after a restart
#      or a re-creation of the container (checkpoints on the volume), continues with new lines
#      and follows a rotation of the file, and sends the credential from its secret file. For
#      this the recipe's one address line is pointed at the stand-in in a copy (what a user
#      does with their own address); everything else is the file as shipped.
# What is NOT proved: delivery to a real Loki, collector or Datadog. The stand-in is a second
# Vector (tests/recipes/receiver.yaml): Vector's own receiving side of OTLP/HTTP and of the
# Datadog logs intake, and for Loki an HTTP server that accepts the push path.
#
# Files are copied into containers (`docker cp`), not bind-mounted, except the two mounts the
# compose file itself defines (the recipe and the secrets directory).
#
# Usage: tests/recipes/run.sh
# Environment (optional): RECIPES_TEST_PREFIX  prefix of every container, volume and network
#   this test creates (default recipes-test).
# Exit code: 0 when every test passed. Each test prints PASS/FAIL with its reason.
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1
PREFIX="${RECIPES_TEST_PREFIX:-recipes-test}"
failures=0

# quiet_grep <grep arguments...>: grep that says only yes or no, reading ALL of its input.
# Not `grep -q`: under pipefail a quiet grep exits at its first match, the writer in front of
# it dies of SIGPIPE (exit 141) and the pipeline is false although the text was found. In a
# check of the form "if a credential is in the log, fail; else pass" that is a false pass.
quiet_grep() { grep "$@" >/dev/null; }

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
recipes_dir="${repo_root}/docs/recipes"
fixtures_dir="${repo_root}/tests/recipes/fixtures"
compose_file="${recipes_dir}/docker-compose.vector.yml"
recipes=(loki otlp datadog)

work_dir="$(mktemp -d)"
secrets_dir="${work_dir}/secrets"
mkdir -p "${secrets_dir}"
# Obviously fake credentials, assembled so that no scanner takes this file for a leak.
loki_user="recipe""user"
loki_password="recipe""pass-not-real"
otlp_token="recipe""token-not-real"
# Thirty-two characters like a Datadog API key, generated so that no literal is in this file.
datadog_credential="$(printf 'ab%.0s' {1..16})"
printf '%s\n' "${loki_user}" >"${secrets_dir}/loki_username"
printf '%s\n' "${loki_password}" >"${secrets_dir}/loki_password"
printf '%s\n' "${otlp_token}" >"${secrets_dir}/otlp_token"
printf '%s\n' "${datadog_credential}" >"${secrets_dir}/datadog_api_key"
chmod -R a+rX "${work_dir}"

network="${PREFIX}-net"
logs_volume="${PREFIX}-logs"
receiver="${PREFIX}-receiver"
helper="${PREFIX}-helper"
project="${PREFIX}"
shipper="${project}-log-shipper-1"

image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "${compose_file}" 2>/dev/null | head -n 1)"

# compose_recipe CONFIG ARGS...: docker compose on the shipped file with CONFIG as the recipe,
# the test's log volume and secrets, and the test network as the project's default network
# (the one thing the shipped file cannot know).
compose_recipe() {
  local config="$1"
  shift
  VECTOR_CONFIG="$(host_path "${config}")" VECTOR_SECRETS_DIR="$(host_path "${secrets_dir}")" IBGW_LOGS_VOLUME="${logs_volume}" \
    docker compose -p "${project}" -f "$(host_path "${compose_file}")" -f "$(host_path "${work_dir}/network.yml")" "$@"
}

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  if [ -f "${work_dir}/network.yml" ]; then
    compose_recipe "${recipes_dir}/vector-loki.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  docker rm -f "${receiver}" "${helper}" "${PREFIX}-validate" >/dev/null 2>&1 || true
  docker volume rm "${logs_volume}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT

wait_for() { # seconds command...
  local t="$1"
  shift
  for _ in $(seq 1 "${t}"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

echo "== the Vector image =="
if [[ "${image}" =~ ^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]; then
  pass "the compose file pins the Vector image by tag and digest"
else
  fail "image pin" "docker-compose.vector.yml does not name an image as name:tag@sha256:<digest> (got '${image}')"
  echo "1 recipe test(s) FAILED (no image to test with)"
  exit 1
fi
# A second copy of the version would go stale; every other file refers to the compose file.
mentions="$(grep -rhoE 'timberio/vector[:@][A-Za-z0-9._@:-]+' "${recipes_dir}" "${repo_root}/tests/recipes" 2>/dev/null | sort -u)"
if [ "${mentions}" = "${image}" ]; then
  pass "the Vector version and digest are written in one place only"
else
  fail "one pin" "found: $(tr '\n' ' ' <<<"${mentions}")"
fi
# The Azure pack ships the same shipper (compose/docker-compose.azure.yml). Two different
# Vector versions in one repository would be bumped, scanned and trusted separately, and one
# of them would be forgotten: the two pins must be the same image.
azure_image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(timberio\/vector[^[:space:]]*\).*$/\1/p' "${repo_root}/compose/docker-compose.azure.yml" | head -n 1)"
if [ -n "${azure_image}" ] && [ "${azure_image}" = "${image}" ]; then
  pass "the recipes and the Azure pack pin the same Vector image"
else
  fail "same pin as the Azure pack" "recipes '${image}', compose/docker-compose.azure.yml '${azure_image:-none found}'"
fi

# validate RECIPE [docker-create-options...]: run `vector validate` on the recipe in a fresh
# container without a network; the recipe and the fake secrets are copied in. Prints Vector's
# output and returns its status.
validate() {
  local recipe="$1" name="${PREFIX}-validate" status
  shift
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker create --name "${name}" --network none "$@" "${image}" validate --skip-healthchecks --deny-warnings /recipe.yaml >/dev/null || return 125
  docker cp "$(host_path "${recipes_dir}/vector-${recipe}.yaml")" "${name}:/recipe.yaml" >/dev/null || return 125
  docker cp "$(host_path "${secrets_dir}")" "${name}:/run/secrets" >/dev/null || return 125
  docker start -a "${name}" 2>&1
  status=$?
  docker rm -f "${name}" >/dev/null 2>&1 || true
  return "${status}"
}

echo "== every recipe is a valid Vector configuration =="
for recipe in "${recipes[@]}"; do
  if [ ! -f "${recipes_dir}/vector-${recipe}.yaml" ]; then
    fail "${recipe}: validate" "docs/recipes/vector-${recipe}.yaml does not exist"
    continue
  fi
  if output="$(validate "${recipe}")"; then
    pass "${recipe}: vector validate accepts the recipe as shipped (placeholder endpoint, fake secrets, no network)"
  else
    fail "${recipe}: validate" "$(tail -n 6 <<<"${output}" | tr '\n' ' ' | cut -c1-400)"
  fi
  # This Vector version does not expand ${VAR} unless it is started with
  # --dangerously-allow-env-var-interpolation: a variable in a recipe would be sent as text.
  if grep -v -E '^[[:space:]]*#' "${recipes_dir}/vector-${recipe}.yaml" | quiet_grep -F '${'; then
    fail "${recipe}: no environment variables" "the recipe uses \${...}, which this Vector version does not expand"
  else
    pass "${recipe}: reads no environment variable (settings are edited in the file, secrets come from files)"
  fi
  # The raw logs can hold the IBKR username: a recipe reads the two contract files only.
  includes="$(grep -E '^[[:space:]]*-[[:space:]]*/var/log/ibgateway/' "${recipes_dir}/vector-${recipe}.yaml" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sort | tr '\n' ' ')"
  if [ "${includes}" = "/var/log/ibgateway/events/events.jsonl* /var/log/ibgateway/metrics/metrics.jsonl* " ] \
    && ! grep -v -E '^[[:space:]]*#' "${recipes_dir}/vector-${recipe}.yaml" | quiet_grep -E '/(ibc|jts)/|\*\*'; then
    pass "${recipe}: reads events.jsonl and metrics.jsonl (and their rotated generations) only"
  else
    fail "${recipe}: files read" "include list is '${includes}'"
  fi
done

echo "== the compose file =="
printf '%s\n' 'networks:' '  default:' '    external: true' "    name: ${network}" >"${work_dir}/network.yml"
docker network rm "${network}" >/dev/null 2>&1 || true
docker network create --internal "${network}" >/dev/null
docker volume rm "${logs_volume}" >/dev/null 2>&1 || true
docker volume create "${logs_volume}" >/dev/null
rendered="$(compose_recipe "${recipes_dir}/vector-loki.yaml" config 2>&1)"
rendered_status=$?
compose_says() { # description extended-regex (matched against the rendered configuration)
  if [ "${rendered_status}" -eq 0 ] && grep -q -E "$2" <<<"${rendered}"; then pass "compose: $1"; else fail "compose" "$1"; fi
}
compose_says "runs as a non-root user" '^    user: "?1000:1000"?$'
compose_says "read-only root filesystem" '^    read_only: true$'
compose_says "every capability dropped" '^      - ALL$'
compose_says "no-new-privileges" 'no-new-privileges:true'
# A mount is rendered as a block: its target, then `read_only: true` when it is read-only.
mount_read_only() { grep -A 1 -F "target: $1" <<<"${rendered}" | quiet_grep -E '^[[:space:]]+read_only: true$'; }
if [ "${rendered_status}" -eq 0 ] && mount_read_only /var/log/ibgateway && mount_read_only /run/secrets && mount_read_only /etc/vector/vector.yaml \
  && ! mount_read_only /var/tmp; then
  pass "compose: the log volume, the secrets and the recipe are mounted read-only; only the data volume is writable"
else
  fail "compose" "a mount that must be read-only is not, or the data volume is"
fi
if [ "${rendered_status}" -eq 0 ] && [ "$(grep -c -E '^[[:space:]]+published:' <<<"${rendered}")" = "0" ]; then
  pass "compose: publishes no port"
else
  fail "compose" "the shipper publishes a port, or the file does not render: $(tail -n 2 <<<"${rendered}" | tr '\n' ' ')"
fi

echo "== delivery to a stand-in receiver, restart, new lines, rotation =="
# The stand-in: Vector's own receiving side of each protocol, on the test network only.
docker rm -f "${receiver}" >/dev/null 2>&1 || true
docker create --name "${receiver}" --network "${network}" --network-alias receiver "${image}" --config /receiver.yaml >/dev/null
docker cp "$(host_path "${repo_root}/tests/recipes/receiver.yaml")" "${receiver}:/receiver.yaml" >/dev/null
docker start "${receiver}" >/dev/null
# in_helper SCRIPT: run a shell snippet with the log volume mounted read-write at /logs.
in_helper() { docker run --rm --name "${helper}" --network none -v "${logs_volume}:/logs" --entrypoint sh "${image}" -c "$1"; }
# received KIND: how many of the gateway's lines the stand-in has for this recipe. For Loki the
# lines travel inside the push body, so their marker is counted; the other two are one line of
# the receiver's file per record.
received() {
  case "$1" in
    loki) docker exec "${receiver}" sh -c 'grep -o "boot_id" /var/tmp/loki.jsonl 2>/dev/null | wc -l' ;;
    *) docker exec "${receiver}" sh -c "cat /var/tmp/$1.jsonl 2>/dev/null | wc -l" ;;
  esac
}
received_is() { [ "$(received "$1")" -eq "$2" ]; }
receiver_has() { docker exec "${receiver}" grep -q -F -- "$2" "/var/tmp/$1.jsonl"; }
# still COUNT KIND: the count is COUNT now and is still COUNT five seconds later.
still() {
  received_is "$2" "$1" || return 1
  sleep 5
  received_is "$2" "$1"
}

for recipe in "${recipes[@]}"; do
  config="${recipes_dir}/vector-${recipe}.yaml"
  if [ ! -f "${config}" ]; then
    fail "${recipe}: delivery" "docs/recipes/vector-${recipe}.yaml does not exist"
    continue
  fi
  # The one address line of the recipe, pointed at the stand-in in a copy. Loki and OTLP have
  # an address line to replace; the Datadog sink derives its address from `site`, so its
  # `endpoint` option is added below that line.
  shipped="${config}"
  config="${work_dir}/vector-${recipe}.yaml"
  case "${recipe}" in
    loki) sed -E 's|^([[:space:]]*)endpoint:.*$|\1endpoint: "http://receiver:3100"|' "${shipped}" >"${config}" ;;
    otlp) sed -E 's|^([[:space:]]*)uri:.*$|\1uri: "http://receiver:4318/v1/logs"|' "${shipped}" >"${config}" ;;
    datadog) sed -E 's|^([[:space:]]*)site:.*$|&\n\1endpoint: "http://receiver:8080"|' "${shipped}" >"${config}" ;;
  esac
  if [ "$(grep -c -F 'http://receiver:' "${config}")" != "1" ] || [ "$(diff "${shipped}" "${config}" | grep -c '^[<>]')" -gt 2 ]; then
    fail "${recipe}: delivery" "could not point exactly one address line of a copy at the stand-in"
    continue
  fi
  compose_recipe "${config}" down -v --remove-orphans >/dev/null 2>&1 || true
  # A fresh log volume: five events, one line cut short, two resource samples.
  in_helper 'rm -rf /logs/events /logs/metrics && mkdir -p /logs/events /logs/metrics'
  docker rm -f "${helper}" >/dev/null 2>&1 || true
  docker create --name "${helper}" -v "${logs_volume}:/logs" "${image}" >/dev/null
  docker cp "$(host_path "${fixtures_dir}/events/events.jsonl")" "${helper}:/logs/events/events.jsonl" >/dev/null
  docker cp "$(host_path "${fixtures_dir}/metrics/metrics.jsonl")" "${helper}:/logs/metrics/metrics.jsonl" >/dev/null
  docker rm -f "${helper}" >/dev/null 2>&1 || true
  in_helper 'chmod -R a+rX /logs'
  before="$(received "${recipe}")"

  if compose_recipe "${config}" up -d >/dev/null 2>&1 && wait_for 60 received_is "${recipe}" "$((before + 7))"; then
    pass "${recipe}: started from the compose file, the five events and two samples reach the stand-in"
  else
    fail "${recipe}: delivery" "stand-in has $(received "${recipe}") of $((before + 7)); shipper: $(docker logs "${shipper}" 2>&1 | tail -n 3 | tr '\n' ' ' | cut -c1-500)"
    continue
  fi
  if [ "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "${shipper}" 2>/dev/null)" = "1000:1000 true [ALL]" ] \
    && [ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/log/ibgateway"}}{{.RW}}{{end}}{{end}}' "${shipper}" 2>/dev/null)" = "false" ]; then
    pass "${recipe}: the shipper runs as uid 1000, read-only, without capabilities, the log volume read-only"
  else
    fail "${recipe}: hardening" "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' "${shipper}" 2>&1)"
  fi
  case "${recipe}" in
    loki)
      expected_auth="Basic $(printf '%s:%s' "${loki_user}" "${loki_password}" | base64 | tr -d '\n')"
      if receiver_has loki "${expected_auth}" && receiver_has loki 'job=\"ibgateway\"' && receiver_has loki 'instance=\"default\"' \
        && receiver_has loki 'stream=\"events\"' && receiver_has loki 'stream=\"metrics\"' && receiver_has loki 'level=\"error\"' \
        && receiver_has loki 'src=\"vnc\"' && receiver_has loki '\"event\":\"login_failed_dialog\"'; then
        pass "loki: basic auth from the secret files, the labels job, instance, stream, src and level, the JSON line unchanged"
      else
        fail "loki: content" "$(docker exec "${receiver}" sh -c 'tail -c 600 /var/tmp/loki.jsonl' 2>&1 | tr -d '\000-\037' | cut -c1-600)"
      fi
      ;;
    otlp)
      if receiver_has otlp "Bearer ${otlp_token}" && receiver_has otlp 'login_failed_dialog' && receiver_has otlp 'ERROR' \
        && receiver_has otlp 'ib-gateway' && receiver_has otlp 'service.instance.id' && receiver_has otlp 'needs-human'; then
        pass "otlp: bearer token from the secret file; records carry severity, event name, service and instance"
      else
        fail "otlp: content" "$(docker exec "${receiver}" sh -c 'tail -n 1 /var/tmp/otlp.jsonl' 2>&1 | cut -c1-700)"
      fi
      ;;
    datadog)
      if receiver_has datadog "${datadog_credential}" && receiver_has datadog '"status":"error"' && receiver_has datadog '"ddsource":"ibgateway"' \
        && receiver_has datadog '"service":"ib-gateway"' && receiver_has datadog 'instance:default' && receiver_has datadog 'login_failed_dialog'; then
        pass "datadog: API key from the secret file; records carry status, source, service and tags"
      else
        fail "datadog: content" "$(docker exec "${receiver}" sh -c 'tail -n 1 /var/tmp/datadog.jsonl' 2>&1 | cut -c1-700)"
      fi
      ;;
  esac
  if receiver_has "${recipe}" '06:20:31.9'; then
    fail "${recipe}: cut line" "the line that was cut short was shipped"
  else
    pass "${recipe}: the line that was cut short is not shipped"
  fi

  compose_recipe "${config}" restart log-shipper >/dev/null 2>&1
  if wait_for 30 docker exec "${shipper}" true && still "$((before + 7))" "${recipe}"; then
    pass "${recipe}: after a restart nothing is sent twice"
  else
    fail "${recipe}: restart" "stand-in has $(received "${recipe}") lines, expected $((before + 7))"
  fi
  in_helper 'printf "%s\n" "{\"ts\":\"2026-11-12T06:21:05.000Z\",\"src\":\"entrypoint\",\"level\":\"info\",\"event\":\"shutdown_requested\",\"msg\":\"SIGTERM/SIGINT received; stopping IB Gateway tidily\",\"boot_id\":\"0123456789abcdef\",\"seq\":6}" >>/logs/events/events.jsonl
    printf "%s\n" "{\"ts\":\"2026-11-12T06:21:06.000Z\",\"src\":\"metrics\",\"boot_id\":\"0123456789abcdef\",\"seq\":3,\"phase\":\"stopping\",\"pids\":12}" >>/logs/metrics/metrics.jsonl'
  if wait_for 60 received_is "${recipe}" "$((before + 9))" && still "$((before + 9))" "${recipe}"; then
    pass "${recipe}: two new lines are sent, and only those"
  else
    fail "${recipe}: new lines" "stand-in has $(received "${recipe}") lines, expected $((before + 9))"
  fi
  # The gateway rotates by renaming the file and starting a new one.
  in_helper 'mv /logs/events/events.jsonl /logs/events/events.jsonl.1
    printf "%s\n" "{\"ts\":\"2026-11-12T06:21:07.000Z\",\"src\":\"entrypoint\",\"level\":\"info\",\"event\":\"shutdown_complete\",\"msg\":\"all processes stopped\",\"boot_id\":\"0123456789abcdef\",\"seq\":7}" >/logs/events/events.jsonl
    chmod a+r /logs/events/events.jsonl'
  if wait_for 60 received_is "${recipe}" "$((before + 10))" && still "$((before + 10))" "${recipe}"; then
    pass "${recipe}: after a rotation the new file is followed and the renamed one is not sent again"
  else
    fail "${recipe}: rotation" "stand-in has $(received "${recipe}") lines, expected $((before + 10))"
  fi
  # A new container on the same data volume: the checkpoints are on the volume.
  compose_recipe "${config}" up -d --force-recreate >/dev/null 2>&1
  if wait_for 30 docker exec "${shipper}" true && still "$((before + 10))" "${recipe}"; then
    pass "${recipe}: a re-created container continues from the checkpoints on the data volume"
  else
    fail "${recipe}: recreate" "stand-in has $(received "${recipe}") lines, expected $((before + 10))"
  fi
  if docker logs "${shipper}" 2>&1 | quiet_grep -F -e "${loki_password}" -e "${otlp_token}" -e "${datadog_credential}"; then
    fail "${recipe}: secret in the log" "a credential appears in the shipper's output"
  else
    pass "${recipe}: no credential in the shipper's output"
  fi
  compose_recipe "${config}" down -v --remove-orphans >/dev/null 2>&1 || true
done

echo
if [ "${failures}" -eq 0 ]; then
  echo "ALL RECIPE TESTS PASSED"
  exit 0
fi
echo "${failures} recipe test(s) FAILED"
exit 1

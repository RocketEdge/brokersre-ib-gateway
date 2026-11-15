#!/usr/bin/env bash
# Fresh volumes: the gateway image and the sidecar image CREATED together, the way
# `docker compose up` does it, before either has written anything.
#
# Why this is a test of its own: an EMPTY named volume takes the owner and mode of its mount
# point in the image of the LAST container created on it, and compose creates every container
# before it starts any. The sidecar is created after the gateway (depends_on). A sidecar image
# whose /var/log/ibgateway was root-owned therefore turned the gateway's log volume
# root-owned, the gateway (uid 1000) failed its preflight (dirs_not_writable), and its restart
# policy started it again and again (found with the first real session, 2026-11-16).
# sidecar/tests/e2e/run.sh could not show it: it uses `docker run`, so the gateway has written
# to the volume before the sidecar exists.
#
# Two protections are checked, each on its own:
#   1. the sidecar IMAGE owns that mount point as the gateway does (a plain read-only mount,
#      as a hand-written compose file or `docker run` has it, leaves the volume alone);
#   2. the shipped compose overrides mount the volume with `nocopy`, which keeps Docker from
#      applying the mount point's owner at all (so an older sidecar image is safe too).
# Then the shipped files are started as shipped, on fresh volumes, for both sidecar overrides.
#
# Nothing here can log in: the gateway runs with IBC_LAUNCH=no (IBC and IB Gateway are not
# started) and the credentials are dummies.
#
# Usage: sidecar/tests/e2e/fresh-volumes.sh <gateway image> <sidecar image>
# Environment (optional): FRESH_RELAY_PORT (default 14204) and FRESH_SIDECAR_PORT (default
#   19810): host ports used while the stacks run, so that a gateway already running on this
#   host does not fail the test (the shipped files publish 4001, 4002 and 9810).
# Exit code: the number of failed checks.
set -uo pipefail

# quiet_grep <grep arguments...>: grep that says only yes or no, reading ALL of its input.
# Not `grep -q`: under pipefail a quiet grep exits at its first match, the writer in front of
# it dies of SIGPIPE (exit 141) and the pipeline is false although the text was found.
quiet_grep() { grep "$@" >/dev/null; }
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1
GW_IMAGE="${1:?usage: fresh-volumes.sh <gateway image> <sidecar image>}"
SC_IMAGE="${2:?usage: fresh-volumes.sh <gateway image> <sidecar image>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../.." && pwd)"
RELAY_PORT="${FRESH_RELAY_PORT:-14204}"
SIDECAR_PORT="${FRESH_SIDECAR_PORT:-19810}"
PROJECT="sidecar-fresh"
VOLUME="sidecar-fresh-plain-logs"
GW="sidecar-fresh-plain-gateway"
SC="sidecar-fresh-plain-sidecar"
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

work="$(mktemp -d)"
mkdir -p "${work}/secrets"
# Obviously fake credentials (never used: IBC is not started) and a webhook URL on a name
# that can never resolve (RFC 2606), for the channel the shipped override configures.
printf 'dummyuser' >"${work}/secrets/ib-username"
printf 'dummypassword-not-real' >"${work}/secrets/ib-password"
printf 'https://example.invalid/not-a-real-webhook' >"${work}/secrets/notify-teams-url"
chmod -R a+rX "${work}"
host_work="$(host_path "${work}")"
compose_dir="$(host_path "${repo_root}/compose")"

# What the test changes about the shipped files, and nothing else: the sidecar image under
# test, host ports that do not collide, and where the notification secret file is.
printf '%s\n' \
  'services:' \
  '  ib-gateway:' \
  '    ports: !override' \
  "      - \"127.0.0.1:${RELAY_PORT}:4004\"" \
  "      - \"127.0.0.1:${SIDECAR_PORT}:9810\"" \
  '  sidecar:' \
  "    image: ${SC_IMAGE}" \
  '    ports: !reset []' \
  'secrets:' \
  '  notify-teams-url:' \
  "    file: ${host_work}/secrets/notify-teams-url" \
  >"${work}/fresh-test.yml"

# stack <override file> <compose arguments...>: the reference compose file, one sidecar
# override and the test's own changes, with the images under test and without a login.
stack() {
  local override="$1"
  shift
  IBGW_IMAGE="${GW_IMAGE}" IBGW_SECRETS_DIR="${host_work}/secrets" IBC_LAUNCH=no TRADING_MODE=paper \
    docker compose -p "${PROJECT}" -f "${compose_dir}/docker-compose.example.yml" \
    -f "${compose_dir}/${override}" -f "${host_work}/fresh-test.yml" "$@"
}

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  stack docker-compose.sidecar.yml down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "${GW}" "${SC}" >/dev/null 2>&1 || true
  docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT
stack docker-compose.sidecar.yml down -v --remove-orphans >/dev/null 2>&1 || true
docker rm -f "${GW}" "${SC}" >/dev/null 2>&1 || true
docker volume rm "${VOLUME}" >/dev/null 2>&1 || true

# volume_owner <volume>: "uid:gid mode" of the volume's top directory. It is read through a
# mount point that does not exist in the image, so the probe itself changes nothing.
volume_owner() {
  docker run --rm -v "$1:/probe-volume:ro" --entrypoint stat "${SC_IMAGE}" -c '%u:%g %a' /probe-volume 2>&1
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

echo "== the images alone: gateway created first, sidecar last, a plain read-only mount =="
expected="$(docker run --rm --entrypoint stat "${GW_IMAGE}" -c '%u:%g %a' /var/log/ibgateway 2>&1)"
if [ "${expected}" = "1000:1000 755" ]; then
  pass "the gateway image owns its log directory as 1000:1000, mode 755"
else
  fail "gateway image" "/var/log/ibgateway is ${expected}"
fi
docker create --name "${GW}" -v "${VOLUME}:/var/log/ibgateway" "${GW_IMAGE}" >/dev/null
docker create --name "${SC}" -v "${VOLUME}:/var/log/ibgateway:ro" "${SC_IMAGE}" >/dev/null
owner="$(volume_owner "${VOLUME}")"
if [ "${owner}" = "${expected}" ]; then
  pass "an empty log volume keeps the gateway's owner when the sidecar is created after the gateway"
else
  fail "fresh volume" "the volume is ${owner} after the sidecar was created; the gateway needs ${expected}"
fi
docker rm -f "${GW}" "${SC}" >/dev/null 2>&1 || true
docker volume rm "${VOLUME}" >/dev/null 2>&1 || true

for override in docker-compose.sidecar.yml docker-compose.sidecar-shared.yml; do
  echo "== ${override}: as shipped, on fresh volumes =="
  gateway="${PROJECT}-ib-gateway-1"
  sidecar="${PROJECT}-sidecar-1"
  # The mount as compose understands it: read-only, and nocopy so that the owner of the
  # sidecar image's mount point is never applied to the volume.
  if stack "${override}" config --format json 2>/dev/null | docker run --rm -i --entrypoint python "${SC_IMAGE}" -c '
import json, sys
mounts = [m for m in json.load(sys.stdin)["services"]["sidecar"]["volumes"] if m["target"] == "/var/log/ibgateway"]
ok = len(mounts) == 1 and mounts[0].get("read_only") is True and mounts[0].get("volume", {}).get("nocopy") is True
sys.exit(0 if ok else 1)
'; then
    pass "${override}: the log volume is mounted read-only and with nocopy"
  else
    fail "${override} mount" "the sidecar's mount of /var/log/ibgateway is not read-only with nocopy"
  fi
  stack "${override}" down -v --remove-orphans >/dev/null 2>&1 || true
  if stack "${override}" up -d >"${work}/up.log" 2>&1; then
    pass "${override}: docker compose up -d creates and starts both containers"
  else
    fail "${override} up" "$(tail -3 "${work}/up.log" | tr '\n' ' ')"
  fi
  # shellcheck disable=SC2329  # invoked through wait_for
  gateway_started() { docker logs "${gateway}" 2>&1 | quiet_grep '"event":"ibc_not_launched"'; }
  if wait_for 60 gateway_started; then
    pass "${override}: the gateway passed its preflight and finished its start (test mode, no login)"
  else
    fail "${override} gateway start" "$(docker logs "${gateway}" 2>&1 | tail -3 | cut -c1-300 | tr '\n' ' ')"
  fi
  if docker logs "${gateway}" 2>&1 | quiet_grep -e '"event":"dirs_not_writable"' -e '"event":"doctor_failed"'; then
    fail "${override} preflight" "$(docker logs "${gateway}" 2>&1 | grep -e dirs_not_writable -e doctor_failed | head -2 | cut -c1-300 | tr '\n' ' ')"
  else
    pass "${override}: no dirs_not_writable and no failed preflight"
  fi
  state="$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "${gateway}" 2>&1)"
  if [ "${state}" = "running restarts=0" ]; then
    pass "${override}: the gateway container runs and was never restarted"
  else
    fail "${override} gateway state" "${state}"
  fi
  owner="$(volume_owner "${PROJECT}_ibgw-logs")"
  if [ "${owner}" = "1000:1000 755" ]; then
    pass "${override}: the log volume belongs to the gateway (1000:1000, 755)"
  else
    fail "${override} volume" "the log volume is ${owner}"
  fi
  # The sidecar reads the volume it did not get to own: the feeds are there and followed.
  # shellcheck disable=SC2329  # invoked through wait_for
  feeds_seen() {
    docker exec "${sidecar}" python -c '
import http.client, json, sys
c = http.client.HTTPConnection("127.0.0.1", 9810, timeout=5)
c.request("GET", "/status")
d = json.loads(c.getresponse().read())
sys.exit(0 if d["gateway_feed"]["volume_present"] and d["gateway_feed"]["feeds_seen"] else 1)
'
  }
  if wait_for 60 feeds_seen; then
    pass "${override}: the sidecar sees and follows the gateway's feeds on the read-only volume"
  else
    fail "${override} sidecar feed" "$(docker logs "${sidecar}" 2>&1 | tail -2 | cut -c1-300 | tr '\n' ' ')"
  fi
  stack "${override}" down -v --remove-orphans >/dev/null 2>&1 || true
done

echo
if [ "${failures}" -eq 0 ]; then echo "FRESH VOLUMES PASSED"; else echo "${failures} FRESH-VOLUME CHECK(S) FAILED"; fi
exit "${failures}"

#!/usr/bin/env bats
# Unit tests for scripts/check-package-private.sh: publish.yml's proof that the gateway package
# is private before any image with IBKR software in it is pushed (ADR 0018). `curl` is
# replaced by a stub on PATH; nothing reaches ghcr.io.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# What ghcr.io answered without credentials, observed 2026-11-17 07:15 UTC (the cases below):
#   private package rocketedge/brokersre-agent:stable    token 401 UNAUTHORIZED
#   no such package rocketedge/does-not-exist-probe-xyz  token 403 DENIED
#   public package  rocketedge/brokersre-ib-gateway:stable  token 200, manifest 200
#   public package  rocketedge/brokersre-ib-gateway-sidecar:no-such-tag-xyz
#                                                        token 200, manifest 404 MANIFEST_UNKNOWN
# A package that may not be read anonymously is refused at the TOKEN request; a token granted
# anonymously means anonymous pulls are allowed, whatever the manifest request answers.
#
# The contract under test:
#   * private (exit 0) only when the anonymous token request is refused (401/403);
#   * public (exit 1) when the anonymous token is granted and the manifest request returns 200;
#   * anything else is inconclusive (exit 3), never private: a granted token with any other
#     manifest answer (a 404 of a public package's missing tag looked private to the first
#     version), a network error, a server error, a rate limit, a token answer without a token;
#   * no request carries a credential, and the manifest request carries only the anonymous
#     token;
#   * bad input is refused with exit 2 before any request.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-package-private.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/curl.calls"
  mkdir -p "${STUB_BIN}"
  : > "${CALLS}"
  # curl stub: every call is appended to ${CALLS} (one line, arguments separated by ' | ').
  # A URL with /token? answers with ${WORK}/token-code and the body ${WORK}/token-body; a URL
  # with /manifests/ with ${WORK}/manifest-code and ${WORK}/manifest-body. The body goes to
  # the file after -o, the code to stdout (what -w '%{http_code}' prints). ${WORK}/token-exit
  # or ${WORK}/manifest-exit makes that request fail with that curl exit code instead.
  cat > "${STUB_BIN}/curl" <<EOF
#!/usr/bin/env bash
args=("\$@")
line=""
for a in "\${args[@]}"; do line="\${line}\${a} | "; done
printf '%s\n' "\${line}" >> "${CALLS}"
out=/dev/null
url=""
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i + 1]}" ;;
    https://*) url="\${args[i]}" ;;
  esac
done
case "\${url}" in
  *"/token?"*) kind=token ;;
  *"/manifests/"*) kind=manifest ;;
  *) echo "stub: unexpected URL \${url}" >&2; exit 99 ;;
esac
if [ -f "${WORK}/\${kind}-exit" ]; then exit "\$(cat "${WORK}/\${kind}-exit")"; fi
cat "${WORK}/\${kind}-body" > "\${out}" 2>/dev/null || : > "\${out}"
cat "${WORK}/\${kind}-code"
EOF
  chmod +x "${STUB_BIN}/curl"
  export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# answer KIND CODE [BODY]: what the stub answers to the token or the manifest request.
answer() {
  printf '%s' "$2" > "${WORK}/$1-code"
  printf '%s' "${3:-}" > "${WORK}/$1-body"
}

@test "a refused anonymous token request means private, and no manifest is asked for" {
  # Observed: a package that does not exist (403 DENIED) and the private brokersre-agent
  # package (401 UNAUTHORIZED).
  answer token 403 '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 0 ]
  [[ "$output" == "private: "*"ghcr.io/rocketedge/brokersre-ib-gateway:visibility-probe"*"HTTP 403"* ]]
  [ "$(wc -l < "${CALLS}")" -eq 1 ]
  answer token 401 '{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-agent stable
  [ "$status" -eq 0 ]
  [[ "$output" == "private: "*"HTTP 401"* ]]
}

@test "a token granted anonymously is never private, whatever the manifest request answers" {
  # Observed: the public sidecar package with a tag it does not have answers token 200,
  # manifest 404 MANIFEST_UNKNOWN. The first version read that as private.
  answer token 200 '{"token":"anonymous-token"}'
  answer manifest 404 '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway-sidecar no-such-tag-xyz
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"INCONCLUSIVE"*"anonymous"*"HTTP 404"* ]]
  for code in 401 403 404; do
    answer manifest "${code}" '{"errors":[{"code":"DENIED"}]}'
    run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
    [ "$status" -eq 3 ] || { echo "manifest ${code} -> ${status}"; false; }
    [ -z "$output" ]
  done
}

@test "an anonymous read that returns the manifest means public (exit 1)" {
  # Observed: the public gateway package's tag stable answers token 200, manifest 200.
  answer token 200 '{"token":"anonymous-token"}'
  answer manifest 200 '{"schemaVersion":2}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"PUBLIC"*"ghcr.io/rocketedge/brokersre-ib-gateway:visibility-probe"* ]]
}

@test "a network error, a server error or a rate limit is inconclusive, never private" {
  echo 7 > "${WORK}/token-exit"
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  rm "${WORK}/token-exit"
  for code in 500 502 429 000; do
    answer token "${code}" ''
    run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
    [ "$status" -eq 3 ] || { echo "token ${code} -> ${status}"; false; }
  done
  answer token 200 '{"token":"anonymous-token"}'
  for code in 500 429 302; do
    answer manifest "${code}" ''
    run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
    [ "$status" -eq 3 ] || { echo "manifest ${code} -> ${status}"; false; }
  done
  echo 28 > "${WORK}/manifest-exit"
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 3 ]
}

@test "a token answer without a token is inconclusive" {
  answer token 200 '{"errors":[]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 3 ]
  answer token 200 'not json'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 3 ]
}

@test "the requests are anonymous, over HTTPS, for the right scope and tag" {
  answer token 200 '{"token":"anonymous-token"}'
  answer manifest 200 '{"schemaVersion":2}'
  GH_TOKEN=must-not-be-sent GITHUB_TOKEN=must-not-be-sent run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 1 ]
  [ "$(wc -l < "${CALLS}")" -eq 2 ]
  sed -n 1p "${CALLS}" | grep -q -F 'https://ghcr.io/token?scope=repository:rocketedge/brokersre-ib-gateway:pull&service=ghcr.io | '
  sed -n 2p "${CALLS}" | grep -q -F 'https://ghcr.io/v2/rocketedge/brokersre-ib-gateway/manifests/visibility-probe | '
  sed -n 2p "${CALLS}" | grep -q -F 'Authorization: Bearer anonymous-token | '
  run ! grep -q -i -E 'must-not-be-sent| -u | --user |Basic |--netrc|-n \|' "${CALLS}"
  run ! grep -q -E '(^| )-k( |$)|--insecure' "${CALLS}"
}

@test "bad input is refused with exit 2 before any request" {
  for args in "" "rocketedge/brokersre-ib-gateway" "RocketEdge/brokersre-ib-gateway visibility-probe" \
    "rocketedge visibility-probe" "rocketedge/brokersre-ib-gateway;id visibility-probe" \
    "rocketedge/brokersre-ib-gateway visibility probe" "rocketedge/brokersre-ib-gateway -visibility" \
    "rocketedge/brokersre-ib-gateway visibility-probe extra"; do
    # shellcheck disable=SC2086 # the words of each case are the arguments
    run --separate-stderr "${SCRIPT}" ${args}
    [ "$status" -eq 2 ] || { echo "args: '${args}' -> ${status}"; false; }
    [ -z "$output" ]
  done
  [ ! -s "${CALLS}" ]
}

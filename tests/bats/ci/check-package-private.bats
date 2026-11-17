#!/usr/bin/env bats
# Unit tests for scripts/check-package-private.sh: publish.yml's proof that the gateway package
# is private before any image with IBKR software in it is pushed (ADR 0018). `curl` is
# replaced by a stub on PATH; nothing reaches ghcr.io.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test:
#   * private (exit 0) only when an ANONYMOUS read is refused: the anonymous token request is
#     refused (401/403, what ghcr.io answers for a package nobody may read anonymously), or the
#     manifest request with the anonymous token is refused (401/403/404);
#   * public (exit 1) when the anonymous read returns the manifest;
#   * anything else is inconclusive (exit 3), never private: a network error, a server error,
#     a rate limit, a token answer without a token;
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
  answer token 403 '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 0 ]
  [[ "$output" == "private: "*"ghcr.io/rocketedge/brokersre-ib-gateway:visibility-probe"*"HTTP 403"* ]]
  [ "$(wc -l < "${CALLS}")" -eq 1 ]
  answer token 401 '{"errors":[{"code":"UNAUTHORIZED"}]}'
  run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 0 ]
}

@test "an anonymous token that cannot read the manifest means private" {
  for code in 401 403 404; do
    answer token 200 '{"token":"anonymous-token"}'
    answer manifest "${code}" '{"errors":[{"code":"DENIED"}]}'
    run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
    [ "$status" -eq 0 ] || { echo "manifest ${code} -> ${status}"; false; }
    [[ "$output" == "private: "*"HTTP ${code}"* ]]
  done
}

@test "an anonymous read that returns the manifest means public (exit 1)" {
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
  answer manifest 404 ''
  GH_TOKEN=must-not-be-sent GITHUB_TOKEN=must-not-be-sent run --separate-stderr "${SCRIPT}" rocketedge/brokersre-ib-gateway visibility-probe
  [ "$status" -eq 0 ]
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

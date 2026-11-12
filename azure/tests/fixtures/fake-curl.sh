#!/usr/bin/env bash
# Test double for curl, installed as /usr/local/bin/curl by fetch-secrets.test.sh. It plays the
# two HTTP services fetch-secrets.sh talks to (the instance metadata service and Key Vault);
# everything else in that script runs for real.
#
# Behaviour is chosen by FAKE_SCENARIO:
#   ok               token, then both secrets (the password contains JSON escapes on purpose)
#   missing-password ib-password answers 404
#   forbidden        every secret answers 403
#   no-identity      the metadata service fails (curl --fail exit code 22, no body)
#   empty-username   ib-username has an empty value
# Every call appends its full argument list to FAKE_CURL_LOG, so the test can prove that
# neither the token nor a secret value was ever passed on a command line. A secret request
# without the bearer header (read from the --config file) is answered 401.
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_CURL_LOG:?}"

output=""
config=""
write_out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --config)
      config="$2"
      shift 2
      ;;
    --write-out)
      write_out="$2"
      shift 2
      ;;
    --header | --retry | --retry-delay | --max-time | --data-urlencode)
      shift 2
      ;;
    http://* | https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# respond <http status> <body>: write the body to --output and the status to stdout when asked.
respond() {
  if [[ -n "${output}" ]]; then printf '%s' "$2" >"${output}"; fi
  if [[ "${write_out}" == '%{http_code}' ]]; then printf '%s' "$1"; fi
}

case "${url}" in
  http://169.254.169.254/metadata/instance/compute/userData*)
    # The VM's userData as the instance metadata service returns it: base64 of what the
    # template stored (FAKE_USERDATA_FILE holds the plain JSON).
    if [[ "${FAKE_SCENARIO}" == no-identity ]]; then
      echo "curl: (22) The requested URL returned error: 404" >&2
      exit 22
    fi
    respond 200 "$(base64 --wrap=0 "${FAKE_USERDATA_FILE:?}")"
    ;;
  http://169.254.169.254/*)
    if [[ "${FAKE_SCENARIO}" == no-identity ]]; then
      echo "curl: (22) The requested URL returned error: 400" >&2
      exit 22
    fi
    respond 200 '{"access_token":"CANARY_TOKEN_abc123","expires_in":"3600","token_type":"Bearer"}'
    ;;
  https://*/secrets/*)
    if [[ -z "${config}" ]] || ! grep -q '^header = "Authorization: Bearer CANARY_TOKEN_abc123"$' "${config}"; then
      respond 401 '{"error":{"code":"Unauthorized"}}'
      exit 0
    fi
    if [[ "${FAKE_SCENARIO}" == forbidden ]]; then
      respond 403 '{"error":{"code":"Forbidden"}}'
      exit 0
    fi
    case "${url}" in
      */secrets/ib-username\?*)
        if [[ "${FAKE_SCENARIO}" == empty-username ]]; then
          respond 200 '{"value":"","id":"https://kv-test.vault.azure.net/secrets/ib-username/1"}'
        else
          respond 200 '{"value":"CANARY_USER_zq7","id":"https://kv-test.vault.azure.net/secrets/ib-username/1"}'
        fi
        ;;
      */secrets/ib-password\?*)
        if [[ "${FAKE_SCENARIO}" == missing-password ]]; then
          respond 404 '{"error":{"code":"SecretNotFound"}}'
        else
          # shellcheck disable=SC2016  # the dollar sign is part of the canary password
          respond 200 '{"value":"hunter2\"hunter2\\tail $x","id":"https://kv-test.vault.azure.net/secrets/ib-password/1"}'
        fi
        ;;
      *)
        respond 404 '{"error":{"code":"SecretNotFound"}}'
        ;;
    esac
    ;;
  *)
    echo "fake curl: unexpected URL" >&2
    exit 7
    ;;
esac

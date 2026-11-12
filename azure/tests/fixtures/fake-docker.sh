#!/usr/bin/env bash
# Test double for docker, installed as /usr/local/bin/docker by apply-config.test.sh. It
# answers the four things apply-config.sh asks Docker and records every call in
# FAKE_DOCKER_LOG so the test can see whether (and how) the stack was touched.
#
#   docker ps ...                          prints a container id when FAKE_GATEWAY_EXISTS=1
#   docker compose ... config --hash S     prints "S <hash>"; the hash covers what reaches the
#                                          gateway service: its image line of the VM overlay,
#                                          the gateway's variables of the env file and the
#                                          reference compose file of the pack next to them
#   docker compose ... exec ... phase      prints FAKE_PHASE (default logged-in)
#   docker compose ... up / down           succeeds
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG:?}"

case "${1:-}" in
  ps)
    if [[ "${FAKE_GATEWAY_EXISTS:-0}" == 1 ]]; then echo 0123456789ab; fi
    ;;
  compose)
    shift
    env_file=""
    overlay=""
    subcommand=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --env-file)
          env_file="$2"
          shift 2
          ;;
        --file)
          overlay="$2"
          shift 2
          ;;
        --project-name | --profile)
          shift 2
          ;;
        *)
          subcommand="$1"
          shift
          break
          ;;
      esac
    done
    case "${subcommand}" in
      config)
        {
          grep -A 1 '^  ib-gateway:' "${overlay}"
          grep -E '^(TRADING_MODE|READ_ONLY_API|TIME_ZONE|AUTO_RESTART_TIME|IBGW_INSTANCE)=' "${env_file}"
          cat "$(dirname "${overlay}")/pack/compose/docker-compose.example.yml"
        } | sha256sum | awk '{ print "ib-gateway " $1 }'
        ;;
      exec)
        printf '%s\n' "${FAKE_PHASE:-logged-in}"
        ;;
      *) ;;
    esac
    ;;
  *) ;;
esac

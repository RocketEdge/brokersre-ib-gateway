#!/usr/bin/env bash
# ibgw-compose.sh <docker compose arguments...>   (installed to /usr/local/sbin by install.sh)
#
# Runs docker compose for the gateway stack of this VM: the reference compose and the Azure
# override from the pinned checkout of the repository, plus the VM overlay that pins the
# images by digest and points the secrets at tmpfs. Profile azure = Vector with the VM's
# managed identity. Also the operator's entry point: ibgw-compose.sh ps,
# ibgw-compose.sh logs -f vector. IBGW_ROOT (default /opt/ibgateway) selects another
# configuration root; apply-config.sh uses it to look at a staged configuration.
# Exit code: that of docker compose.
set -euo pipefail
root="${IBGW_ROOT:-/opt/ibgateway}"
exec docker compose --project-name ibgw --env-file "${root}/.env" \
  --file "${root}/pack/compose/docker-compose.example.yml" \
  --file "${root}/pack/compose/docker-compose.azure.yml" \
  --file "${root}/docker-compose.vm.yml" \
  --profile azure "$@"

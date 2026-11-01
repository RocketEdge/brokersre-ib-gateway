#!/usr/bin/env bash
# Launch IBC (which launches IB Gateway) with its output captured to the shared log volume and
# classified into structured events. Sets IBC_PID (the ibcstart.sh process).
#
# ibcstart.sh contract (IBC 3.24): ibcstart <twsVersion> -g --tws-path --tws-settings-path
# --ibc-path --ibc-ini --on2fatimeout. Credentials come from the rendered config.ini, not the
# command line, so `ps` never shows them.
start_ibc() {
  mkdir -p "${LOG_DIR}/ibc"
  set_phase login
  log_event ibc info ibc_starting "IBC ${IBC_VERSION} starting IB Gateway ${IB_GATEWAY_VERSION} (${IB_GATEWAY_CHANNEL}, ${TRADING_MODE}); command server port ${IBC_COMMAND_SERVER_PORT}"
  "${IBC_PATH}/scripts/ibcstart.sh" "${IB_GATEWAY_VERSION}" -g \
    "--tws-path=${TWS_PATH}" \
    "--tws-settings-path=${TWS_SETTINGS_PATH}" \
    "--ibc-path=${IBC_PATH}" \
    "--ibc-ini=${RUN_DIR}/config.ini" \
    "--on2fatimeout=${TWOFA_TIMEOUT_ACTION}" \
    > >(tee -a "${LOG_DIR}/ibc/ibc.log" | "${BROKERSRE_LIB:-/usr/local/lib/brokersre}/classify-ibc-log.sh") 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  IBC_PID=$!
}

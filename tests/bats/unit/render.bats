#!/usr/bin/env bats
# Unit tests for render-config.sh: secrets via _FILE, rendered config permissions, env hygiene.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export RUN_DIR="$(mktemp -d)"
  export TWS_SETTINGS_PATH="$(mktemp -d)"
  export LOG_DIR="$(mktemp -d)"
  export IBC_TEMPLATE="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc.config.ini.tmpl"
  export JTS_TEMPLATE="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/jts.ini.tmpl"
  export TRADING_MODE=paper READ_ONLY_API=yes TWOFA_TIMEOUT_ACTION=restart RELOGIN_AFTER_TWOFA_TIMEOUT=yes \
         TWOFA_EXIT_INTERVAL=60 EXISTING_SESSION_DETECTED_ACTION=primary TWS_ACCEPT_INCOMING=reject \
         ALLOW_BLIND_TRADING=no BYPASS_WARNING=yes IBC_COMMAND_SERVER_PORT=7462 IBC_SUPPRESS_INFO_MESSAGES=no \
         TIME_ZONE=America/New_York CUSTOM_CONFIG=no
  SECRETS="$(mktemp -d)"
  printf 'dummyuser' > "${SECRETS}/u"
  printf 'hunter2hunter2$pecial' > "${SECRETS}/p"
}

teardown() {
  rm -rf "${RUN_DIR}" "${TWS_SETTINGS_PATH}" "${LOG_DIR}" "${SECRETS}"
}

render() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/render-config.sh'; render_config; $1"
}

@test "credentials from _FILE land in config.ini with mode 0600 and are not expanded" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "${RUN_DIR}/config.ini")" == "600" ]
  grep -q '^IbLoginId=dummyuser$' "${RUN_DIR}/config.ini"
  grep -q '^IbPassword=hunter2hunter2$pecial$' "${RUN_DIR}/config.ini"
  grep -q '^CommandServerPort=7462$' "${RUN_DIR}/config.ini"
  grep -q '^BindAddress=127.0.0.1$' "${RUN_DIR}/config.ini"
  grep -q '^ReadOnlyApi=yes$' "${RUN_DIR}/config.ini"
  grep -q '^TradingMode=paper$' "${RUN_DIR}/config.ini"
}

@test "secrets are unset from the environment after rendering" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'echo "U=${TWS_USERID:-unset} P=${TWS_PASSWORD:-unset} F=${TWS_PASSWORD_FILE:-unset}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"U=unset P=unset F=unset"* ]]
}

@test "unset optional variables render as empty values, never as literal placeholders" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  unset TWOFA_DEVICE AUTO_RESTART_TIME
  render 'true' >/dev/null
  grep -q '^SecondFactorDevice=$' "${RUN_DIR}/config.ini"
  grep -q '^AutoRestartTime=$' "${RUN_DIR}/config.ini"
  ! grep -q '\${' "${RUN_DIR}/config.ini"
}

@test "jts.ini is written with the time zone only when absent" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  render 'true' >/dev/null
  grep -q '^TimeZone=America/New_York$' "${TWS_SETTINGS_PATH}/jts.ini"
  echo "TimeZone=Europe/Zurich" > "${TWS_SETTINGS_PATH}/jts.ini"
  render 'true' >/dev/null
  grep -q '^TimeZone=Europe/Zurich$' "${TWS_SETTINGS_PATH}/jts.ini"
}

@test "setting both TWS_PASSWORD and TWS_PASSWORD_FILE is refused" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p" TWS_PASSWORD=x
  run render 'true'
  [ "$status" -ne 0 ]
  [[ "$output" == *"config_conflict"* ]]
}

@test "missing credentials fail fast with a structured error" {
  run render 'true'
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_missing" and .level == "error"' >/dev/null
}

@test "CUSTOM_CONFIG=yes uses the operator file and renders nothing" {
  export CUSTOM_CONFIG=yes
  printf 'IbLoginId=custom\n' > "${RUN_DIR}/config.ini"
  run render 'true'
  [ "$status" -eq 0 ]
  grep -q '^IbLoginId=custom$' "${RUN_DIR}/config.ini"
}

@test "TRADING_MODE other than live or paper is rejected (one session per container)" {
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=both set_ports"
  [ "$status" -ne 0 ]
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=live set_ports; echo \$API_PORT \$SOCAT_PORT"
  [ "$output" == "4001 4003" ]
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=paper set_ports; echo \$API_PORT \$SOCAT_PORT"
  [ "$output" == "4002 4004" ]
}

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
  ! grep -q '\${' "${RUN_DIR}/config.ini" || false
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

# IBC reads config.ini with java.util.Properties.load(InputStream): ISO-8859-1 bytes, backslash
# as the escape character, leading whitespace of a value dropped. A credential must therefore be
# written in .properties escaping or IBC types a different password than the user set.
@test "a backslash in the password is escaped for IBC's .properties parser" {
  printf 'dummyuser' > "${SECRETS}/u"
  printf 'hunter2\\x\\\\y' > "${SECRETS}/p"
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [ "$status" -eq 0 ]
  grep -q -F -x 'IbPassword=hunter2\\x\\\\y' "${RUN_DIR}/config.ini"
}

@test "leading whitespace of a credential survives the .properties parser" {
  printf 'dummyuser' > "${SECRETS}/u"
  printf ' hunter2 lead' > "${SECRETS}/p"
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [ "$status" -eq 0 ]
  grep -q -F -x 'IbPassword=\ hunter2 lead' "${RUN_DIR}/config.ini"
}

@test "non-ASCII credential characters are written as \\uXXXX escapes (incl. surrogate pairs)" {
  printf 'dummyuser' > "${SECRETS}/u"
  # a-umlaut (U+00E4), euro sign (U+20AC), an emoji (U+1F600 = surrogates D83D DE00)
  printf 'hunter2\xc3\xa4\xe2\x82\xac\xf0\x9f\x98\x80' > "${SECRETS}/p"
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [ "$status" -eq 0 ]
  # The expected escapes are assembled from parts so that no editor or tool turns a literal
  # backslash-u sequence back into the character it stands for.
  bs='\'
  grep -q -F -x "IbPassword=hunter2${bs}u00e4${bs}u20ac${bs}ud83d${bs}ude00" "${RUN_DIR}/config.ini"
  # The rendered file is pure ASCII, so the parser's ISO-8859-1 decoding cannot corrupt it.
  ! LC_ALL=C grep -q '[^ -~]' "${RUN_DIR}/config.ini" || false
}

@test "the username gets the same escaping as the password" {
  printf 'dummy\\user' > "${SECRETS}/u"
  printf 'hunter2hunter2' > "${SECRETS}/p"
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [ "$status" -eq 0 ]
  grep -q -F -x 'IbLoginId=dummy\\user' "${RUN_DIR}/config.ini"
}

@test "TRADING_MODE other than live or paper is rejected (one session per container)" {
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=both set_ports"
  [ "$status" -ne 0 ]
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=live set_ports; echo \$API_PORT \$SOCAT_PORT"
  [ "$output" == "4001 4003" ]
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; TRADING_MODE=paper set_ports; echo \$API_PORT \$SOCAT_PORT"
  [ "$output" == "4002 4004" ]
}

# config_hash: a fingerprint of the non-secret configuration, carried by the config_rendered
# event, so a reader can tell that the configuration changed between two starts. It must not
# depend on the credentials: a hash that included the password would let anyone who sees the
# events test password guesses offline.
config_hash() {
  render 'true' | jq -r 'select(.event == "config_rendered") | .data.config_hash'
}

@test "config_rendered carries a 16-hex config_hash that is stable for the same settings" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  a="$(config_hash)"
  b="$(config_hash)"
  [[ "${a}" =~ ^[0-9a-f]{16}$ ]]
  [ "${a}" == "${b}" ]
}

@test "config_hash changes when a setting changes" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  a="$(config_hash)"
  export READ_ONLY_API=no
  b="$(config_hash)"
  [ "${a}" != "${b}" ]
}

@test "config_hash does not depend on the username or the password" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  a="$(config_hash)"
  printf 'anotheruser' > "${SECRETS}/u"
  printf 'hunter2-a-different-password' > "${SECRETS}/p"
  b="$(config_hash)"
  [ "${a}" == "${b}" ]
}

@test "no event of the rendering step contains the username or the password" {
  export TWS_USERID_FILE="${SECRETS}/u" TWS_PASSWORD_FILE="${SECRETS}/p"
  run render 'true'
  [[ "$output" != *"dummyuser"* ]]
  [[ "$output" != *"hunter2hunter2"* ]]
}

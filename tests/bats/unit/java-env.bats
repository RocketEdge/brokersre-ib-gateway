#!/usr/bin/env bats
# Unit tests for java-env.sh: the Gateway JVM must get a writable user.home, or a real login
# under a read-only root filesystem blocks behind a hidden "directory not accessible" dialog
# (observed with IB Gateway 10.50.1g on 2026-11-12; see docs/limitations.md L02).

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export TWS_SETTINGS_PATH="$(mktemp -d)"
  export LOG_DIR="$(mktemp -d)"
  unset JAVA_USER_HOME _JAVA_OPTIONS XDG_CACHE_HOME
}

teardown() {
  chmod -R u+w "${TWS_SETTINGS_PATH}" 2>/dev/null || true
  rm -rf "${TWS_SETTINGS_PATH}" "${LOG_DIR}"
}

# java_env_then <command>: source the library, run java_env, then the command in the same shell.
java_env_then() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/java-env.sh'; java_env; $1"
}

@test "user.home defaults to a private directory on the settings volume" {
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$status" -eq 0 ]
  [ "$output" == "-Duser.home=${TWS_SETTINGS_PATH}/.java-home" ]
  [ -d "${TWS_SETTINGS_PATH}/.java-home" ]
  [ "$(stat -c %a "${TWS_SETTINGS_PATH}/.java-home")" == "700" ]
}

@test "JAVA_USER_HOME overrides the location" {
  export JAVA_USER_HOME="${LOG_DIR}/elsewhere"
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$status" -eq 0 ]
  [ "$output" == "-Duser.home=${LOG_DIR}/elsewhere" ]
  [ -d "${LOG_DIR}/elsewhere" ]
}

@test "operator-supplied _JAVA_OPTIONS are kept and come last, so they win" {
  export _JAVA_OPTIONS="-Dfoo=bar -Xss1m"
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$status" -eq 0 ]
  [ "$output" == "-Duser.home=${TWS_SETTINGS_PATH}/.java-home -Dfoo=bar -Xss1m" ]
}

@test "the native cache directory follows the Java home" {
  run java_env_then 'printf "%s" "${XDG_CACHE_HOME}"'
  [ "$status" -eq 0 ]
  [ "$output" == "${TWS_SETTINGS_PATH}/.java-home/.cache" ]
}

@test "_JAVA_OPTIONS is exported to child processes" {
  run java_env_then 'bash -c "printf %s \"\${_JAVA_OPTIONS}\""'
  [ "$status" -eq 0 ]
  [[ "$output" == "-Duser.home="* ]]
}

@test "a Java home that cannot be created stops the start with dirs_not_writable" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  chmod 0500 "${TWS_SETTINGS_PATH}"
  run java_env_then 'true'
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "dirs_not_writable" and .level == "error"' >/dev/null
}

@test "a Java home containing whitespace is refused (the JVM splits _JAVA_OPTIONS on spaces)" {
  export JAVA_USER_HOME="${LOG_DIR}/with space"
  run java_env_then 'true'
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_invalid" and .level == "error"' >/dev/null
}

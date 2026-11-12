#!/usr/bin/env bats
# Unit tests for java-env.sh: the Gateway JVM must get a writable user.home, or a real login
# under a read-only root filesystem blocks behind a hidden "directory not accessible" dialog
# (observed with IB Gateway 10.50.1g on 2026-11-12; see docs/limitations.md L02).

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export TWS_SETTINGS_PATH="$(mktemp -d)"
  export LOG_DIR="$(mktemp -d)"
  unset JAVA_USER_HOME _JAVA_OPTIONS XDG_CACHE_HOME JAVA_HEAP_MB CGROUP_ROOT
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
  [ "$output" == "-Duser.home=${TWS_SETTINGS_PATH}/.java-home -XX:+ExitOnOutOfMemoryError" ]
  [ -d "${TWS_SETTINGS_PATH}/.java-home" ]
  [ "$(stat -c %a "${TWS_SETTINGS_PATH}/.java-home")" == "700" ]
}

@test "JAVA_USER_HOME overrides the location" {
  export JAVA_USER_HOME="${LOG_DIR}/elsewhere"
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$status" -eq 0 ]
  [ "$output" == "-Duser.home=${LOG_DIR}/elsewhere -XX:+ExitOnOutOfMemoryError" ]
  [ -d "${LOG_DIR}/elsewhere" ]
}

@test "operator-supplied _JAVA_OPTIONS are kept and come last, so they win" {
  export _JAVA_OPTIONS="-Dfoo=bar -Xss1m"
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$status" -eq 0 ]
  [ "$output" == "-Duser.home=${TWS_SETTINGS_PATH}/.java-home -XX:+ExitOnOutOfMemoryError -Dfoo=bar -Xss1m" ]
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

# heap_option: print only the -Xmx part of _JAVA_OPTIONS (empty when there is none).
heap_option() {
  java_env_then 'for o in ${_JAVA_OPTIONS}; do case "${o}" in -Xmx*) printf "%s" "${o}" ;; esac; done'
}

@test "without JAVA_HEAP_MB the image's built-in heap is left alone" {
  run heap_option
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "JAVA_HEAP_MB sets the heap at run time" {
  export JAVA_HEAP_MB=1536
  run heap_option
  [ "$status" -eq 0 ]
  [ "$output" == "-Xmx1536m" ]
}

@test "the heap option comes before operator options, so an operator -Xmx still wins" {
  export JAVA_HEAP_MB=1024 _JAVA_OPTIONS="-Xmx3g"
  run java_env_then 'printf "%s" "${_JAVA_OPTIONS}"'
  [ "$output" == "-Duser.home=${TWS_SETTINGS_PATH}/.java-home -XX:+ExitOnOutOfMemoryError -Xmx1024m -Xmx3g" ]
}

@test "JAVA_HEAP_MB=auto takes half of the container memory limit" {
  export JAVA_HEAP_MB=auto CGROUP_ROOT="${LOG_DIR}/cg"
  mkdir -p "${CGROUP_ROOT}"
  echo 4294967296 >"${CGROUP_ROOT}/memory.max"
  run heap_option
  [ "$output" == "-Xmx2048m" ]
}

@test "JAVA_HEAP_MB=auto never goes below 768 MB or above 4096 MB" {
  export JAVA_HEAP_MB=auto CGROUP_ROOT="${LOG_DIR}/cg"
  mkdir -p "${CGROUP_ROOT}"
  echo 1073741824 >"${CGROUP_ROOT}/memory.max"
  run heap_option
  [ "$output" == "-Xmx768m" ]
  echo 34359738368 >"${CGROUP_ROOT}/memory.max"
  run heap_option
  [ "$output" == "-Xmx4096m" ]
}

@test "JAVA_HEAP_MB=auto without a memory limit leaves the built-in heap alone" {
  export JAVA_HEAP_MB=auto CGROUP_ROOT="${LOG_DIR}/cg"
  mkdir -p "${CGROUP_ROOT}"
  echo max >"${CGROUP_ROOT}/memory.max"
  run heap_option
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a JAVA_HEAP_MB that is not a number or auto is refused" {
  export JAVA_HEAP_MB=2g
  run java_env_then 'true'
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_invalid" and (.msg | contains("JAVA_HEAP_MB"))' >/dev/null
}

@test "a heap below 256 MB is refused: the Gateway cannot start with it" {
  export JAVA_HEAP_MB=64
  run java_env_then 'true'
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_invalid"' >/dev/null
}

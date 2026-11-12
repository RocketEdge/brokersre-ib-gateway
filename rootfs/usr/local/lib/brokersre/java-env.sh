#!/usr/bin/env bash
# JVM environment for IB Gateway. Sourced by the entrypoint, never executed.
#
# Why this exists: IB Gateway writes a hardware-id file (`.hwid`) and Java caches (`.java/`)
# into the JVM's `user.home` during login. Under a read-only root filesystem the image's home
# directory is not writable, the Gateway opens a modal "directory not accessible" warning that
# IBC does not handle, and the login blocks forever without any event (observed with IB Gateway
# 10.50.1g, 2026-11-12). The JVM derives `user.home` from the passwd entry, not from $HOME, so
# the only way to move it is a JVM option.
#
# Why `_JAVA_OPTIONS`: IBC's ibcstart.sh drops every `-D` line of ibgateway.vmoptions and
# clears JAVA_TOOL_OPTIONS before it starts Java, so options written to either never reach the
# JVM. `_JAVA_OPTIONS` is read by the JVM itself, is not touched by ibcstart.sh, and is applied
# after the command line, so a value set here wins over the launcher's.

# java_env: export _JAVA_OPTIONS (and XDG_CACHE_HOME) so the Gateway JVM has a writable home.
#
# Inputs:  JAVA_USER_HOME (optional; default ${TWS_SETTINGS_PATH}/.java-home, on the settings
#          volume so the hardware id survives a container restart or re-creation);
#          _JAVA_OPTIONS (optional operator options; kept and placed last so they win).
# Effects: creates the directory with mode 0700; exports _JAVA_OPTIONS and XDG_CACHE_HOME.
# Fails:   config_invalid when the path contains whitespace (the JVM splits _JAVA_OPTIONS on
#          spaces and there is no quoting); dirs_not_writable when it cannot be created or
#          written. Both exit 1 before IBC starts, so a doomed login is never attempted.
java_env() {
  local home="${JAVA_USER_HOME:-${TWS_SETTINGS_PATH}/.java-home}"
  if [[ "${home}" =~ [[:space:]] ]]; then
    log_event entrypoint error config_invalid "JAVA_USER_HOME must not contain whitespace (got '${home}')"
    exit 1
  fi
  if ! mkdir -p "${home}" 2>/dev/null || [ ! -w "${home}" ]; then
    log_event entrypoint error dirs_not_writable "${home} (Java user.home) is not writable by uid $(id -u); IB Gateway cannot log in without it"
    exit 1
  fi
  chmod 0700 "${home}"
  # Native libraries (Mesa's shader cache) use XDG_CACHE_HOME or $HOME/.cache, not user.home.
  export XDG_CACHE_HOME="${home}/.cache"
  export _JAVA_OPTIONS="-Duser.home=${home}${_JAVA_OPTIONS:+ ${_JAVA_OPTIONS}}"
}

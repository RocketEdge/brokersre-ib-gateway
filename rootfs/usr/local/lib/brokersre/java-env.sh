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
# after the command line, so a value set here wins over the launcher's (which is how the heap
# can be set at run time although ibgateway.vmoptions sits in the read-only image).

# java_heap_mb: set JAVA_HEAP_RESOLVED_MB to the heap size in MB that JAVA_HEAP_MB asks for, or to
# the empty string when the image's built-in heap (768 MB) is to be left alone. It sets a global
# instead of printing because it must be able to end the entrypoint with an event on stdout.
#
# JAVA_HEAP_MB is unset/empty (nothing), a whole number of MB (at least 256), or `auto`:
# half of the container's memory limit (${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max), never below
# 768 or above 4096; no limit means nothing. Half, because the JVM needs memory beyond the heap
# (metaspace, threads, the embedded browser) and Xvfb shares the limit; a heap close to the
# limit gets the container killed instead of a tidy OutOfMemoryError.
# Fails with config_invalid (exit 1) for any other value.
java_heap_mb() {
  local want="${JAVA_HEAP_MB:-}" limit="" mb
  JAVA_HEAP_RESOLVED_MB=""
  case "${want}" in
    "")
      return 0
      ;;
    auto)
      if [ -r "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max" ]; then
        read -r limit <"${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max" || true
      fi
      [[ "${limit}" =~ ^[0-9]+$ ]] || return 0
      mb=$((limit / 2 / 1048576))
      if [ "${mb}" -lt 768 ]; then mb=768; fi
      if [ "${mb}" -gt 4096 ]; then mb=4096; fi
      JAVA_HEAP_RESOLVED_MB="${mb}"
      ;;
    *)
      if ! [[ "${want}" =~ ^[1-9][0-9]*$ ]] || [ "${want}" -lt 256 ]; then
        log_event entrypoint error config_invalid "JAVA_HEAP_MB must be a whole number of megabytes (256 or more) or 'auto' (got '${want}')"
        exit 1
      fi
      JAVA_HEAP_RESOLVED_MB="${want}"
      ;;
  esac
}

# java_env: export _JAVA_OPTIONS (and XDG_CACHE_HOME) for the Gateway JVM.
#
# Inputs:  JAVA_USER_HOME (optional; default ${TWS_SETTINGS_PATH}/.java-home, on the settings
#          volume so the hardware id survives a container restart or re-creation);
#          JAVA_HEAP_MB (optional, see java_heap_mb);
#          _JAVA_OPTIONS (optional operator options; kept and placed last so they win).
# Effects: creates the directory with mode 0700; exports XDG_CACHE_HOME and
#          _JAVA_OPTIONS="-Duser.home=<home> -XX:+ExitOnOutOfMemoryError [-Xmx<n>m] [operator]".
#          ExitOnOutOfMemoryError: a JVM that survived an OutOfMemoryError keeps its port open
#          and answers nothing; exiting makes the failure visible (IBC and the container end).
# Fails:   config_invalid when the path contains whitespace (the JVM splits _JAVA_OPTIONS on
#          spaces and there is no quoting) or JAVA_HEAP_MB is invalid; dirs_not_writable when
#          the home cannot be created or written. All exit 1 before IBC starts, so a doomed
#          login is never attempted.
java_env() {
  local home="${JAVA_USER_HOME:-${TWS_SETTINGS_PATH}/.java-home}" heap options
  if [[ "${home}" =~ [[:space:]] ]]; then
    log_event entrypoint error config_invalid "JAVA_USER_HOME must not contain whitespace (got '${home}')"
    exit 1
  fi
  if ! mkdir -p "${home}" 2>/dev/null || [ ! -w "${home}" ]; then
    log_event entrypoint error dirs_not_writable "${home} (Java user.home) is not writable by uid $(id -u); IB Gateway cannot log in without it"
    exit 1
  fi
  chmod 0700 "${home}"
  java_heap_mb
  heap="${JAVA_HEAP_RESOLVED_MB}"
  options="-Duser.home=${home} -XX:+ExitOnOutOfMemoryError"
  if [ -n "${heap}" ]; then options="${options} -Xmx${heap}m"; fi
  # Native libraries (Mesa's shader cache) use XDG_CACHE_HOME or $HOME/.cache, not user.home.
  export XDG_CACHE_HOME="${home}/.cache"
  export _JAVA_OPTIONS="${options}${_JAVA_OPTIONS:+ ${_JAVA_OPTIONS}}"
}

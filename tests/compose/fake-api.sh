#!/usr/bin/env bash
# Stand-in for the Gateway's API port in tests/compose/run.sh: serves ONE connection on
# stdin/stdout (socat runs it per connection). It reads the client's 17 handshake bytes
# ("API\0", a 4-byte length, "v157..178") and answers like the TWS API does: a 4-byte
# big-endian length (26) followed by "<server version>\0<connection time>\0". Then it waits
# for the client to close. It knows nothing else of the protocol and never contacts IBKR.
dd bs=1 count=17 >/dev/null 2>&1
printf '\0\0\0\032178\00020261112 10:00:00 UTC\0'
cat >/dev/null

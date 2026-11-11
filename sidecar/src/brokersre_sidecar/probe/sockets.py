"""Count half-closed API sockets of the gateway from ``/proc/net/tcp`` and ``tcp6``.

The sidecar shares the gateway's network namespace, so ``/proc/net/tcp`` lists the
gateway's sockets. A socket in CLOSE_WAIT whose local port is the API port is a connection
the client has closed and the gateway has not: a few for a moment are normal, many for
minutes mean the gateway's API thread no longer serves its sockets.
"""

from __future__ import annotations

from pathlib import Path

_CLOSE_WAIT = "08"
# sl, local_address, rem_address, st are the first four columns of both files.
_MIN_COLUMNS = 4


def count_close_wait(port: int, proc_root: Path = Path("/proc")) -> int | None:
    """Count sockets in CLOSE_WAIT whose local port is ``port``.

    Args:
        port: The gateway's API port (4001 or 4002).
        proc_root: Mount point of procfs; a parameter so tests can supply a fixture tree.

    Returns:
        The count over IPv4 and IPv6, or None when neither file can be read (not Linux, or
        procfs is restricted): not measured, never 0.
    """
    total = 0
    measured = False
    for name in ("tcp", "tcp6"):
        try:
            text = (proc_root / "net" / name).read_text(encoding="ascii", errors="replace")
        except OSError:
            continue
        measured = True
        for row in text.splitlines()[1:]:
            columns = row.split()
            if len(columns) < _MIN_COLUMNS or columns[3] != _CLOSE_WAIT:
                continue
            try:
                local_port = int(columns[1].rsplit(":", 1)[1], 16)
            except IndexError, ValueError:
                continue
            if local_port == port:
                total += 1
    return total if measured else None

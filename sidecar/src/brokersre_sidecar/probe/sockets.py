"""Read the TCP socket table of the network namespace from ``/proc/net/tcp`` and ``tcp6``.

The sidecar shares the gateway's network namespace, so these files list the gateway's
sockets. Two facts are derived from them:

* sockets in CLOSE_WAIT whose local port is the API port are connections the client has
  closed and the gateway has not: a few for a moment are normal, many for minutes mean the
  gateway's API thread no longer serves its sockets;
* listening sockets other than the sidecar's own tell whether the gateway is still in this
  namespace at all (see ``NamespaceWatch``).
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

_CLOSE_WAIT = "08"
_LISTEN = "0A"
# sl, local_address, rem_address, st are the first four columns of both files.
_MIN_COLUMNS = 4


def _sockets(proc_root: Path) -> Iterator[tuple[int, str]] | None:
    """Return ``(local port, state)`` of every TCP socket, or None when unreadable.

    Returns None when neither ``net/tcp`` nor ``net/tcp6`` can be read (not Linux, or
    procfs is restricted): the caller must treat that as not measured, never as zero.
    """
    rows: list[tuple[int, str]] = []
    measured = False
    for name in ("tcp", "tcp6"):
        try:
            text = (proc_root / "net" / name).read_text(encoding="ascii", errors="replace")
        except OSError:
            continue
        measured = True
        for row in text.splitlines()[1:]:
            columns = row.split()
            if len(columns) < _MIN_COLUMNS:
                continue
            try:
                local_port = int(columns[1].rsplit(":", 1)[1], 16)
            except IndexError, ValueError:
                continue
            rows.append((local_port, columns[3]))
    return iter(rows) if measured else None


def count_close_wait(port: int, proc_root: Path = Path("/proc")) -> int | None:
    """Count sockets in CLOSE_WAIT whose local port is ``port``.

    Args:
        port: The gateway's API port (4001 or 4002).
        proc_root: Mount point of procfs; a parameter so tests can supply a fixture tree.

    Returns:
        The count over IPv4 and IPv6, or None when it cannot be measured.
    """
    sockets = _sockets(proc_root)
    if sockets is None:
        return None
    return sum(1 for local_port, state in sockets if local_port == port and state == _CLOSE_WAIT)


def count_foreign_listeners(own_port: int, proc_root: Path = Path("/proc")) -> int | None:
    """Count listening sockets that are not the sidecar's own HTTP port.

    Args:
        own_port: The sidecar's HTTP port (``SIDECAR_PORT``).
        proc_root: Mount point of procfs.

    Returns:
        The number of listening TCP sockets on other ports (the gateway's relay, command
        server and API), or None when it cannot be measured.
    """
    sockets = _sockets(proc_root)
    if sockets is None:
        return None
    return sum(1 for local_port, state in sockets if local_port != own_port and state == _LISTEN)

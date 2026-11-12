"""Persistence of the ladder state: one small JSON file, written atomically."""

from __future__ import annotations

import json
from pathlib import Path

from brokersre_sidecar.fsutil import atomic_write_text, is_dir_writable

# The state of 13 alert classes is a few hundred bytes; anything much larger is not ours.
_MAX_STATE_BYTES = 256 * 1024


class NotifierStore:
    """Reads and writes the notifier state file (``/var/lib/sidecar/notifier-state.json``).

    The file lets de-duplication and escalation survive a restart of the sidecar. Losing it
    costs at most one repeated notification per active alert, so every read problem is
    treated as "no saved state".
    """

    def __init__(self, path: Path) -> None:
        """Bind the store to ``path``; nothing is read or created yet."""
        self._path = path

    def writable(self) -> bool:
        """Report whether the state directory accepts a new file right now."""
        return is_dir_writable(self._path.parent)

    def load(self) -> object | None:
        """Return the saved state, or None when there is none or it cannot be used.

        Returns:
            The parsed JSON value. None for a missing, unreadable, oversized or malformed
            file.
        """
        try:
            with open(self._path, "rb") as handle:
                data = handle.read(_MAX_STATE_BYTES + 1)
        except OSError:
            return None
        if len(data) > _MAX_STATE_BYTES:
            return None
        try:
            parsed: object = json.loads(data)
        except ValueError:
            return None
        return parsed

    def save(self, state: object) -> None:
        """Write ``state`` atomically.

        Raises:
            OSError: The directory is missing or read-only, or the disk is full.
        """
        atomic_write_text(self._path, json.dumps(state, sort_keys=True, indent=2) + "\n")

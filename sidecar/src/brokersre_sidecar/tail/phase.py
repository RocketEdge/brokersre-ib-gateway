"""Read the gateway's phase file (``state/phase``): one token, written atomically."""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from brokersre_sidecar.vocab import KNOWN_PHASES, UNKNOWN_PHASE

# The longest valid token is 16 characters; anything much longer is not a phase file.
_MAX_PHASE_BYTES = 64


@dataclass(frozen=True, slots=True)
class PhaseReading:
    """One observation of the phase file.

    Attributes:
        token: A token from ``vocab.Phase`` or ``"unknown"``. The raw content of an unknown
            file is deliberately not kept: it is not part of any vocabulary and could be
            anything.
        known: False when ``token`` is ``"unknown"``.
        modified: The file's modification time (UTC): the last time the gateway wrote the
            phase, which is at or after the moment the phase began.
    """

    token: str
    known: bool
    modified: datetime


def read_phase(path: Path) -> PhaseReading | None:
    """Read the phase file once.

    Args:
        path: ``<log dir>/state/phase``.

    Returns:
        None when the file does not exist or cannot be read (the phase is then not
        measured); otherwise a reading whose token is ``"unknown"`` unless the content is
        exactly one known token, optionally padded with white space or a CRLF.
    """
    try:
        with open(path, "rb") as handle:
            modified = os.fstat(handle.fileno()).st_mtime
            data = handle.read(_MAX_PHASE_BYTES + 1)
    except OSError:
        return None
    when = datetime.fromtimestamp(modified, UTC)
    token = data.decode("ascii", errors="replace").strip() if len(data) <= _MAX_PHASE_BYTES else ""
    if token in KNOWN_PHASES:
        return PhaseReading(token=token, known=True, modified=when)
    return PhaseReading(token=UNKNOWN_PHASE, known=False, modified=when)

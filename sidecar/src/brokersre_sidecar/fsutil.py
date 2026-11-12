"""File-system helpers (leaf module): atomic writes and a writability probe."""

from __future__ import annotations

import contextlib
import os
import sys
import time
from pathlib import Path

# Windows refuses a rename while another process (antivirus, indexer) has the target open
# for a moment; a few short retries get past that. On POSIX a rename never fails for that
# reason, so a PermissionError there is final. (The image is Linux; Windows is a
# development host.)
_REPLACE_ATTEMPTS = 20 if sys.platform == "win32" else 1
_REPLACE_RETRY_S = 0.01


def _replace(source: Path, target: Path) -> None:
    """Rename ``source`` over ``target``; see ``_REPLACE_ATTEMPTS`` for the one retry case.

    Raises:
        OSError: The rename failed (after the retries, where they apply).
    """
    for attempt in range(1, _REPLACE_ATTEMPTS + 1):
        try:
            os.replace(source, target)
        except PermissionError:
            if attempt == _REPLACE_ATTEMPTS:
                raise
            time.sleep(_REPLACE_RETRY_S)
        else:
            return


def atomic_write_text(path: Path, text: str) -> None:
    """Write ``text`` to ``path`` so that a reader sees the old or the new content, never a mix.

    The text goes to a temporary file in the same directory, is flushed and fsynced, then
    renamed over the target; on POSIX the directory is fsynced too so the rename survives a
    power loss. The temporary file is removed when anything fails.

    Args:
        path: Target file; its directory must exist and be writable.
        text: Content, written as UTF-8 with LF line endings exactly as given.

    Raises:
        OSError: The directory is missing or not writable, or the disk is full. The previous
            content of ``path`` is intact in that case.
    """
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        _replace(temporary, path)
    except OSError:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise
    if sys.platform != "win32":
        # Windows cannot open a directory for fsync; NTFS journals the rename itself.
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def is_dir_writable(path: Path) -> bool:
    """Report whether a file can be created in ``path`` right now.

    Creates and removes a probe file rather than trusting mode bits: a read-only bind mount
    or a read-only root file system reports writable modes and still refuses the write.

    Args:
        path: Directory to test.

    Returns:
        True when a file could be created and removed; False for a missing directory, a
        read-only mount or insufficient permissions.
    """
    probe = path / f".write-probe-{os.getpid()}"
    try:
        with open(probe, "w", encoding="utf-8") as handle:
            handle.write("")
        probe.unlink()
    except OSError:
        return False
    return True

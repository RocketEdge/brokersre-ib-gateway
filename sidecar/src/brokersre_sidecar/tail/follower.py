"""Follow an append-only, size-rotated text file without holding it open.

The gateway appends JSON lines to ``events/events.jsonl`` and ``metrics/metrics.jsonl`` and
rotates each by renaming it to ``<name>.1`` and starting a new file. ``LineFollower.poll()``
returns the complete lines added since the previous poll and survives everything the log
contract allows: the file missing at start, a partial last line, rotation, truncation in
place, bytes that are not UTF-8 and lines of absurd length.

Why no open handle is kept: the volume is mounted read-only from another container, the
poll interval is a second, and a re-opened file makes rotation handling explicit (identity
is compared on every poll) instead of depending on what an old descriptor still points at.

File identity is ``(st_dev, st_ino)`` plus the first bytes of the file: an inode number
alone is reused by some file systems as soon as the rotated predecessor is deleted.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

_HEAD_BYTES = 64
_NEWLINE = b"\n"


@dataclass(slots=True)
class FollowerStats:
    """Counters describing what a follower had to tolerate.

    Attributes:
        rotations: Times the file was replaced by a new one (rename rotation).
        truncations: Times the file was truncated or rewritten in place.
        lost_rotations: Rotations whose predecessor could not be found any more (rotated
            twice between two polls); its unread lines are lost.
        dropped_lines: Lines discarded because they exceeded ``max_line_bytes``.
    """

    rotations: int = 0
    truncations: int = 0
    lost_rotations: int = 0
    dropped_lines: int = 0


class LineFollower:
    """Incremental reader of one append-only file.

    Contract: every complete line (terminated by LF) written to the file is returned exactly
    once and in order, as long as the file is rotated at most once between two polls and a
    truncation happens after its content was polled. A line is returned without its line
    ending; empty lines are skipped; undecodable bytes become U+FFFD. Memory is bounded by
    ``max_read_bytes`` per poll and ``max_line_bytes`` of buffered partial line.

    Not thread-safe; ``poll`` does blocking file I/O on small local files and is meant to be
    called from one task (through ``asyncio.to_thread`` when the loop must stay free).
    """

    def __init__(
        self,
        path: Path,
        *,
        max_line_bytes: int = 64 * 1024,
        initial_tail_bytes: int = 1024 * 1024,
        max_read_bytes: int = 4 * 1024 * 1024,
        replay_rotated: bool = False,
    ) -> None:
        """Create a follower; nothing is read until the first ``poll``.

        Args:
            path: The live file (its rotated predecessor is ``<path>.1``).
            max_line_bytes: Longer lines are dropped and counted.
            initial_tail_bytes: When the file already exists at first sight, at most this
                many trailing bytes are read (history is useful, unbounded history is not).
            max_read_bytes: Upper bound of bytes read from one file in one poll.
            replay_rotated: Also read the tail of ``<path>.1`` once at first sight, so a
                rotation just before start does not hide the recent past.
        """
        self._path = path
        self._rotated_path = path.with_name(path.name + ".1")
        self._max_line_bytes = max_line_bytes
        self._initial_tail_bytes = initial_tail_bytes
        self._max_read_bytes = max_read_bytes
        self._replay_rotated = replay_rotated
        self._identity: tuple[int, int] | None = None
        self._head = b""
        self._offset = 0
        self._partial = b""
        self._skipping = False
        self.stats = FollowerStats()

    @property
    def seen(self) -> bool:
        """True once the file has existed at any poll."""
        return self._identity is not None

    def poll(self) -> list[str]:
        """Return the complete lines appended since the previous poll.

        Returns:
            Decoded lines in file order; an empty list when nothing new is complete, the
            file does not exist (yet) or it cannot be read right now.

        Side effects:
            Reads the file (and ``<path>.1`` after a rotation); updates ``stats``.
        """
        try:
            status = os.stat(self._path)
        except OSError:
            # Missing (not created yet, or between the two steps of a rotation) or
            # unreadable: keep the position, a later poll resolves it.
            return []
        identity = (status.st_dev, status.st_ino)
        lines: list[str] = []
        if self._identity is None:
            if self._replay_rotated:
                lines += self._read_whole(self._rotated_path)
            self._enter(identity, status.st_size)
        elif identity != self._identity:
            lines += self._drain_predecessor()
            self.stats.rotations += 1
            self._restart(identity)
        elif status.st_size < self._offset or not self._head_matches(self._path):
            self.stats.truncations += 1
            self._restart(identity)
        lines += self._read_live()
        return lines

    def _enter(self, identity: tuple[int, int], size: int) -> None:
        """Adopt the file at first sight, entering near its end when it is large."""
        self._identity = identity
        self._head = b""
        self._partial = b""
        if size > self._initial_tail_bytes:
            # One byte early with skipping on: if that byte is a newline the first line is
            # kept whole, otherwise the cut line is discarded up to its newline.
            self._offset = size - self._initial_tail_bytes - 1
            self._skipping = True
        else:
            self._offset = 0
            self._skipping = False

    def _restart(self, identity: tuple[int, int]) -> None:
        """Start reading a replaced or truncated file from its beginning."""
        self._identity = identity
        self._head = b""
        self._offset = 0
        self._partial = b""
        self._skipping = False

    def _head_matches(self, path: Path) -> bool:
        """Report whether ``path`` still begins with the bytes remembered for the live file."""
        if not self._head:
            return True
        try:
            with open(path, "rb") as handle:
                return handle.read(len(self._head)) == self._head
        except OSError:
            return True

    def _read_live(self) -> list[str]:
        """Read up to ``max_read_bytes`` from the live file at the current offset."""
        try:
            with open(self._path, "rb") as handle:
                status = os.fstat(handle.fileno())
                if (status.st_dev, status.st_ino) != self._identity:
                    # Rotated between stat and open: the next poll handles it.
                    return []
                if len(self._head) < _HEAD_BYTES:
                    self._head = handle.read(_HEAD_BYTES)
                handle.seek(self._offset)
                chunk = handle.read(self._max_read_bytes)
        except OSError:
            return []
        self._offset += len(chunk)
        return self._split(chunk)

    def _drain_predecessor(self) -> list[str]:
        """Read the unread remainder of the file that was just rotated to ``<path>.1``.

        Returns:
            Its remaining lines, including a final line without a line ending (the writer
            is done with that file). Empty, with ``lost_rotations`` incremented, when the
            predecessor is not the file this follower was reading.
        """
        lines: list[str] = []
        try:
            with open(self._rotated_path, "rb") as handle:
                status = os.fstat(handle.fileno())
                same = (status.st_dev, status.st_ino) == self._identity
                if same and self._head:
                    same = handle.read(len(self._head)) == self._head
                if not same:
                    self.stats.lost_rotations += 1
                    return []
                handle.seek(self._offset)
                while chunk := handle.read(self._max_read_bytes):
                    lines += self._split(chunk)
        except OSError:
            self.stats.lost_rotations += 1
            return []
        lines += self._flush_partial()
        return lines

    def _read_whole(self, path: Path) -> list[str]:
        """Read the tail of a finished file (the rotated predecessor at first sight)."""
        lines: list[str] = []
        try:
            with open(path, "rb") as handle:
                size = os.fstat(handle.fileno()).st_size
                if size > self._initial_tail_bytes:
                    handle.seek(size - self._initial_tail_bytes - 1)
                    self._skipping = True
                while chunk := handle.read(self._max_read_bytes):
                    lines += self._split(chunk)
        except OSError:
            lines = []
        lines += self._flush_partial()
        self._skipping = False
        return lines

    def _flush_partial(self) -> list[str]:
        """Return the buffered partial line of a finished file as a line, and clear it."""
        partial, self._partial = self._partial, b""
        return self._decode([partial])

    def _split(self, chunk: bytes) -> list[str]:
        """Cut ``chunk`` into complete lines, keeping the trailing partial line buffered."""
        if self._skipping:
            cut = chunk.find(_NEWLINE)
            if cut < 0:
                return []
            chunk = chunk[cut + 1 :]
            self._skipping = False
        parts = (self._partial + chunk).split(_NEWLINE)
        self._partial = parts.pop()
        if len(self._partial) > self._max_line_bytes:
            self._partial = b""
            self._skipping = True
            self.stats.dropped_lines += 1
        return self._decode(parts)

    def _decode(self, parts: list[bytes]) -> list[str]:
        """Decode raw lines, dropping empty and oversized ones."""
        lines: list[str] = []
        for part in parts:
            raw = part.rstrip(b"\r")
            if not raw:
                continue
            if len(raw) > self._max_line_bytes:
                self.stats.dropped_lines += 1
                continue
            lines.append(raw.decode("utf-8", errors="replace"))
        return lines

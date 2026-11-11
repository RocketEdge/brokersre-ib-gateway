"""Structured JSON logs on stdout with a redaction pass (leaf module).

One line per record, shaped like the gateway's own log contract so both containers can share
a log sink: ``ts``, ``src`` (always ``sidecar``), ``level`` (``debug|info|warn|error``),
``event`` (snake_case), ``msg``, plus the keyword fields of ``log_event``. Every string that
reaches the stream passes ``redact_text`` first, including records of third-party loggers.

Why library loggers are capped at WARNING: httpx logs the full request URL at INFO (a webhook
URL is a credential) and ib_async logs raw API traffic at DEBUG.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any, TextIO

from brokersre_sidecar.clock import format_utc
from brokersre_sidecar.redaction import SecretRegistry, redact_text

_LEVEL_NAMES = {
    logging.DEBUG: "debug",
    logging.INFO: "info",
    logging.WARNING: "warn",
    logging.ERROR: "error",
    logging.CRITICAL: "error",
}
_LEVELS = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warn": logging.WARNING,
    "warning": logging.WARNING,
    "error": logging.ERROR,
}
_NOISY_LIBRARIES = ("httpx", "httpcore", "ib_async", "asyncio")
_FIELDS_ATTRIBUTE = "sidecar_fields"
_EVENT_ATTRIBUTE = "sidecar_event"


def log_event(
    logger: logging.Logger, level: int, event: str, msg: str = "", **fields: object
) -> None:
    """Emit one structured record.

    Args:
        logger: A logger below ``brokersre_sidecar``.
        level: A ``logging`` level constant.
        event: Stable snake_case event name (the key operators alert on).
        msg: Short human text; never a raw gateway line.
        **fields: JSON-serialisable context. Strings are redacted before output.
    """
    logger.log(level, msg, extra={_EVENT_ATTRIBUTE: event, _FIELDS_ATTRIBUTE: fields})


class JsonFormatter(logging.Formatter):
    """Format a record as one redacted JSON object per line.

    Contract: the output is always valid JSON on a single line; no input (message, field,
    exception text) can add a second line or an unredacted secret.
    """

    def __init__(self, registry: SecretRegistry) -> None:
        """Create the formatter.

        Args:
            registry: Secrets loaded by this process; consulted at format time, so secrets
                registered after logging was configured are still scrubbed.
        """
        super().__init__()
        self._registry = registry

    def _clean(self, value: object) -> object:
        """Redact strings inside ``value`` recursively; stringify anything not JSON-native."""
        if isinstance(value, str):
            return redact_text(value, self._registry)
        if isinstance(value, bool | int | float) or value is None:
            return value
        if isinstance(value, dict):
            return {str(key): self._clean(item) for key, item in value.items()}
        if isinstance(value, list | tuple | set | frozenset):
            return [self._clean(item) for item in value]
        return redact_text(str(value), self._registry)

    def format(self, record: logging.LogRecord) -> str:
        """Render ``record`` as a JSON line (see the class contract)."""
        payload: dict[str, Any] = {
            "ts": format_utc(_record_time(record)),
            "src": "sidecar",
            "level": _LEVEL_NAMES.get(record.levelno, "info"),
            "event": getattr(record, _EVENT_ATTRIBUTE, "log"),
            "msg": self._clean(record.getMessage()),
            "logger": record.name,
        }
        fields = getattr(record, _FIELDS_ATTRIBUTE, None)
        if isinstance(fields, dict):
            for key, value in fields.items():
                payload.setdefault(str(key), self._clean(value))
        if record.exc_info and record.exc_info[1] is not None:
            # Type and message only: a traceback can quote local variables and paths, and
            # the operator needs the event, not the stack.
            payload["error_type"] = type(record.exc_info[1]).__name__
            payload["error"] = self._clean(str(record.exc_info[1]))
        return json.dumps(payload, ensure_ascii=True, separators=(",", ":"), default=str)


def _record_time(record: logging.LogRecord) -> datetime:
    """Return the record's creation time as an aware UTC datetime."""
    return datetime.fromtimestamp(record.created, UTC)


def configure_logging(level: str, registry: SecretRegistry, stream: TextIO | None = None) -> None:
    """Install the JSON handler on the root logger, replacing any existing handler.

    Args:
        level: ``debug``, ``info``, ``warn`` or ``error`` (case-insensitive).
        registry: Secrets to scrub from every record.
        stream: Output stream; defaults to ``sys.stdout``.

    Raises:
        ValueError: ``level`` is not one of the accepted names (the message names LOG_LEVEL).

    Side effects:
        Replaces the root logger's handlers and caps third-party loggers at WARNING.
    """
    numeric = _LEVELS.get(level.strip().lower())
    if numeric is None:
        raise ValueError(f"LOG_LEVEL must be one of debug, info, warn, error (got {level!r})")
    handler = logging.StreamHandler(stream if stream is not None else sys.stdout)
    handler.setFormatter(JsonFormatter(registry))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(numeric)
    for name in _NOISY_LIBRARIES:
        logging.getLogger(name).setLevel(logging.WARNING)

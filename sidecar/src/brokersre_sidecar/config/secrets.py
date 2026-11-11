"""Secret files: tolerant reading, validation of their contents, and the ``Secret`` wrapper.

Every credential the sidecar uses (webhook URLs, tokens, the SMTP URL) arrives as a file,
normally a Docker secret under ``/run/secrets``. Files written on Windows often carry a UTF-8
byte-order mark and CRLF; both are stripped, exactly as the gateway does. Anything that
cannot be a single-line secret is refused with an error that names the variable and the
reason and never quotes the content.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit

from brokersre_sidecar.redaction import SecretRegistry

# Far above any real URL or token; bounds the read so a mis-pointed path (a log file, a
# device) cannot exhaust memory.
MAX_SECRET_BYTES = 64 * 1024

_UTF8_BOM = b"\xef\xbb\xbf"
_UTF16_BOMS = (b"\xff\xfe", b"\xfe\xff")
# Telegram bot tokens: numeric bot id, a colon, then the secret part.
_TELEGRAM_TOKEN_RE = re.compile(r"^\d{3,20}:[A-Za-z0-9_-]{10,}$")


class SecretFileError(Exception):
    """A secret file is missing, unreadable or cannot contain a single-line secret.

    The message names the environment variable and the reason; it never contains any part
    of the file's content or its path beyond the variable name.
    """


class Secret:
    """A secret value that does not show itself in ``repr``, ``str`` or f-strings.

    Use ``reveal()`` at the single place the value is handed to the network library.
    """

    __slots__ = ("_value",)

    def __init__(self, value: str) -> None:
        """Wrap ``value``."""
        self._value = value

    def reveal(self) -> str:
        """Return the secret value. Call only where it is sent to its destination."""
        return self._value

    def __repr__(self) -> str:
        """Return a constant placeholder."""
        return "Secret(****)"

    __str__ = __repr__


@dataclass(frozen=True, slots=True)
class SmtpTarget:
    """Where and how to submit mail, parsed from the SMTP URL secret.

    Attributes:
        host: Server host name.
        port: TCP port (465 for ``smtps``, 587 for ``smtp`` unless the URL says otherwise).
        implicit_tls: True for ``smtps://`` (TLS from the first byte); False for ``smtp://``,
            where STARTTLS is mandatory before anything else is sent.
        username: Login name or None for an unauthenticated relay.
        password: Password or None.
    """

    host: str
    port: int
    implicit_tls: bool
    username: str | None
    password: Secret | None


def read_secret_file(path: Path, variable: str) -> str:
    """Read one secret from ``path`` with Windows tolerance.

    Strips a UTF-8 byte-order mark and every trailing CR/LF. Refuses: an unreadable or
    oversized file, UTF-16 (PowerShell's ``>`` redirection writes it), NUL bytes, invalid
    UTF-8, an empty value, and control characters or line breaks inside the value (a line
    break in a token would let it inject an HTTP header).

    Args:
        path: The secret file.
        variable: The ``*_FILE`` environment variable that named it, for the error text.

    Returns:
        The secret value.

    Raises:
        SecretFileError: See above; the message never quotes the content.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_SECRET_BYTES + 1)
    except OSError as error:
        raise SecretFileError(
            f"{variable}: the file cannot be read ({type(error).__name__})"
        ) from None
    if len(data) > MAX_SECRET_BYTES:
        raise SecretFileError(f"{variable}: the file is larger than {MAX_SECRET_BYTES} bytes")
    if data.startswith(_UTF16_BOMS):
        raise SecretFileError(
            f"{variable}: the file is UTF-16; save it as UTF-8 (PowerShell: Set-Content -Encoding utf8NoBOM -NoNewline)"
        )
    if b"\x00" in data:
        raise SecretFileError(
            f"{variable}: the file contains NUL bytes (UTF-16 without a byte-order mark, or binary)"
        )
    if data.startswith(_UTF8_BOM):
        data = data[len(_UTF8_BOM) :]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise SecretFileError(f"{variable}: the file is not valid UTF-8") from None
    text = text.rstrip("\r\n")
    if not text:
        raise SecretFileError(f"{variable}: the file is empty")
    if "\n" in text or "\r" in text:
        raise SecretFileError(f"{variable}: the value contains a line break; a secret is one line")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in text):
        raise SecretFileError(f"{variable}: the value contains a control character")
    return text


def validate_http_url(value: str, variable: str, allow_http: bool) -> None:
    """Check that ``value`` is an absolute ``https://`` URL (``http://`` only when allowed).

    Raises:
        SecretFileError: Wrong scheme, no host, embedded whitespace or a fragment. The
            message names ``variable`` and the rule, never the URL.
    """
    if any(character.isspace() for character in value):
        raise SecretFileError(f"{variable}: the URL contains whitespace")
    try:
        parts = urlsplit(value)
        host = parts.hostname
    except ValueError:
        raise SecretFileError(f"{variable}: the value is not a URL") from None
    if parts.scheme == "http" and not allow_http:
        raise SecretFileError(
            f"{variable}: the URL must start with https:// (set NOTIFY_ALLOW_HTTP=yes only for a local receiver)"
        )
    if parts.scheme not in ("https", "http"):
        raise SecretFileError(f"{variable}: the URL must start with https://")
    if not host:
        raise SecretFileError(f"{variable}: the URL has no host")


def validate_telegram_token(value: str, variable: str) -> None:
    """Check the shape ``<bot id>:<secret>`` of a Telegram bot token.

    Raises:
        SecretFileError: The value does not look like a bot token.
    """
    if not _TELEGRAM_TOKEN_RE.fullmatch(value):
        raise SecretFileError(
            f"{variable}: the value is not a Telegram bot token (expected <digits>:<token>)"
        )


def parse_smtp_url(value: str, variable: str, registry: SecretRegistry) -> SmtpTarget:
    """Parse ``smtps://user:pass@host:465`` or ``smtp://user:pass@host:587``.

    Args:
        value: The URL read from the secret file.
        variable: The variable that named the file, for errors.
        registry: Receives the password so it is scrubbed from every later output.

    Returns:
        The submission target. ``smtp://`` means STARTTLS is required, never plaintext.

    Raises:
        SecretFileError: Wrong scheme, missing host or an invalid port.
    """
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
    except ValueError:
        raise SecretFileError(
            f"{variable}: the value is not a valid smtp:// or smtps:// URL"
        ) from None
    if parts.scheme not in ("smtp", "smtps"):
        raise SecretFileError(
            f"{variable}: the URL must start with smtps:// (implicit TLS) or smtp:// (STARTTLS)"
        )
    if not host:
        raise SecretFileError(f"{variable}: the URL has no host")
    implicit_tls = parts.scheme == "smtps"
    username = unquote(parts.username) if parts.username else None
    password = unquote(parts.password) if parts.password else None
    if password is not None:
        registry.add(password)
    return SmtpTarget(
        host=host,
        port=port if port is not None else (465 if implicit_tls else 587),
        implicit_tls=implicit_tls,
        username=username,
        password=Secret(password) if password is not None else None,
    )

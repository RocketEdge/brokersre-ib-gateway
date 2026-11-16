"""Redaction primitives (leaf module): account ids, loaded secrets and identity assignments.

Rules of the product: an IBKR account id leaves the container only as its last three
characters; a secret (webhook URL, token, password) never leaves at all; a raw IBC line is
forwarded nowhere without passing ``redact_log_line``. The sidecar does not know the IBKR
username (it never receives that secret), so usernames are removed by pattern: whatever
follows an identity-looking key is masked.
"""

from __future__ import annotations

import re
from urllib.parse import quote

REDACTED = "[REDACTED]"
"""Replacement text for a secret or an identity value."""

# The shape of an IBKR account id: an optional D (paper), then one of U, F, I, then zero to
# two further capital letters, then 5 to 9 digits.
#
# Evidence (each source read on 2026-11-16).
#   F and U: "The account number for the Fund Manager master account is denoted with the
#     letter F", "The sub-Hedge Fund account number is denoted with the letter U" (IBKR
#     Campus, hedge fund account overview):
#     https://www.interactivebrokers.com/campus/trading-lessons/hedge-fund-account-overview/
#   I and U: a fully disclosed broker's "Master Account, whose Account ID begins with an I
#     prefix", and its proprietary account, whose id "begins with a U prefix" (IBKR
#     application guide, page 14):
#     https://www.interactivebrokers.ie/download/applicationguide.pdf
#   DU: "The account number for the paper trading account will begin with DU" (Interactive
#     Brokers Securities Japan, customer service):
#     https://www.interactivebrokers.co.jp/en/support/customer-service.php
#   DF and DI: assumptions (paper counterparts of F and I); no source names them.
#   The letter after DU: observed, in no source. A real paper session on 2026-11-16 showed
#     DU, one more letter and six digits; the earlier pattern (DU, DF, U or F directly
#     followed by the digits) missed it and a support bundle carried the id in full.
#   The second further letter: headroom, an assumption. Masking a token that is no id costs
#     readability only; missing an id breaks the rule in the module docstring.
#
# Boundaries. Loose on the left on purpose: an id glued to an underscore, a digit or
# lower-case text (``acct_DUR123456``, the ``\\x00DU1234567`` of a bytes repr) must still be
# caught. Tight in one respect: the match must start at the FIRST letter of a run of capital
# letters, so a run that begins with any letter other than D, U, F, I is never touched
# (``CPU12345``, ``XYZ123456``, ``XDU1234567``). Tight on the right: a tenth digit makes it
# something else (``U1234567890``).
#
# Not caught: lower-case ids (``dur123456``), an id directly behind another capital letter,
# three or more further letters (``DUABC123456``), fewer than 5 or more than 9 digits.
# Caught although no id: any run of one to four capital letters of this shape in front of 5
# to 9 digits (``ID12345``, ``USD100000``, ``FIX12345``, ``0FA2345678`` in upper-case hex).
#
# The same shape lives in azure/vector/redact.vrl, azure/vector/entrypoint.sh and
# azure/vm/apply-config.sh; change the four together.
ACCOUNT_RE = re.compile(r"(?<![A-Z])D?[UFI][A-Z]{0,2}\d{5,9}(?!\d)")

# "key=value" / "key: value" where the key names an identity. The value runs to the next
# whitespace, comma, semicolon or closing bracket. Keys are matched case-insensitively and
# may be glued to a prefix (IbLoginId, FIXLoginId, TWS_USERID).
_IDENTITY_RE = re.compile(
    r"(?i)\b((?:[a-z_]*?)(?:login[ _]?id|user[ _]?name|user[ _]?id|username|userid|user|"
    r"password|passwd|account))(\s*[=:]\s*)([^\s,;\])}]+)"
)

_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# Shorter values would turn ordinary text into "[REDACTED]" soup (a 2-character chat id
# matches everywhere); real secrets are far longer.
_MIN_SECRET_LENGTH = 4


def redact_accounts(text: str) -> str:
    """Replace every IBKR account id in ``text`` by ``***`` plus its last three characters.

    Args:
        text: Any text that may leave the process.

    Returns:
        The text with account ids shortened; unchanged when none is present.
    """
    return ACCOUNT_RE.sub(lambda match: "***" + match.group(0)[-3:], text)


class SecretRegistry:
    """The set of secret values loaded by this process, used to scrub outgoing text.

    Every secret read from a ``*_FILE`` path is registered once at start. ``scrub`` is the
    last line of defence: messages are built from closed vocabularies and never contain a
    secret by construction, and the registry catches the case where that construction is
    wrong. Not thread-safe by design: it is filled before the event loop starts serving.
    """

    def __init__(self) -> None:
        """Start with no registered secret."""
        self._values: list[str] = []

    def add(self, value: str) -> None:
        """Register a secret value and its URL-encoded form.

        Args:
            value: The secret; values shorter than four characters are ignored because
                scrubbing them would mangle unrelated text.
        """
        if len(value) < _MIN_SECRET_LENGTH:
            return
        for candidate in (value, quote(value, safe="")):
            if candidate not in self._values:
                self._values.append(candidate)
        # Longest first, so a secret that contains another is replaced as a whole.
        self._values.sort(key=len, reverse=True)

    def scrub(self, text: str) -> str:
        """Return ``text`` with every registered secret replaced by ``[REDACTED]``."""
        for value in self._values:
            if value in text:
                text = text.replace(value, REDACTED)
        return text


def redact_text(text: str, registry: SecretRegistry) -> str:
    """Scrub registered secrets, then shorten account ids.

    This is the redaction applied to every log record and every human-readable message
    field before it leaves the process.
    """
    return redact_accounts(registry.scrub(text))


def redact_log_line(line: str, registry: SecretRegistry) -> str:
    """Redact one raw gateway log line for inclusion in a support bundle.

    Applies, in order: registered secrets, identity assignments (the value after
    ``username=``, ``IbLoginId:``, ``account=`` ... becomes ``[REDACTED]``), e-mail
    addresses, account ids.

    Args:
        line: One raw line (IBC output); never forwarded unredacted.
        registry: Secrets loaded by this process.

    Returns:
        The redacted line. The caller decides which lines are eligible at all.
    """
    text = registry.scrub(line)
    text = _IDENTITY_RE.sub(lambda match: f"{match.group(1)}{match.group(2)}{REDACTED}", text)
    text = _EMAIL_RE.sub(REDACTED, text)
    return redact_accounts(text)

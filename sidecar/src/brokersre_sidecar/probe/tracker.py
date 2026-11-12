"""Book-keeping of the API error/notice codes that describe the gateway's link to IBKR.

Codes (verified against ib_async 2.1.0 and the IB API message-code table):

* 1100 connectivity to IBKR lost; 1101 restored with data lost; 1102 restored, data kept.
* 2103 / 2104 / 2108: market-data farm broken / OK / inactive (idle, connects on demand).
* 2105 / 2106 / 2107: historical-data farm broken / OK / inactive.
* 2157 / 2158: security-definition farm broken / OK.
* 326: the client id is already in use by another API client.

The gateway re-announces every farm after each API handshake, so the tracker is reset at
every (re)connect and never carries stale state from an earlier connection.
"""

from __future__ import annotations

import re
from collections import OrderedDict

from brokersre_sidecar.model.health import Connectivity, FarmCondition, FarmKind, FarmState
from brokersre_sidecar.redaction import ACCOUNT_RE

CODE_CONNECTIVITY_LOST = 1100
CODES_CONNECTIVITY_RESTORED = frozenset({1101, 1102})
CODE_CLIENT_ID_IN_USE = 326

_FARM_CODES: dict[int, tuple[FarmKind, FarmCondition]] = {
    2103: ("market_data", "broken"),
    2104: ("market_data", "ok"),
    2108: ("market_data", "inactive"),
    2105: ("historical_data", "broken"),
    2106: ("historical_data", "ok"),
    2107: ("historical_data", "inactive"),
    2157: ("sec_def", "broken"),
    2158: ("sec_def", "ok"),
}

# A farm name as IBKR writes it: lower-case letters and digits around one of the stems below,
# optionally a dotted site suffix (usfarm, usfarm.nj, cashfarm, ushmds, secdefnj, usfuture,
# usopt). The notice text comes from the gateway, and a character filter alone would let any
# alphanumeric token through (a username is alphanumeric too), so a name that does not have
# this shape is reported as ``other``: the kind of farm is kept, the text is not.
_FARM_NAME_RE = re.compile(
    r"^[a-z0-9]{0,10}(?:farm|hmds|secdef|future|opt|bond)[a-z0-9]{0,8}(?:[.-][a-z0-9]{1,6})?$"
)
_MAX_FARM_NAME = 24
_MAX_FARMS = 32
_ON_DEMAND_PREFIX = "demand."
OTHER_FARM = "other"
"""Name reported for a farm whose notice did not carry a recognisable farm name."""


def farm_name(message: str) -> str:
    """Extract the farm name from a farm notice, or ``"other"``.

    The notices end in ``...:usfarm`` or, for the inactive form, ``...upon demand.usfarm``.
    Only that last token is looked at, lower-cased, and only when it has the shape of an
    IBKR farm name (see ``_FARM_NAME_RE``) is it returned. Nothing else of the notice ever
    leaves this function, so gateway free text cannot reach ``/status``, ``/readyz`` or an
    alert through a farm notice.
    """
    text = message.strip()
    candidate = text.rsplit(":", 1)[1] if ":" in text else (text.split() or [""])[-1]
    candidate = candidate.strip().lower()
    if candidate.startswith(_ON_DEMAND_PREFIX):
        candidate = candidate[len(_ON_DEMAND_PREFIX) :]
    if (
        len(candidate) <= _MAX_FARM_NAME
        and _FARM_NAME_RE.fullmatch(candidate)
        and not ACCOUNT_RE.search(candidate.upper())
    ):
        return candidate
    return OTHER_FARM


class ApiConditionTracker:
    """State derived from the error/notice codes of the current API connection.

    Bounded: at most 32 farms are remembered (the oldest is forgotten first).
    """

    def __init__(self) -> None:
        """Start with connectivity up, no client-id conflict and no farm known."""
        self._connectivity_lost = False
        self._client_id_in_use = False
        self._farms: OrderedDict[tuple[FarmKind, str], FarmCondition] = OrderedDict()

    def reset(self) -> None:
        """Forget everything; called before each (re)connect and when the phase leaves logged-in."""
        self._connectivity_lost = False
        self._client_id_in_use = False
        self._farms.clear()

    def on_error(self, code: int, message: str) -> None:
        """Apply one API error/notice.

        Args:
            code: IB API error code; unknown codes are ignored.
            message: The gateway's text; only a farm name is extracted from it.
        """
        if code == CODE_CONNECTIVITY_LOST:
            self._connectivity_lost = True
        elif code in CODES_CONNECTIVITY_RESTORED:
            self._connectivity_lost = False
        elif code == CODE_CLIENT_ID_IN_USE:
            self._client_id_in_use = True
        elif code in _FARM_CODES:
            kind, condition = _FARM_CODES[code]
            key = (kind, farm_name(message))
            self._farms[key] = condition
            self._farms.move_to_end(key)
            while len(self._farms) > _MAX_FARMS:
                self._farms.popitem(last=False)

    @property
    def client_id_in_use(self) -> bool:
        """True when error 326 was received since the last reset."""
        return self._client_id_in_use

    @property
    def connectivity(self) -> Connectivity:
        """``lost`` between a 1100 and the next 1101/1102, otherwise ``ok``."""
        return "lost" if self._connectivity_lost else "ok"

    def farms(self) -> tuple[FarmState, ...]:
        """Return every farm reported on this connection, sorted by kind and name."""
        return tuple(
            FarmState(kind=kind, name=name, condition=condition)
            for (kind, name), condition in sorted(self._farms.items())
        )

    def broken_farms(self) -> tuple[FarmState, ...]:
        """Return the farms whose last report was ``broken``."""
        return tuple(farm for farm in self.farms() if farm.condition == "broken")

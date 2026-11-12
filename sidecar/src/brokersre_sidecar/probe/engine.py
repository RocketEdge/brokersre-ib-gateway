"""The read-only API probe: one persistent connection, one time round trip per interval.

``ProbeEngine.tick()`` is called about once a second by its supervised task. It decides
whether anything is due and does at most one bounded network operation per call:

* outside phase ``logged-in`` (or with the probe disabled) nothing is sent, an open
  connection is closed and the status is ``not_measured``;
* right after the phase became ``logged-in`` the endpoint may not accept connections
  yet (the gateway's relay starts a moment later): for ``login_grace_s`` a refused
  connection is retried every few seconds and reported as ``not_measured``, after
  that it is a failure like any other;
* while ``logged-in`` it keeps ONE connection with the reserved client id and asks for the
  server time every ``interval_s``; a failed attempt closes the connection (a half-dead
  connection is never reused) and the next attempt backs off exponentially up to a cap;
* error 326 (client id in use) is reported as its own status and retried no sooner than
  every ``client_id_retry_s`` seconds: hammering the gateway cannot fix a configuration
  conflict;
* API notices arriving between probes (1100/1101/1102, farm codes) update the status at once.

The engine never requests market data, account data or anything order-related; the
``IbClient`` protocol has no method for it.
"""

from __future__ import annotations

import random
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import Clock
from brokersre_sidecar.config import endpoint_text
from brokersre_sidecar.model.health import ProbeError, ProbeSnapshot
from brokersre_sidecar.probe.protocol import (
    IbClient,
    IbConnectError,
    IbDisconnectedError,
    IbError,
    IbTimeoutError,
)
from brokersre_sidecar.probe.tracker import ApiConditionTracker
from brokersre_sidecar.probe.windows import active_reset_window
from brokersre_sidecar.vocab import Phase, ProbeStatus

_CLOSE_WAIT_SAMPLE_S = 5.0
# Delay between connection attempts while the endpoint has not opened after a login.
_ENDPOINT_RETRY_S = 3.0


@dataclass(frozen=True, slots=True)
class ProbeConfig:
    """Parameters of the probe.

    Attributes:
        enabled: False turns the probe off (``PROBE_ENABLED=no``); the status is then
            ``not_measured`` and no socket is ever opened.
        host: Where the gateway's API is reached: the gateway's service name (own network
            namespace, the default) or loopback (shared network namespace).
        port: The API port on ``host``: the relay port from another container, the
            Gateway's own port inside its network namespace.
        client_id: Reserved API client id of the probe (``HEALTH_CLIENT_ID``).
        interval_s: Seconds between round trips while healthy.
        timeout_s: Bound of the handshake and of each round trip.
        login_grace_s: For this long after the phase became ``logged-in``, a connection
            that cannot be opened means "not open yet", not "down".
        backoff_cap_s: Longest delay between attempts while failing.
        zombie_after_s: Half-closed API sockets must persist this long (and the API must
            not answer) before the gateway is called a zombie.
        client_id_retry_s: Delay between attempts while the client id is in use.
    """

    enabled: bool
    host: str
    port: int
    client_id: int
    interval_s: float
    timeout_s: float
    login_grace_s: float = 20.0
    backoff_cap_s: float = 300.0
    zombie_after_s: float = 300.0
    client_id_retry_s: float = 300.0


class ProbeEngine:
    """State machine of the probe. Single-threaded: driven from one asyncio task.

    The status is computed on demand from the last attempt, the API notices and the current
    phase, so ``snapshot()`` is always consistent with what is known at that instant.
    """

    def __init__(
        self,
        config: ProbeConfig,
        client: IbClient,
        clock: Clock,
        *,
        phase: Callable[[], str | None],
        close_wait: Callable[[], int | None],
        rand: Callable[[], float] = random.random,
    ) -> None:
        """Create the engine; nothing is sent until ``tick`` runs in phase ``logged-in``.

        Args:
            config: Probe parameters.
            client: The API connection (the ib_async adapter, or a fake in tests).
            clock: Time source for deadlines, round-trip time and clock skew.
            phase: Returns the gateway's current phase token (None when not measured).
            close_wait: Returns the number of half-closed API sockets, or None when it
                cannot be measured.
            rand: Random source of the back-off jitter, in ``[0, 1]``.
        """
        self._config = config
        self._client = client
        self._clock = clock
        self._phase = phase
        self._close_wait = close_wait
        self._rand = rand
        self._tracker = ApiConditionTracker()
        # First retry after a quarter interval (at least 5 s), doubling up to the cap.
        self._backoff = Backoff(
            base_s=max(5.0, config.interval_s / 4),
            cap_s=max(config.interval_s, config.backoff_cap_s),
        )
        self._endpoint = endpoint_text(config.host, config.port)
        self._next_due: float | None = None
        self._logged_in_since: float | None = None
        self._awaiting_endpoint = False
        self._expect_connected = False
        self._last_probe_at: datetime | None = None
        self._last_probe_ok: bool | None = None
        self._last_rtt_s: float | None = None
        self._last_error: ProbeError | None = None
        self._failures = 0
        self._clock_skew_s: float | None = None
        self._close_wait_count: int | None = None
        self._close_wait_since: float | None = None
        self._close_wait_sampled_at: float | None = None
        self._status: ProbeStatus | None = None
        self._status_since: datetime | None = None
        client.set_error_listener(self._on_api_error)

    async def tick(self) -> None:
        """Run one scheduling step; perform a probe when one is due.

        Never raises for a gateway failure: every transport error becomes part of the
        snapshot. Bounded by twice ``timeout_s`` (handshake plus round trip).
        """
        self._sample_close_wait()
        if not self._config.enabled:
            return
        if self._phase() != Phase.LOGGED_IN:
            self._leave_logged_in()
            return
        now = self._clock.monotonic()
        if self._logged_in_since is None:
            self._logged_in_since = now
        dropped = self._expect_connected and not self._client.is_connected()
        if self._next_due is not None and now < self._next_due and not dropped:
            return
        await self._probe_once()
        self._evaluate()

    def shutdown(self) -> None:
        """Close the API connection; called when the sidecar stops."""
        self._client.disconnect()
        self._expect_connected = False

    def snapshot(self) -> ProbeSnapshot:
        """Return the probe's current result (see ``ProbeSnapshot``)."""
        status, reason = self._evaluate()
        connected = self._expect_connected and self._client.is_connected()
        return ProbeSnapshot(
            status=status,
            reason=reason,
            status_since=self._status_since,
            connectivity=self._tracker.connectivity if connected else "not_measured",
            farms=self._tracker.farms() if connected else (),
            last_probe_at=self._last_probe_at,
            last_probe_ok=self._last_probe_ok,
            last_rtt_s=self._last_rtt_s,
            last_error=self._last_error,
            consecutive_failures=self._failures,
            clock_skew_s=self._clock_skew_s,
            close_wait_sockets=self._close_wait_count,
            zombie=self._is_zombie(),
            in_reset_window=active_reset_window(self._clock.now()) is not None,
        )

    def _on_api_error(self, code: int, message: str) -> None:
        """Receive an API notice from the client (may arrive at any time)."""
        self._tracker.on_error(code, message)
        self._evaluate()

    def _leave_logged_in(self) -> None:
        """Drop the connection and forget results that belonged to the logged-in session."""
        if self._expect_connected or self._client.is_connected():
            self._client.disconnect()
        self._expect_connected = False
        self._tracker.reset()
        self._next_due = None
        self._logged_in_since = None
        self._awaiting_endpoint = False
        self._failures = 0
        self._last_probe_ok = None
        self._last_error = None
        self._last_rtt_s = None
        self._clock_skew_s = None
        self._evaluate()

    async def _probe_once(self) -> None:
        """Connect if needed, do one time round trip and record the outcome."""
        started = self._clock.monotonic()
        try:
            if not self._client.is_connected():
                self._tracker.reset()
                await self._client.connect(
                    self._config.host,
                    self._config.port,
                    self._config.client_id,
                    self._config.timeout_s,
                )
            self._expect_connected = True
            sent_mono = self._clock.monotonic()
            sent_wall = self._clock.now()
            ibkr_time = await self._client.current_time(self._config.timeout_s)
            rtt = self._clock.monotonic() - sent_mono
        except IbError as error:
            self._record_failure(started, error)
            return
        self._awaiting_endpoint = False
        self._last_probe_at = self._clock.now()
        self._last_probe_ok = True
        self._last_error = None
        self._last_rtt_s = rtt
        # Against the local time at the middle of the round trip. IBKR answers in whole
        # seconds, so a healthy clock reads between -1 and 0 here.
        local_midpoint = sent_wall.timestamp() + rtt / 2
        self._clock_skew_s = ibkr_time.timestamp() - local_midpoint
        self._failures = 0
        self._next_due = started + self._config.interval_s

    def _record_failure(self, started: float, error: IbError) -> None:
        """Record a failed attempt, drop the connection and schedule the next attempt."""
        self._client.disconnect()
        self._expect_connected = False
        if self._endpoint_not_open_yet(started, error):
            self._awaiting_endpoint = True
            self._next_due = started + _ENDPOINT_RETRY_S
            return
        self._awaiting_endpoint = False
        self._failures += 1
        self._last_probe_at = self._clock.now()
        self._last_probe_ok = False
        self._last_rtt_s = None
        if self._tracker.client_id_in_use:
            self._last_error = "client_id_in_use"
            self._next_due = started + max(self._config.client_id_retry_s, self._backoff.cap_s)
            return
        if isinstance(error, IbConnectError):
            self._last_error = "connect_failed"
        elif isinstance(error, IbTimeoutError):
            self._last_error = "timeout"
        elif isinstance(error, IbDisconnectedError):
            self._last_error = "disconnected"
        else:
            self._last_error = "connect_failed"
        self._next_due = started + self._backoff.delay(self._failures, self._rand)

    def _endpoint_not_open_yet(self, started: float, error: IbError) -> bool:
        """Report whether a failed connect still falls into the grace after a login.

        The phase file says ``logged-in`` a moment before the API endpoint accepts
        connections (the relay is started by the gateway after the login). Calling
        that ``down`` would be a false alarm at every login, and backing off would make
        the first real answer late. The grace ends for good with the first result of
        the session: once the API has answered, a refused connection is a failure.
        """
        return (
            isinstance(error, IbConnectError)
            and not self._tracker.client_id_in_use
            and self._last_probe_ok is None
            and self._logged_in_since is not None
            and started - self._logged_in_since < self._config.login_grace_s
        )

    def _sample_close_wait(self) -> None:
        """Sample the half-closed socket count every few seconds and track how long it is > 0."""
        now = self._clock.monotonic()
        if (
            self._close_wait_sampled_at is not None
            and now - self._close_wait_sampled_at < _CLOSE_WAIT_SAMPLE_S
        ):
            return
        self._close_wait_sampled_at = now
        self._close_wait_count = self._close_wait()
        if self._close_wait_count is None or self._close_wait_count <= 0:
            self._close_wait_since = None
        elif self._close_wait_since is None:
            self._close_wait_since = now

    def _is_zombie(self) -> bool:
        """True when half-closed sockets have persisted and the last attempt failed."""
        return (
            self._close_wait_since is not None
            and self._clock.monotonic() - self._close_wait_since >= self._config.zombie_after_s
            and self._last_probe_ok is False
        )

    def _evaluate(self) -> tuple[ProbeStatus, str]:
        """Compute status and reason now, and note the time when the status changes."""
        status, reason = self._compute()
        if status is not self._status:
            self._status = status
            self._status_since = self._clock.now()
        return status, reason

    def _compute(self) -> tuple[ProbeStatus, str]:
        """Derive ``(status, reason)`` from the configuration, the phase and the last results."""
        config = self._config
        if not config.enabled:
            return ProbeStatus.NOT_MEASURED, "the API probe is disabled (PROBE_ENABLED=no)"
        phase = self._phase()
        if phase != Phase.LOGGED_IN:
            shown = phase if phase is not None else "not measured"
            return (
                ProbeStatus.NOT_MEASURED,
                f"gateway phase is {shown}; the API is probed only while it is logged-in",
            )
        if self._last_error == "client_id_in_use":
            return (
                ProbeStatus.CLIENT_ID_IN_USE,
                f"API client id {config.client_id} is already in use by another client "
                "(error 326); stop that client or set HEALTH_CLIENT_ID to a free id",
            )
        if self._last_probe_ok is None:
            if self._awaiting_endpoint:
                return (
                    ProbeStatus.NOT_MEASURED,
                    f"logged in; {self._endpoint} does not accept connections yet "
                    f"(waiting up to {config.login_grace_s:g} s)",
                )
            return ProbeStatus.NOT_MEASURED, "first probe pending"
        if not self._last_probe_ok:
            if self._is_zombie():
                return (
                    ProbeStatus.DOWN,
                    f"the gateway holds {self._close_wait_count} half-closed API sockets and "
                    "does not answer (zombie)",
                )
            if self._last_error == "timeout":
                return (
                    ProbeStatus.DOWN,
                    f"the time round trip timed out after {config.timeout_s:g} s",
                )
            if self._last_error == "disconnected":
                return ProbeStatus.DOWN, "the API connection dropped during the round trip"
            return (
                ProbeStatus.DOWN,
                f"no API handshake on {self._endpoint} within {config.timeout_s:g} s",
            )
        if self._tracker.connectivity == "lost":
            return (
                ProbeStatus.DEGRADED,
                "IBKR connectivity lost (1100) and not yet restored (1101/1102)",
            )
        broken = self._tracker.broken_farms()
        if broken:
            listed = ", ".join(f"{farm.kind} {farm.name}" for farm in broken)
            return ProbeStatus.DEGRADED, f"data farm broken: {listed}"
        return ProbeStatus.READY, "time round trip ok, connectivity up, no farm broken"

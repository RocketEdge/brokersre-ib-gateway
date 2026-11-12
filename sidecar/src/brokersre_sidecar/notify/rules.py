"""Alert rules: turn the gateway and probe snapshots into one verdict per alert class.

Each verdict is three-valued. ``ACTIVE``: the condition holds. ``INACTIVE``: it provably
does not. ``UNKNOWN``: it cannot be decided right now (the input is not measured, the
condition has not lasted long enough yet, or a reset window makes it meaningless). An
``UNKNOWN`` verdict changes nothing: it neither raises an alert nor resolves one. That is
"absence is never healthy" applied to alerting, and it is also what stops a restart of the
sidecar from sending a false "resolved".

The ``detail`` of a verdict is built from numbers and fixed words only.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum

from brokersre_sidecar.model.health import ProbeSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot
from brokersre_sidecar.vocab import UNKNOWN_PHASE, AlertClass, Phase, ProbeStatus

_UNHEALTHY = frozenset({ProbeStatus.DOWN, ProbeStatus.DEGRADED, ProbeStatus.CLIENT_ID_IN_USE})
_SILENCE_EXPECTED = frozenset({Phase.STOPPING, Phase.STOPPED, Phase.EXITED})
_LOGIN_FAILURE_EVENTS = ("login_failed", "login_failed_dialog")


class Condition(Enum):
    """Verdict of one rule (see the module docstring)."""

    ACTIVE = "active"
    INACTIVE = "inactive"
    UNKNOWN = "unknown"


@dataclass(frozen=True, slots=True)
class Evaluation:
    """Verdict plus a short factual detail for the notification.

    Attributes:
        state: The verdict.
        detail: Numbers and fixed words describing an ``ACTIVE`` verdict; empty otherwise.
    """

    state: Condition
    detail: str = ""


@dataclass(frozen=True, slots=True)
class RuleConfig:
    """Thresholds of the rules. Only ``login_stall_s`` is operator-configurable.

    Attributes:
        login_stall_s: Phase ``login`` longer than this is a stalled login (LOGIN_STALL_S).
        api_unhealthy_after_s: The API must be unhealthy this long before it alerts.
        storm_boots: Gateway starts within 30 minutes that make a restart storm.
        memory_high_for_s: Memory pressure must last this long before it alerts.
        event_hold_s: An event-triggered condition stays active this long after the event.
        clock_skew_max_s: Tolerated clock difference in seconds.
        silent_after_s: Seconds without any feed line that count as silence.
        disk_low_bytes: Free space below this on a gateway volume is low.
    """

    login_stall_s: float
    api_unhealthy_after_s: float = 300.0
    storm_boots: int = 3
    memory_high_for_s: float = 600.0
    event_hold_s: float = 900.0
    clock_skew_max_s: float = 1.0
    silent_after_s: float = 300.0
    disk_low_bytes: float = 256 * 1024 * 1024


_ACTIVE = Condition.ACTIVE
_INACTIVE = Evaluation(Condition.INACTIVE)
_UNKNOWN = Evaluation(Condition.UNKNOWN)


def skew_exceeds(skew_s: float, limit_s: float) -> bool:
    """Report whether a measured clock skew is PROVABLY beyond ``limit_s``.

    IBKR answers the time request in whole seconds. The measured value (IBKR time minus the
    local time at the middle of the round trip) therefore understates the true difference
    by up to one second if IBKR truncates, or misstates it by half a second either way if
    it rounds. The alert fires only when every reading consistent with both behaviours is
    beyond the limit; a perfectly synchronised clock (which reads between -1 and +0.5)
    never alerts.

    Args:
        skew_s: IBKR time minus local time, in seconds.
        limit_s: Tolerated absolute difference.
    """
    return skew_s - 0.5 > limit_s or skew_s + 1.0 < -limit_s


class RuleEngine:
    """Evaluates every condition class.

    Holds one piece of memory: since when the API has been continuously unhealthy (moving
    between ``down`` and ``degraded`` must not restart that clock). Single-threaded.
    """

    def __init__(self, config: RuleConfig) -> None:
        """Create the engine with its thresholds."""
        self._config = config
        self._unhealthy_since: datetime | None = None

    def evaluate(
        self,
        gateway: GatewaySnapshot,
        probe: ProbeSnapshot,
        *,
        now: datetime,
        volume_present: bool,
    ) -> dict[AlertClass, Evaluation]:
        """Return a verdict for every condition class.

        Args:
            gateway: What the feeds and the phase file say.
            probe: What the API probe says.
            now: Current time (UTC).
            volume_present: Whether the gateway's log volume is mounted.

        Returns:
            One ``Evaluation`` per class except ``HEARTBEAT`` (which is not a condition).
        """
        phase = gateway.phase
        phase_known = phase is not None and phase != UNKNOWN_PHASE
        return {
            AlertClass.TWOFA_PENDING: self._phase_is(phase, phase_known, Phase.TWOFA_PENDING),
            AlertClass.NEEDS_HUMAN: self._phase_is(phase, phase_known, Phase.NEEDS_HUMAN),
            AlertClass.LOGIN_FAILED: self._login_failed(gateway, now),
            AlertClass.EXISTING_SESSION: self._phase_is(phase, phase_known, Phase.EXISTING_SESSION),
            AlertClass.LOGIN_STALLED: self._login_stalled(gateway, phase_known, now),
            AlertClass.UNKNOWN_WINDOW: self._unknown_window(gateway, now),
            AlertClass.GATEWAY_EXITED: self._phase_is(phase, phase_known, Phase.EXITED),
            AlertClass.API_UNHEALTHY: self._api_unhealthy(probe, now),
            AlertClass.RESTART_STORM: self._restart_storm(gateway),
            AlertClass.RESOURCE_ALERT: self._resource_alert(gateway, now),
            AlertClass.DISK_LOW: self._disk_low(gateway, now),
            AlertClass.CLOCK_SKEW: self._clock_skew(probe),
            AlertClass.GATEWAY_SILENT: self._silent(gateway, now, volume_present),
        }

    @staticmethod
    def _phase_is(phase: str | None, known: bool, wanted: Phase) -> Evaluation:
        """Active exactly while the phase is ``wanted``; unknown without a known phase."""
        if not known:
            return _UNKNOWN
        if phase == wanted:
            return Evaluation(_ACTIVE, f"gateway phase is {wanted.value}")
        return _INACTIVE

    def _fresh(self, gateway: GatewaySnapshot, name: str, now: datetime) -> bool:
        """True when event ``name`` happened within the hold time."""
        event = gateway.last_events.get(name)
        return event is not None and now - event.ts <= timedelta(seconds=self._config.event_hold_s)

    def _login_failed(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active after a recent login failure that no later login has superseded."""
        if not gateway.feeds_seen:
            return _UNKNOWN
        failures = [
            gateway.last_events[name].ts
            for name in _LOGIN_FAILURE_EVENTS
            if self._fresh(gateway, name, now)
        ]
        if not failures or gateway.phase == Phase.LOGGED_IN:
            return _INACTIVE
        if gateway.last_login is not None and gateway.last_login >= max(failures):
            return _INACTIVE
        return Evaluation(_ACTIVE, "the gateway reported a failed login")

    def _login_stalled(self, gateway: GatewaySnapshot, known: bool, now: datetime) -> Evaluation:
        """Active when phase ``login`` has lasted too long, or the gateway says so itself."""
        if not known:
            return _UNKNOWN
        if gateway.phase != Phase.LOGIN:
            return _INACTIVE
        limit = self._config.login_stall_s
        if self._fresh(gateway, "login_stalled", now):
            return Evaluation(_ACTIVE, "the gateway reported a stalled login")
        if gateway.phase_since is None:
            return _UNKNOWN
        elapsed = (now - gateway.phase_since).total_seconds()
        if elapsed > limit:
            return Evaluation(_ACTIVE, f"in phase login for {elapsed:.0f} s (limit {limit:.0f} s)")
        return _UNKNOWN

    def _unknown_window(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active after a recent unclassified dialog while the gateway is not logged in."""
        if not gateway.feeds_seen:
            return _UNKNOWN
        if self._fresh(gateway, "unknown_window", now) and gateway.phase != Phase.LOGGED_IN:
            return Evaluation(_ACTIVE, "the gateway reported an unrecognised dialog")
        return _INACTIVE

    def _api_unhealthy(self, probe: ProbeSnapshot, now: datetime) -> Evaluation:
        """Active when the API has been unhealthy for long enough outside reset windows."""
        if probe.status is ProbeStatus.READY:
            self._unhealthy_since = None
            return _INACTIVE
        if probe.status not in _UNHEALTHY:
            return _UNKNOWN
        if self._unhealthy_since is None:
            since = probe.status_since if probe.status_since is not None else now
            self._unhealthy_since = min(since, now)
        elapsed = (now - self._unhealthy_since).total_seconds()
        if elapsed <= self._config.api_unhealthy_after_s or probe.in_reset_window:
            # Too early to say, or a disconnect that IBKR's schedule explains.
            return _UNKNOWN
        return Evaluation(
            _ACTIVE, f"API status {probe.status.value} for {elapsed:.0f} s: {probe.reason}"
        )

    def _restart_storm(self, gateway: GatewaySnapshot) -> Evaluation:
        """Active at ``storm_boots`` or more gateway starts within 30 minutes."""
        if gateway.boots_30m is None:
            return _UNKNOWN
        if gateway.boots_30m >= self._config.storm_boots:
            return Evaluation(_ACTIVE, f"{gateway.boots_30m} gateway starts in the last 30 minutes")
        return _INACTIVE

    def _resource_alert(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active on a recent OOM kill or on sustained memory pressure."""
        hold = timedelta(seconds=self._config.event_hold_s)
        if gateway.last_oom_at is not None and now - gateway.last_oom_at <= hold:
            return Evaluation(_ACTIVE, "an out-of-memory kill was observed")
        if gateway.memory_ratio is None:
            return _UNKNOWN
        if gateway.memory_high_since is None:
            return _INACTIVE
        elapsed = (now - gateway.memory_high_since).total_seconds()
        if elapsed >= self._config.memory_high_for_s:
            percent = gateway.memory_ratio * 100
            return Evaluation(
                _ACTIVE, f"memory working set at {percent:.0f}% of the limit for {elapsed:.0f} s"
            )
        return _UNKNOWN

    def _disk_low(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active on the gateway's ``disk_low`` event or a measured free space below the limit."""
        if self._fresh(gateway, "disk_low", now):
            return Evaluation(_ACTIVE, "the gateway reported low disk space")
        values = gateway.last_metrics.values if gateway.last_metrics is not None else {}
        measured = [
            (volume, values[key])
            for volume, key in (
                ("log", "disk_free_bytes_logs"),
                ("settings", "disk_free_bytes_settings"),
            )
            if key in values
        ]
        if not measured:
            return _UNKNOWN
        low = [(volume, free) for volume, free in measured if free < self._config.disk_low_bytes]
        if low:
            volume, free = min(low, key=lambda item: item[1])
            return Evaluation(_ACTIVE, f"{free / 1024**2:.0f} MiB free on the {volume} volume")
        return _INACTIVE

    def _clock_skew(self, probe: ProbeSnapshot) -> Evaluation:
        """Active when the host clock provably differs from IBKR time by more than the limit."""
        if probe.clock_skew_s is None:
            return _UNKNOWN
        if skew_exceeds(probe.clock_skew_s, self._config.clock_skew_max_s):
            return Evaluation(_ACTIVE, f"IBKR time minus host time is {probe.clock_skew_s:.1f} s")
        return _INACTIVE

    def _silent(self, gateway: GatewaySnapshot, now: datetime, volume_present: bool) -> Evaluation:
        """Active when a mounted, running gateway wrote nothing for ``silent_after_s``."""
        if (
            not volume_present
            or not gateway.feeds_seen
            or gateway.last_activity_at is None
            or gateway.phase in _SILENCE_EXPECTED
        ):
            return _UNKNOWN
        quiet = (now - gateway.last_activity_at).total_seconds()
        if quiet > self._config.silent_after_s:
            return Evaluation(_ACTIVE, f"no event and no metrics sample for {quiet:.0f} s")
        return _INACTIVE

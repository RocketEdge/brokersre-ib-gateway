"""Alert rules: turn the gateway and probe snapshots into one verdict per alert class.

Each verdict is three-valued. ``ACTIVE``: the condition holds. ``INACTIVE``: it provably
does not. ``UNKNOWN``: it cannot be decided right now (the input is not measured, the
condition has not lasted long enough yet, or a reset window makes it meaningless). An
``UNKNOWN`` verdict changes nothing: it neither raises an alert nor resolves one. That is
"absence is never healthy" applied to alerting, and it is also what stops a restart of the
sidecar from sending a false "resolved".

Who decides what:

* Conditions the gateway reports as an event pair (a stalled login, low disk space, memory
  pressure) are the gateway's call alone. The rule is "the pair is open"; the sidecar keeps
  no threshold and no timer for them, so the two can never disagree and nothing "resolves"
  because a timer ran out.
* Durations the sidecar does measure (API unhealthy, silence) run on the monotonic clock.

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
_NOT_RUNNING = frozenset({Phase.STOPPING, Phase.STOPPED, Phase.EXITED})
# Phases the gateway passes through between two second-factor prompts.
_BETWEEN_PROMPTS = frozenset({Phase.LOGIN, Phase.RESTARTING, Phase.STARTING})
_TWOFA_EVENTS = ("twofa_initiated", "twofa_dialog", "twofa_timeout")
# Phases in which another alert takes over from a pending second factor.
_TWOFA_SUCCESSORS: dict[str, AlertClass] = {
    Phase.NEEDS_HUMAN: AlertClass.NEEDS_HUMAN,
    Phase.EXITED: AlertClass.GATEWAY_EXITED,
}


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
        superseded_by: For an ``INACTIVE`` verdict that is a hand-over rather than a
            recovery: the alert class that describes the gateway now.
    """

    state: Condition
    detail: str = ""
    superseded_by: AlertClass | None = None


@dataclass(frozen=True, slots=True)
class RuleConfig:
    """Thresholds of the rules the sidecar itself measures.

    Attributes:
        api_unhealthy_after_s: The API must be unhealthy this long before it alerts.
        storm_boots: Gateway starts within 30 minutes that make a restart storm.
        event_hold_s: A point event (failed login, unknown dialog, OOM kill) keeps its
            condition active this long.
        clock_skew_max_s: Tolerated clock difference in seconds.
        silent_after_s: Seconds without an observed feed line that count as silence.
    """

    api_unhealthy_after_s: float = 300.0
    storm_boots: int = 3
    event_hold_s: float = 900.0
    clock_skew_max_s: float = 1.0
    silent_after_s: float = 300.0


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

    Holds one piece of memory: since when (monotonic) the API has been continuously
    unhealthy; moving between ``down`` and ``degraded`` must not restart that clock.
    Single-threaded.
    """

    def __init__(self, config: RuleConfig) -> None:
        """Create the engine with its thresholds."""
        self._config = config
        self._unhealthy_since: float | None = None

    def evaluate(
        self,
        gateway: GatewaySnapshot,
        probe: ProbeSnapshot,
        *,
        now: datetime,
        mono: float,
    ) -> dict[AlertClass, Evaluation]:
        """Return a verdict for every condition class.

        Args:
            gateway: What the feeds and the phase file say.
            probe: What the API probe says.
            now: Current time (UTC), for the age of point events.
            mono: Current monotonic reading, for durations.

        Returns:
            One ``Evaluation`` per class except ``HEARTBEAT`` (which is not a condition).
        """
        phase = gateway.phase
        known = phase is not None and phase != UNKNOWN_PHASE
        return {
            AlertClass.TWOFA_PENDING: self._twofa_pending(gateway, known),
            AlertClass.NEEDS_HUMAN: self._needs_human(gateway, known),
            AlertClass.LOGIN_FAILED: self._login_failed(gateway, now),
            AlertClass.EXISTING_SESSION: self._phase_is(phase, known, Phase.EXISTING_SESSION),
            AlertClass.LOGIN_STALLED: self._login_stalled(gateway, known),
            AlertClass.UNKNOWN_WINDOW: self._unknown_window(gateway, now),
            AlertClass.GATEWAY_EXITED: self._phase_is(phase, known, Phase.EXITED),
            AlertClass.API_UNHEALTHY: self._api_unhealthy(probe, now, mono),
            AlertClass.RESTART_STORM: self._restart_storm(gateway),
            AlertClass.RESOURCE_ALERT: self._resource_alert(gateway, now),
            AlertClass.DISK_LOW: self._pair(
                gateway, "disk_low", "the gateway reports low disk space"
            ),
            AlertClass.CLOCK_SKEW: self._clock_skew(probe),
            AlertClass.GATEWAY_SILENT: self._silent(gateway),
        }

    @staticmethod
    def _phase_is(phase: str | None, known: bool, wanted: Phase) -> Evaluation:
        """Active exactly while the phase is ``wanted``; unknown without a known phase."""
        if not known:
            return _UNKNOWN
        if phase == wanted:
            return Evaluation(_ACTIVE, f"gateway phase is {wanted.value}")
        return _INACTIVE

    @staticmethod
    def _twofa_pending(gateway: GatewaySnapshot, known: bool) -> Evaluation:
        """Active from the first second-factor prompt until a login completes.

        With the gateway's defaults an unanswered prompt times out after 180 s, the
        gateway logs in again and prompts again, for hours: the phase flips
        ``2fa-pending`` -> ``login`` -> ``2fa-pending``. For a person nothing changed
        in between, so the condition holds across the flip: while the phase is
        ``login``, ``restarting`` or ``starting`` and this boot has prompted for a
        second factor since the last completed login. Only ``logged-in`` resolves it.
        When the gateway gives up (``needs-human``) or goes away (``exited``,
        ``stopped``), the verdict is a hand-over to that alert, not a recovery.
        """
        if not known:
            return _UNKNOWN
        phase = gateway.phase
        if phase == Phase.TWOFA_PENDING:
            return Evaluation(_ACTIVE, "gateway phase is 2fa-pending")
        if phase in _TWOFA_SUCCESSORS:
            return Evaluation(Condition.INACTIVE, superseded_by=_TWOFA_SUCCESSORS[phase])
        if phase not in _BETWEEN_PROMPTS:
            return _INACTIVE
        prompts = [
            event.ts
            for name in _TWOFA_EVENTS
            if (event := gateway.last_events.get(name)) is not None
            and (event.boot_id is None or event.boot_id == gateway.boot_id)
        ]
        if not prompts:
            return _INACTIVE
        if gateway.last_login is not None and gateway.last_login >= max(prompts):
            return _INACTIVE
        return Evaluation(
            _ACTIVE, f"second factor not approved yet; gateway phase is {phase} between prompts"
        )

    @staticmethod
    def _pair(gateway: GatewaySnapshot, name: str, detail: str) -> Evaluation:
        """Follow a gateway-reported pair: open is active, closed inactive, unseen unknown."""
        pair = gateway.pairs.get(name)
        if pair is None:
            return _UNKNOWN
        return Evaluation(_ACTIVE, detail) if pair.open else _INACTIVE

    def _fresh(self, gateway: GatewaySnapshot, name: str, now: datetime) -> bool:
        """True when event ``name`` happened within the hold time."""
        event = gateway.last_events.get(name)
        return event is not None and now - event.ts <= timedelta(seconds=self._config.event_hold_s)

    @staticmethod
    def _needs_human(gateway: GatewaySnapshot, known: bool) -> Evaluation:
        """Active while the phase is ``needs-human``; the detail names the cause when known."""
        if not known:
            return _UNKNOWN
        if gateway.phase != Phase.NEEDS_HUMAN:
            return _INACTIVE
        rejected = gateway.last_events.get("login_failed_dialog")
        unapproved = gateway.last_events.get("needs_human")
        detail = "gateway phase is needs-human"
        if rejected is not None and (unapproved is None or rejected.ts >= unapproved.ts):
            detail += ": IBKR rejected the login"
        elif unapproved is not None:
            detail += ": the second factor was not approved"
        return Evaluation(_ACTIVE, detail)

    def _login_failed(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active after a recent failed login that no later login has superseded.

        Silent while the phase is ``needs-human``: a rejected login puts the gateway there,
        and that one alert carries the cause.
        """
        if not gateway.feeds_seen:
            return _UNKNOWN
        if gateway.phase in (Phase.LOGGED_IN, Phase.NEEDS_HUMAN):
            return _INACTIVE
        if not self._fresh(gateway, "login_failed", now):
            return _INACTIVE
        failed_at = gateway.last_events["login_failed"].ts
        if gateway.last_login is not None and gateway.last_login >= failed_at:
            return _INACTIVE
        return Evaluation(_ACTIVE, "the gateway reported a failed login")

    @staticmethod
    def _login_stalled(gateway: GatewaySnapshot, known: bool) -> Evaluation:
        """Active while the gateway's ``login_stalled`` pair is open and it is still logging in."""
        if not known:
            return _UNKNOWN
        pair = gateway.pairs.get("login_stalled")
        if pair is None:
            # The gateway never reported a stall; a login that is merely in progress is
            # not for the sidecar to judge.
            return _UNKNOWN if gateway.phase == Phase.LOGIN else _INACTIVE
        if pair.open and gateway.phase == Phase.LOGIN:
            return Evaluation(_ACTIVE, "the gateway reports a stalled login")
        return _INACTIVE

    def _unknown_window(self, gateway: GatewaySnapshot, now: datetime) -> Evaluation:
        """Active after a recent unclassified dialog while the gateway is not logged in."""
        if not gateway.feeds_seen:
            return _UNKNOWN
        if self._fresh(gateway, "unknown_window", now) and gateway.phase != Phase.LOGGED_IN:
            return Evaluation(_ACTIVE, "the gateway reported an unrecognised dialog")
        return _INACTIVE

    def _api_unhealthy(self, probe: ProbeSnapshot, now: datetime, mono: float) -> Evaluation:
        """Active when the API has been unhealthy for long enough outside reset windows."""
        if probe.status is ProbeStatus.READY:
            self._unhealthy_since = None
            return _INACTIVE
        if probe.status not in _UNHEALTHY:
            return _UNKNOWN
        if self._unhealthy_since is None:
            already = (now - probe.status_since).total_seconds() if probe.status_since else 0.0
            self._unhealthy_since = mono - max(0.0, already)
        elapsed = mono - self._unhealthy_since
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
        """Active on a recent OOM kill or while the gateway's ``memory_high`` pair is open."""
        hold = timedelta(seconds=self._config.event_hold_s)
        if gateway.last_oom_at is not None and now - gateway.last_oom_at <= hold:
            return Evaluation(_ACTIVE, "the gateway reports an out-of-memory kill")
        pair = gateway.pairs.get("memory_high")
        if pair is None:
            return _INACTIVE if gateway.last_oom_at is not None else _UNKNOWN
        if pair.open and gateway.phase not in _NOT_RUNNING:
            return Evaluation(_ACTIVE, "the gateway reports memory pressure")
        return _INACTIVE

    def _clock_skew(self, probe: ProbeSnapshot) -> Evaluation:
        """Active when the host clock provably differs from IBKR time by more than the limit."""
        if probe.clock_skew_s is None:
            return _UNKNOWN
        if skew_exceeds(probe.clock_skew_s, self._config.clock_skew_max_s):
            return Evaluation(_ACTIVE, f"IBKR time minus host time is {probe.clock_skew_s:.1f} s")
        return _INACTIVE

    def _silent(self, gateway: GatewaySnapshot) -> Evaluation:
        """Active when a running gateway wrote nothing the sidecar observed for too long."""
        if (
            not gateway.volume_present
            or not gateway.feeds_seen
            or gateway.quiet_for_s is None
            or gateway.phase in _NOT_RUNNING
        ):
            return _UNKNOWN
        if gateway.quiet_for_s > self._config.silent_after_s:
            return Evaluation(
                _ACTIVE, f"no event and no metrics sample for {gateway.quiet_for_s:.0f} s"
            )
        return _INACTIVE

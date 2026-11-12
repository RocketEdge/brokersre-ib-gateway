"""The dead-man ping: tell an outside service "all is well" so that silence becomes the alarm.

Every alert of the sidecar needs the sidecar, its host and its network to be alive. When the
host loses power, nothing is sent and nobody notices. The cure is a signal in the opposite
direction: the sidecar fetches a URL at a fixed interval, and a monitoring service that
expects those pings (Healthchecks, Uptime Kuma push monitors, Dead Man's Snitch, a Prometheus
blackbox job of your own) raises the alarm when they stop.

The ping is sent only while everything it vouches for holds:

* the sidecar's own tasks run and make progress;
* the gateway's log volume is readable and the phase is known;
* no alert that asks a person to act is active (severity ``warning`` or higher, classes
  switched off with ``NOTIFY_DISABLE_CLASSES`` excepted).

So the pings also stop when the gateway needs attention, which makes the monitoring service a
second, independent path for the alerts the channels carry.

The request is a plain ``GET`` of exactly the configured URL: nothing is appended to the URL
and there is no body, so no state of the gateway leaves through it. The URL is a credential
(it identifies the check) and is never logged or shown.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Mapping
from datetime import datetime

from brokersre_sidecar.clock import Clock
from brokersre_sidecar.config import Secret
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import DeadmanSnapshot
from brokersre_sidecar.notify.catalog import CATALOG, CONDITION_CLASSES
from brokersre_sidecar.notify.channels import DeliveryError, HttpTransport
from brokersre_sidecar.notify.channels.base import HttpRequest
from brokersre_sidecar.notify.rules import Condition, Evaluation
from brokersre_sidecar.vocab import AlertClass, Severity

_LOGGER = logging.getLogger(__name__)

# After a failed ping the next attempt comes sooner than a whole interval: one lost request
# must not look like a dead sidecar to a service that allows little grace.
_RETRY_S = 15.0
_ASKS_A_PERSON = frozenset({Severity.WARNING, Severity.ERROR, Severity.CRITICAL})


def alerting_classes(
    evaluations: Mapping[AlertClass, Evaluation], disabled: frozenset[str]
) -> tuple[AlertClass, ...]:
    """Return the active alert classes that ask a person to act, in catalogue order.

    Args:
        evaluations: Verdict per class from ``RuleEngine.evaluate``.
        disabled: Class names switched off by the operator; they never count.

    Returns:
        Classes whose verdict is ``ACTIVE`` and whose severity is ``warning`` or higher. An
        ``info`` class (a gateway stopped on request) does not count: nobody needs to act.
    """
    return tuple(
        alert
        for alert in CONDITION_CLASSES
        if alert.value not in disabled
        and CATALOG[alert].severity in _ASKS_A_PERSON
        and (evaluation := evaluations.get(alert)) is not None
        and evaluation.state is Condition.ACTIVE
    )


class DeadmanPinger:
    """Sends the ping when one is due and nothing speaks against it. Single-threaded."""

    def __init__(
        self,
        url: Secret,
        transport: HttpTransport,
        clock: Clock,
        *,
        interval_s: float,
        withhold: Callable[[], str | None],
    ) -> None:
        """Create the pinger; nothing is sent until ``tick`` runs.

        Args:
            url: The ping URL (a credential).
            transport: Shared outbound HTTP transport (bounded, no redirects).
            clock: Time source.
            interval_s: Seconds between pings (``DEADMAN_PING_INTERVAL_S``).
            withhold: Returns None when a ping may be sent, otherwise a short reason made of
                fixed words (it is shown in ``/status`` and logged).
        """
        self._url = url
        self._transport = transport
        self._clock = clock
        self._interval_s = interval_s
        self._withhold = withhold
        self._next_due: float | None = None
        self._withheld: str | None = None
        self._last_ping_at: datetime | None = None
        self._last_error: str | None = None
        self._pings = 0
        self._failures = 0

    async def tick(self) -> None:
        """Send one ping if it is due and allowed; never raises for a failed request.

        While a reason to withhold exists nothing is sent, and the ping goes out at the
        first tick after the reason is gone. Bounded by the transport's timeout.
        """
        reason = self._withhold()
        if reason != self._withheld:
            self._withheld = reason
            if reason is None:
                log_event(_LOGGER, logging.INFO, "deadman_resumed", "dead-man pings resume")
            else:
                log_event(_LOGGER, logging.WARNING, "deadman_withheld", reason)
        if reason is not None:
            return
        mono = self._clock.monotonic()
        if self._next_due is not None and mono < self._next_due:
            return
        try:
            await self._transport.send(HttpRequest(url=self._url.reveal(), body=b"", method="GET"))
        except DeliveryError as error:
            self._failures += 1
            if self._last_error != error.category:
                log_event(
                    _LOGGER,
                    logging.WARNING,
                    "deadman_ping_failed",
                    "the dead-man ping failed; it is tried again",
                    error=error.category,
                )
            self._last_error = error.category
            self._next_due = mono + min(self._interval_s, _RETRY_S)
            return
        if self._last_error is not None:
            log_event(_LOGGER, logging.INFO, "deadman_ping_ok", "the dead-man ping works again")
        self._pings += 1
        self._last_error = None
        self._last_ping_at = self._clock.now()
        self._next_due = mono + self._interval_s

    def snapshot(self) -> DeadmanSnapshot:
        """Return the pinger's state for ``/status`` and ``/metrics``."""
        return DeadmanSnapshot(
            enabled=True,
            interval_s=self._interval_s,
            withheld=self._withheld,
            last_ping_at=self._last_ping_at,
            last_error=self._last_error,
            pings_total=self._pings,
            failures_total=self._failures,
        )

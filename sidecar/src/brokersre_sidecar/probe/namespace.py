"""Detect that the gateway container restarted and left the sidecar in a dead namespace.

This module matters only in the OPTIONAL shared-namespace mode (``GATEWAY_HOST=127.0.0.1``
with ``network_mode: "service:ib-gateway"``). By default the sidecar has its own network
namespace and none of this can happen to it.

A container started with ``network_mode: "service:ib-gateway"`` joins the network namespace
the gateway container has at that moment. When the gateway CONTAINER restarts (a crash with
a restart policy, ``docker restart``, a host reboot), Docker gives it a new namespace; the
sidecar stays in the old one, where nothing listens any more and no port is published
(verified on Docker 29: loopback connects are refused and ``/proc/net/tcp`` is empty). From
then on the probe can never succeed, the sidecar's own endpoints are unreachable and no
notification can leave.

The only cure is to restart the sidecar, so that it joins the new namespace. The sidecar
does that itself by exiting; the container's restart policy brings it back. Nothing is done
to the gateway. (A restart of the Gateway PROCESS inside its container, such as IBC's daily
auto-restart, does not change the namespace and is not affected.)

The verdict needs positive evidence of a container restart, because "nothing listens" alone
also describes a healthy gateway that is between logins or waits for a person with its
command server off:

* the namespace had a foreign listener before (so a sidecar that never shared a namespace is
  left alone), and the gateway's boot id was known at that time;
* the gateway's boot id on the log volume has CHANGED since then: a new boot id is written
  only when the gateway container starts;
* no foreign listener is present now, and that stays so for a grace period;
* the gateway is alive according to its log volume (a stopped gateway has no namespace to
  rejoin).

A gateway that writes no boot ids therefore never triggers the exit.
"""

from __future__ import annotations

from collections.abc import Callable

from brokersre_sidecar.clock import Clock


class NamespaceWatch:
    """Decides whether the sidecar's network namespace has been orphaned. Single-threaded."""

    def __init__(
        self, clock: Clock, *, listeners: Callable[[], int | None], grace_s: float = 60.0
    ) -> None:
        """Create the watch.

        Args:
            clock: Monotonic time source.
            listeners: Returns the number of listening sockets that are not the sidecar's
                own, or None when the socket table cannot be read.
            grace_s: How long the evidence must hold before the verdict is "orphaned".
        """
        self._clock = clock
        self._listeners = listeners
        self._grace_s = grace_s
        self._seen_shared = False
        self._boot_when_shared: str | None = None
        self._last_count: int | None = None
        self._last_boot: str | None = None
        self._orphan_since: float | None = None

    @property
    def seen_shared(self) -> bool:
        """True once a foreign listener was seen: the namespace is (or was) the gateway's."""
        return self._seen_shared

    @property
    def suspect(self) -> bool:
        """True while the last sample is evidence that this namespace is no longer the gateway's.

        That is: a foreign listener was seen earlier under a known boot id, the gateway's
        boot id is a different one now, and the last sample found no foreign listener. While
        this holds nothing can be delivered from here, so the caller pauses the alert ladder
        (the same conditions are announced after the rejoin, from the replayed feed).
        An unreadable socket table is no evidence: the verdict is then False.
        """
        return (
            self._seen_shared
            and self._last_count == 0
            and self._boot_when_shared is not None
            and self._last_boot is not None
            and self._last_boot != self._boot_when_shared
        )

    def observe(self, *, gateway_alive: bool, boot_id: str | None) -> bool:
        """Sample the socket table once and return True when the namespace is orphaned.

        Args:
            gateway_alive: Whether the gateway is running according to its log volume. A
                gateway that is stopped has no sockets either, and restarting the sidecar
                would not help.
            boot_id: The gateway's current boot id from its log volume, or None when it is
                not known.

        Returns:
            True when the evidence described in the module docstring has held for the grace
            period. The caller then exits so that the restart policy rejoins the gateway.
        """
        count = self._listeners()
        self._last_count = count
        self._last_boot = boot_id
        if count is not None and count > 0:
            self._seen_shared = True
            if boot_id is not None:
                self._boot_when_shared = boot_id
        if not self.suspect or not gateway_alive:
            self._orphan_since = None
            return False
        now = self._clock.monotonic()
        if self._orphan_since is None:
            self._orphan_since = now
        return now - self._orphan_since >= self._grace_s

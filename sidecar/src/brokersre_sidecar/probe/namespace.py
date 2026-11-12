"""Detect that the gateway container restarted and left the sidecar in a dead namespace.

A container started with ``network_mode: "service:ib-gateway"`` joins the network namespace
the gateway container has at that moment. When the gateway CONTAINER restarts (a crash with
a restart policy, ``docker restart``, a host reboot), Docker gives it a new namespace; the
sidecar stays in the old one, where nothing listens any more and no port is published
(verified on Docker 29: loopback connects are refused and ``/proc/net/tcp`` is empty). From
then on the probe can never succeed and the sidecar's own endpoints are unreachable.

The only cure is to restart the sidecar, so that it joins the new namespace. The sidecar
does that itself by exiting; the container's restart policy brings it back. Nothing is done
to the gateway. (A restart of the Gateway PROCESS inside its container, such as IBC's daily
auto-restart, does not change the namespace and is not affected.)

The verdict is deliberately conservative: the namespace must have had a foreign listener
before (so a sidecar that never shared a namespace is left alone), the gateway must be alive
according to its log volume, and the listeners must stay gone for a grace period.
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
            grace_s: How long the listeners must stay gone before the verdict is "orphaned"
                (a restarting gateway process re-opens its sockets within seconds).
        """
        self._clock = clock
        self._listeners = listeners
        self._grace_s = grace_s
        self._seen_shared = False
        self._empty_since: float | None = None

    @property
    def seen_shared(self) -> bool:
        """True once a foreign listener was seen: the namespace is the gateway's."""
        return self._seen_shared

    def observe(self, *, gateway_alive: bool) -> bool:
        """Sample the socket table once and return True when the namespace is orphaned.

        Args:
            gateway_alive: Whether the gateway is running according to its log volume. A
                gateway that is stopped has no sockets either, and restarting the sidecar
                would not help.
        """
        count = self._listeners()
        if count is None:
            self._empty_since = None
            return False
        if count > 0:
            self._seen_shared = True
            self._empty_since = None
            return False
        if not self._seen_shared or not gateway_alive:
            self._empty_since = None
            return False
        now = self._clock.monotonic()
        if self._empty_since is None:
            self._empty_since = now
        return now - self._empty_since >= self._grace_s

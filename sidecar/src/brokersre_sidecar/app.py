"""Application wiring: the ONLY module that connects the subsystems to one another.

``Application`` builds the model, the probe, the notifier and the HTTP server from the
settings and runs each as a supervised task:

========== =====================================================================
task       what it does (about once per ``tick_s``)
========== =====================================================================
follow     reads the gateway's phase file and feeds (file I/O in a worker thread)
probe      one step of the read-only API probe
http       serves /livez, /readyz, /status and /metrics
notify     evaluates the alert rules and queues due notifications
notify-<c> delivers the queue of channel <c> (one task per channel)
========== =====================================================================

The tasks share nothing but in-memory snapshots, so a subsystem that hangs or crashes
cannot stall another: a webhook that never answers blocks only its own ``notify-<c>`` task,
a stuck file system only ``follow``. The sidecar observes; it never sends anything to the
gateway except the probe's time request, and it restarts nothing.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import datetime
from pathlib import Path

import httpx

from brokersre_sidecar import __version__
from brokersre_sidecar.clock import Clock, Sleep, SystemClock
from brokersre_sidecar.config.settings import ChannelSecrets, Settings
from brokersre_sidecar.http import HttpServer, Response
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.metrics import CONTENT_TYPE, render_metrics
from brokersre_sidecar.model import (
    GatewayFeed,
    GatewaySnapshot,
    GatewayState,
    StatusDocument,
    build_status,
)
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot, TaskSnapshot
from brokersre_sidecar.notify import (
    Dispatcher,
    HttpTransport,
    LadderConfig,
    LadderEngine,
    MessageFactory,
    Notifier,
    NotifierStore,
    RuleConfig,
    RuleEngine,
    build_channels,
)
from brokersre_sidecar.probe import (
    IbClient,
    IbConnectError,
    IbDisconnectedError,
    NamespaceWatch,
    ProbeConfig,
    ProbeEngine,
    count_close_wait,
    count_foreign_listeners,
)
from brokersre_sidecar.redaction import SecretRegistry
from brokersre_sidecar.supervisor import Supervisor, TaskFactory
from brokersre_sidecar.vocab import Phase, ProbeStatus

_LOGGER = logging.getLogger(__name__)

STATE_FILE_NAME = "notifier-state.json"
# A read of three small local files; anything longer means the volume is stuck.
_FEED_READ_TIMEOUT_S = 10.0
# Time allowed at shutdown to deliver notifications that are already queued.
_FLUSH_TIMEOUT_S = 3.0
_TEXT = "text/plain; charset=utf-8"

EXIT_ORPHANED = 75
"""Exit code (EX_TEMPFAIL) when the sidecar leaves a dead network namespace."""

_NAMESPACE_SAMPLE_S = 5.0
# A gateway in one of these phases is running (its feeds must also be fresh, if any).
_ALIVE_PHASES = frozenset(
    {
        Phase.STARTING,
        Phase.LOGIN,
        Phase.TWOFA_PENDING,
        Phase.LOGGED_IN,
        Phase.RESTARTING,
        Phase.EXISTING_SESSION,
        Phase.NEEDS_HUMAN,
    }
)
_FEED_FRESH_S = 120.0
# Statuses that are logged at info level; the others are warnings.
_CALM_STATUSES = frozenset({ProbeStatus.READY, ProbeStatus.NOT_MEASURED})

_NOTIFIER_DISABLED = NotifierSnapshot(
    enabled=False,
    channels=(),
    active_alerts=(),
    state_persistence="disabled",
    state_persistence_reason=None,
)


class _NoClient:
    """Stand-in ``IbClient`` for a disabled probe: never connected, refuses to connect."""

    def set_error_listener(self, listener: object) -> None:
        """Accept and ignore the listener; no notice can ever arrive."""

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Refuse: the probe is disabled."""
        raise IbConnectError("probe disabled")

    async def current_time(self, timeout_s: float) -> datetime:
        """Refuse: the probe is disabled."""
        raise IbDisconnectedError("probe disabled")

    def is_connected(self) -> bool:
        """Never connected."""
        return False

    def disconnect(self) -> None:
        """Nothing to close."""


def _default_ib_client(enabled: bool) -> IbClient:
    """Return the ib_async-backed client, or a stand-in when the probe is disabled.

    The adapter is imported here, lazily, so that commands which do not probe (and a
    sidecar with ``PROBE_ENABLED=no``) never load ib_async.
    """
    if not enabled:
        return _NoClient()
    from brokersre_sidecar.probe.adapter import IbAsyncClient

    return IbAsyncClient()


class Application:
    """The running sidecar. Construct once, then ``await run(stop)``."""

    def __init__(
        self,
        settings: Settings,
        secrets: ChannelSecrets,
        registry: SecretRegistry,
        *,
        clock: Clock | None = None,
        sleep: Sleep = asyncio.sleep,
        ib_client: IbClient | None = None,
        http_client: httpx.AsyncClient | None = None,
        proc_root: Path = Path("/proc"),
        tick_s: float = 1.0,
    ) -> None:
        """Build every subsystem; nothing runs and no socket is opened yet.

        Args:
            settings: Validated configuration.
            secrets: Channel credentials (all None when the notifier is not configured).
            registry: Secrets to scrub from messages.
            clock: Time source (the system clock by default).
            sleep: Awaitable delay of the task loops and retries.
            ib_client: API client for the probe (the ib_async adapter by default).
            http_client: Outbound HTTP client of the notifier (created when needed).
            proc_root: procfs mount point, for the CLOSE_WAIT count.
            tick_s: Period of the follow, probe and notify loops.
        """
        self._settings = settings
        self._clock: Clock = clock if clock is not None else SystemClock()
        self._sleep = sleep
        self._tick_s = tick_s
        self._state = GatewayState(self._clock)
        self.feed = GatewayFeed(settings.log_dir, self._state)
        """The gateway feed (public so a test can make it fail)."""
        self._feed_ready = False
        self._last_phase: str | None = None
        self._last_status: ProbeStatus | None = None

        self._engine = ProbeEngine(
            ProbeConfig(
                enabled=settings.probe_enabled,
                port=settings.api_port,
                client_id=settings.health_client_id,
                interval_s=settings.probe_interval_s,
                timeout_s=settings.probe_timeout_s,
            ),
            ib_client if ib_client is not None else _default_ib_client(settings.probe_enabled),
            self._clock,
            phase=lambda: self._state.phase,
            close_wait=lambda: count_close_wait(settings.api_port, proc_root),
        )

        self._watch = (
            NamespaceWatch(
                self._clock,
                listeners=lambda: count_foreign_listeners(settings.port, proc_root),
            )
            if settings.exit_when_orphaned
            else None
        )
        self._watch_sampled_at: float | None = None
        self._orphaned = asyncio.Event()
        self.shares_network_namespace = False
        """True once another listener (the gateway's) was seen in this namespace."""
        self.exit_code = 0
        """Exit code after ``run`` returned (75 after leaving an orphaned namespace)."""

        self._supervisor = Supervisor(self._clock, sleep)
        self._supervisor.add("follow", self._follow)
        self._supervisor.add("probe", self._probe)
        self._supervisor.add("http", self._serve_http)

        self._transport: HttpTransport | None = None
        self._dispatcher: Dispatcher | None = None
        self._notifier: Notifier | None = None
        if settings.configured_channels():
            self._build_notifier(settings, secrets, registry, http_client)

        self._server = HttpServer(
            {
                "/livez": self._livez,
                "/readyz": self._readyz,
                "/status": self._status,
                "/metrics": self._metrics,
            },
            host=settings.bind,
            port=settings.port,
        )

    def _build_notifier(
        self,
        settings: Settings,
        secrets: ChannelSecrets,
        registry: SecretRegistry,
        http_client: httpx.AsyncClient | None,
    ) -> None:
        """Create the notifier, its dispatcher and one delivery task per channel."""
        client = (
            http_client
            if http_client is not None
            else httpx.AsyncClient(
                follow_redirects=False,
                limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
                headers={"User-Agent": f"brokersre-sidecar/{__version__}"},
            )
        )
        self._transport = HttpTransport(client)
        channels = build_channels(settings, secrets, self._transport)
        self._dispatcher = Dispatcher(channels, self._clock, self._sleep)
        self._notifier = Notifier(
            rules=RuleEngine(RuleConfig(login_stall_s=settings.login_stall_s)),
            ladder=LadderEngine(
                LadderConfig(
                    primary_channels=settings.primary_channels(),
                    escalation_channels=settings.escalation_channels(),
                    escalate_after_s=settings.escalate_after_s,
                    escalate_again_after_s=settings.escalate_again_after_s,
                    heartbeat_time=settings.heartbeat_time,
                    time_zone=settings.time_zone,
                    disabled_classes=settings.disabled_classes,
                )
            ),
            factory=MessageFactory(
                settings.instance, settings.time_zone, settings.runbook_base, registry
            ),
            dispatcher=self._dispatcher,
            store=NotifierStore(settings.state_dir / STATE_FILE_NAME),
            clock=self._clock,
            gateway=self._state.snapshot,
            probe=self._engine.snapshot,
            volume_present=lambda: self.feed.volume_present,
            ready=lambda: self._feed_ready,
        )
        self._supervisor.add("notify", self._notify)
        for name in self._dispatcher.channel_names():
            self._supervisor.add(f"notify-{name}", self._channel_worker(name))

    def _channel_worker(self, name: str) -> TaskFactory:
        """Return the task factory that delivers the queue of channel ``name``."""
        dispatcher = self._dispatcher
        assert dispatcher is not None  # noqa: S101 - only called from _build_notifier

        async def worker() -> None:
            await dispatcher.run_channel(name)

        return worker

    @property
    def http_listening(self) -> bool:
        """True while the HTTP server is bound."""
        return self._server.listening

    def gateway_snapshot(self) -> GatewaySnapshot:
        """Return the current gateway snapshot."""
        return self._state.snapshot()

    def probe_snapshot(self) -> ProbeSnapshot:
        """Return the current probe snapshot."""
        return self._engine.snapshot()

    def notifier_snapshot(self) -> NotifierSnapshot:
        """Return the notifier snapshot (``enabled=False`` when no channel is configured)."""
        return self._notifier.snapshot() if self._notifier is not None else _NOTIFIER_DISABLED

    def task_snapshot(self) -> tuple[TaskSnapshot, ...]:
        """Return the supervision records."""
        return self._supervisor.snapshot()

    def status_document(self) -> StatusDocument:
        """Build the ``/status`` document from the current snapshots."""
        return build_status(
            instance=self._settings.instance,
            trading_mode=self._settings.trading_mode,
            gateway=self._state.snapshot(),
            probe=self._engine.snapshot(),
            notifier=self.notifier_snapshot(),
            tasks=self._supervisor.snapshot(),
            volume_present=self.feed.volume_present,
            now=self._clock.now(),
        )

    async def run(self, stop: asyncio.Event) -> None:
        """Run until ``stop`` is set, then shut down gracefully (within a few seconds).

        Side effects:
            Binds the HTTP port, reads the log volume, opens the probe connection while the
            gateway is logged in, sends notifications, writes the notifier state file.
        """
        if self._notifier is not None:
            self._notifier.load_state()
        log_event(
            _LOGGER,
            logging.INFO,
            "sidecar_started",
            version=__version__,
            instance=self._settings.instance,
            trading_mode=self._settings.trading_mode,
            probe_enabled=self._settings.probe_enabled,
            channels=list(self._settings.configured_channels()),
        )
        waiters = {
            asyncio.ensure_future(self._supervisor.run()),
            asyncio.ensure_future(stop.wait()),
            asyncio.ensure_future(self._orphaned.wait()),
        }
        try:
            await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for waiter in waiters:
                waiter.cancel()
            await asyncio.gather(*waiters, return_exceptions=True)
            await self._shutdown()
        log_event(_LOGGER, logging.INFO, "sidecar_stopped")

    async def _follow(self) -> None:
        """Read the gateway's files in a worker thread and apply them to the model."""
        while True:
            batch = await asyncio.wait_for(asyncio.to_thread(self.feed.read), _FEED_READ_TIMEOUT_S)
            self.feed.apply(batch)
            self._feed_ready = True
            phase = self._state.phase
            if phase != self._last_phase:
                self._last_phase = phase
                log_event(_LOGGER, logging.INFO, "phase_changed", phase=phase or "not_measured")
            await self._sleep(self._tick_s)

    def _gateway_alive(self) -> bool:
        """Report whether the gateway is running according to its log volume."""
        snapshot = self._state.snapshot()
        if snapshot.phase not in _ALIVE_PHASES:
            return False
        if not snapshot.feeds_seen or snapshot.last_activity_at is None:
            return True  # a gateway without the v2 feeds: the phase is all there is
        quiet = (snapshot.taken_at - snapshot.last_activity_at).total_seconds()
        return quiet <= _FEED_FRESH_S

    def _check_namespace(self) -> None:
        """Stop the sidecar when its network namespace no longer contains the gateway.

        See ``probe.namespace``: after the gateway CONTAINER restarts, this sidecar sits
        in the old namespace for good. It exits with ``EXIT_ORPHANED`` so that the
        container's restart policy starts it again inside the gateway's new namespace.
        The gateway itself is never touched.
        """
        if self._watch is None:
            return
        now = self._clock.monotonic()
        if (
            self._watch_sampled_at is not None
            and now - self._watch_sampled_at < _NAMESPACE_SAMPLE_S
        ):
            return
        self._watch_sampled_at = now
        orphaned = self._watch.observe(gateway_alive=self._gateway_alive())
        self.shares_network_namespace = self._watch.seen_shared
        if orphaned and not self._orphaned.is_set():
            self.exit_code = EXIT_ORPHANED
            log_event(
                _LOGGER,
                logging.ERROR,
                "network_namespace_orphaned",
                "the gateway container restarted and this sidecar is left in its old "
                "network namespace; exiting so the restart policy starts it in the new one",
                exit_code=EXIT_ORPHANED,
            )
            self._orphaned.set()

    async def _probe(self) -> None:
        """Step the API probe and log status changes."""
        while True:
            self._check_namespace()
            await self._engine.tick()
            snapshot = self._engine.snapshot()
            if snapshot.status is not self._last_status:
                self._last_status = snapshot.status
                log_event(
                    _LOGGER,
                    logging.INFO if snapshot.status in _CALM_STATUSES else logging.WARNING,
                    "api_status_changed",
                    snapshot.reason,
                    status=snapshot.status.value,
                )
            await self._sleep(self._tick_s)

    async def _notify(self) -> None:
        """Evaluate the alert rules and queue due notifications."""
        notifier = self._notifier
        assert notifier is not None  # noqa: S101 - registered only when configured
        while True:
            await notifier.tick()
            await self._sleep(self._tick_s)

    async def _serve_http(self) -> None:
        """Serve the endpoints; release the port when the task stops."""
        try:
            await self._server.serve_forever()
        finally:
            await self._server.close()

    async def _shutdown(self) -> None:
        """Release everything: API connection, HTTP port, queued notifications, HTTP client."""
        self._engine.shutdown()
        await self._server.close()
        if self._dispatcher is not None:
            pending = [
                self._dispatcher.deliver_pending(name) for name in self._dispatcher.channel_names()
            ]
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(
                    asyncio.gather(*pending, return_exceptions=True), _FLUSH_TIMEOUT_S
                )
        if self._transport is not None:
            await self._transport.aclose()

    def _livez(self) -> Response:
        """200 while the supervisor is running its tasks."""
        if self._supervisor.alive():
            return Response(200, _TEXT, b"ok\n")
        return Response(503, _TEXT, b"the supervisor is not running\n")

    def _readyz(self) -> Response:
        """200 only when the API probe is ready; otherwise 503 and a one-line reason."""
        snapshot = self._engine.snapshot()
        if snapshot.status is ProbeStatus.READY:
            return Response(200, _TEXT, b"ready\n")
        return Response(503, _TEXT, f"{snapshot.status.value}: {snapshot.reason}\n".encode())

    def _status(self) -> Response:
        """The versioned status document as JSON."""
        body = self.status_document().model_dump_json(by_alias=True)
        return Response(200, "application/json", body.encode() + b"\n")

    def _metrics(self) -> Response:
        """The Prometheus exposition."""
        text = render_metrics(
            gateway=self._state.snapshot(),
            probe=self._engine.snapshot(),
            notifier=self.notifier_snapshot(),
            tasks=self._supervisor.snapshot(),
        )
        return Response(200, CONTENT_TYPE, text.encode())

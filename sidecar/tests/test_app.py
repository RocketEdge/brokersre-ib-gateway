"""The wired application: four isolated subsystems behind real HTTP on loopback."""

from __future__ import annotations

import asyncio
import contextlib
import json
import re
import threading
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import httpx
import jsonschema
import pytest

from brokersre_sidecar.app import Application
from brokersre_sidecar.config import load_secrets, load_settings
from brokersre_sidecar.redaction import SecretRegistry
from fakes.fake_ib import FakeIb
from testkit import T0, FakeClock, free_port, http_get, iso, replace_file, until

SCHEMA_FILE = Path(__file__).resolve().parents[1] / "schemas" / "status.v1.schema.json"
WEBHOOK_URL = "https://hooks.example.com/CANARY_WEBHOOK_PATH"


class Volume:
    """A directory that imitates the gateway's log volume."""

    def __init__(self, root: Path) -> None:
        self.root = root
        for name in ("state", "events", "metrics"):
            (root / name).mkdir(parents=True)
        self._seq = 0

    def phase(self, token: str) -> None:
        """Write the phase atomically (temporary file + rename), as the gateway does."""
        temporary = self.root / "state" / "phase.tmp"
        temporary.write_bytes(f"{token}\n".encode())
        replace_file(temporary, self.root / "state" / "phase")

    def event(self, name: str, boot: str = "00000000000000aa") -> None:
        self._seq += 1
        line = {
            "ts": iso(T0),
            "src": "ibc",
            "level": "info",
            "event": name,
            "msg": "CANARY_USERNAME DU7654321",
            "boot_id": boot,
            "seq": self._seq,
        }
        with open(self.root / "events" / "events.jsonl", "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(line) + "\n")

    def metrics(self, **values: float) -> None:
        self._seq += 1
        line = {"ts": iso(T0), "src": "metrics", "boot_id": "00000000000000aa", "seq": self._seq}
        with open(
            self.root / "metrics" / "metrics.jsonl", "a", encoding="utf-8", newline="\n"
        ) as f:
            f.write(json.dumps(line | values) + "\n")


class Harness:
    """A running application with its surroundings."""

    def __init__(
        self,
        tmp_path: Path,
        env: dict[str, str],
        *,
        webhook: bool,
        proc_root: Path | None = None,
        feed_read_timeout_s: float = 10.0,
    ) -> None:
        self.volume = Volume(tmp_path / "volume")
        self.clock = FakeClock()
        self.ib = FakeIb(self.clock)
        self.received: list[dict[str, Any]] = []
        self.webhook_status = 200
        self.port = free_port()
        full_env = {
            "GATEWAY_LOG_DIR": str(self.volume.root),
            "SIDECAR_STATE_DIR": str(tmp_path / "state"),
            "SIDECAR_BIND": "127.0.0.1",
            "SIDECAR_PORT": str(self.port),
            "IBGW_INSTANCE": "desk-1",
        }
        (tmp_path / "state").mkdir()
        if webhook:
            secret = tmp_path / "webhook-url"
            secret.write_text(WEBHOOK_URL, encoding="utf-8")
            full_env["NOTIFY_WEBHOOK_URL_FILE"] = str(secret)
        full_env |= env
        settings = load_settings(full_env)
        registry = SecretRegistry()
        self.app = Application(
            settings,
            load_secrets(settings, registry),
            registry,
            clock=self.clock,
            ib_client=self.ib,
            http_client=httpx.AsyncClient(transport=httpx.MockTransport(self._receive)),
            proc_root=proc_root if proc_root is not None else tmp_path / "no-proc",
            tick_s=0.005,
            feed_read_timeout_s=feed_read_timeout_s,
        )
        self.stop = asyncio.Event()
        self.task: asyncio.Task[None] | None = None

    def _receive(self, request: httpx.Request) -> httpx.Response:
        assert str(request.url) == WEBHOOK_URL
        self.received.append(json.loads(request.content))
        return httpx.Response(self.webhook_status)

    async def start(self) -> None:
        self.task = asyncio.ensure_future(self.app.run(self.stop))
        await until(lambda: self.app.http_listening)

    async def shutdown(self) -> None:
        self.stop.set()
        if self.task is not None:
            await asyncio.wait_for(self.task, 10)

    async def get(self, path: str) -> tuple[int, dict[str, str], bytes]:
        return await http_get(self.port, path)

    async def status(self) -> dict[str, Any]:
        _, _, body = await self.get("/status")
        document: dict[str, Any] = json.loads(body)
        return document

    def kinds(self) -> list[tuple[str, str]]:
        return [(message["class"], message["kind"]) for message in self.received]


@contextlib.asynccontextmanager
async def running(
    tmp_path: Path, *, webhook: bool = True, proc_root: Path | None = None, **env: str
) -> AsyncIterator[Harness]:
    harness = Harness(tmp_path, env, webhook=webhook, proc_root=proc_root)
    try:
        # Inside the try: a start that fails must not leave the application running.
        await harness.start()
        yield harness
    finally:
        await harness.shutdown()


async def test_before_login_the_sidecar_is_live_not_ready_and_says_not_measured(
    tmp_path: Path,
) -> None:
    async with running(tmp_path) as h:
        h.volume.phase("starting")
        await until(lambda: h.app.gateway_snapshot().phase == "starting")
        status, _, body = await h.get("/livez")
        assert (status, body) == (200, b"ok\n")
        status, _, body = await h.get("/readyz")
        assert status == 503
        assert body.startswith(b"not_measured: gateway phase is starting")
        document = await h.status()
        schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(document)
        assert document["phase"] == "starting"
        assert document["status"] == "not_measured"
        assert document["instance"] == "desk-1"
        assert document["notifier"]["enabled"] is True
        assert [task["name"] for task in document["tasks"]] == [
            "follow",
            "probe",
            "http",
            "notify",
            "notify-webhook",
        ]
        assert all(task["state"] == "running" for task in document["tasks"])
        status, headers, body = await h.get("/metrics")
        assert status == 200
        assert headers["content-type"] == "text/plain; version=0.0.4; charset=utf-8"
        text = body.decode()
        assert 'ibgw_phase{phase="starting"} 1' in text
        assert "ibgw_api_ready" not in text
        assert h.ib.connect_calls == 0


async def test_two_factor_pending_reaches_the_webhook_and_login_resolves_it(
    tmp_path: Path,
) -> None:
    async with running(tmp_path) as h:
        h.volume.phase("login")
        h.volume.event("twofa_initiated")
        h.volume.phase("2fa-pending")
        await until(lambda: len(h.received) >= 1)
        first = h.received[0]
        assert (first["class"], first["kind"], first["severity"]) == (
            "twofa_pending",
            "firing",
            "critical",
        )
        assert first["instance"] == "desk-1"
        assert first["phase"] == "2fa-pending"
        assert first["instruction"].startswith("Approve the IBKR Mobile prompt now")
        assert (await h.status())["notifier"]["active_alerts"][0]["class"] == "twofa_pending"

        h.volume.event("login_completed")
        h.volume.phase("logged-in")
        await until(lambda: len(h.received) >= 2)
        assert h.kinds() == [("twofa_pending", "firing"), ("twofa_pending", "resolved")]
        await until(lambda: h.ib.time_calls >= 1)
        status, _, body = await h.get("/readyz")
        assert (status, body) == (200, b"ready\n")
        document = await h.status()
        assert document["status"] == "ready"
        assert document["last_login"] == iso(T0)
        assert document["notifier"]["channels"][0]["sent_total"] == 2
        assert h.ib.connect_args == ("ib-gateway", 4004, 999, 10.0)
        text = (await h.get("/metrics"))[2].decode()
        assert "ibgw_api_ready 1" in text
        assert 'ibgw_notify_failures_total{channel="webhook"} 0' in text
        assert "CANARY" not in json.dumps(h.received)
        assert "DU7654321" not in json.dumps(h.received) + json.dumps(document)


async def test_a_failing_webhook_is_visible_and_stalls_nothing_else(tmp_path: Path) -> None:
    async with running(tmp_path) as h:
        h.webhook_status = 401  # final: no retries
        h.volume.phase("needs-human")
        await until(lambda: len(h.received) >= 1)
        await until(lambda: h.app.notifier_snapshot().channels[0].failures_total == 1)
        channel = (await h.status())["notifier"]["channels"][0]
        assert (channel["failures_total"], channel["last_error"]) == (1, "http_401")
        assert WEBHOOK_URL not in json.dumps(await h.status())
        text = (await h.get("/metrics"))[2].decode()
        assert 'ibgw_notify_failures_total{channel="webhook"} 1' in text
        assert (await h.get("/livez"))[0] == 200


async def test_a_crashing_subsystem_is_recorded_and_the_others_keep_working(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with running(tmp_path) as h:
        h.volume.phase("logged-in")
        await until(lambda: h.ib.time_calls >= 1)

        def broken_read() -> None:
            raise RuntimeError("disk on fire CANARY")

        monkeypatch.setattr(h.app.feed, "read", broken_read)
        await until(lambda: h.app.task_snapshot()[0].restarts >= 1)
        document = await h.status()
        follow = document["tasks"][0]
        assert (follow["name"], follow["last_error"]) == ("follow", "RuntimeError")
        assert follow["restarts"] >= 1
        assert "CANARY" not in json.dumps(document)
        assert (await h.get("/livez"))[0] == 200
        assert (await h.get("/readyz"))[0] == 200
        assert re.search(
            r'ibgw_sidecar_task_restarts_total\{task="follow"\} [1-9]',
            (await h.get("/metrics"))[2].decode(),
        )


async def test_without_a_channel_the_notifier_does_not_run(tmp_path: Path) -> None:
    async with running(tmp_path, webhook=False) as h:
        h.volume.phase("2fa-pending")
        await until(lambda: h.app.gateway_snapshot().phase == "2fa-pending")
        document = await h.status()
        assert document["notifier"] == {
            "enabled": False,
            "channels": [],
            "active_alerts": [],
            "state_persistence": "disabled",
            "state_persistence_reason": None,
        }
        assert [task["name"] for task in document["tasks"]] == ["follow", "probe", "http"]


async def test_a_disabled_probe_never_touches_the_gateway(tmp_path: Path) -> None:
    async with running(tmp_path, PROBE_ENABLED="no") as h:
        h.volume.phase("logged-in")
        await until(lambda: h.app.gateway_snapshot().phase == "logged-in")
        status, _, body = await h.get("/readyz")
        assert status == 503
        assert b"PROBE_ENABLED=no" in body
        assert h.ib.connect_calls == 0


async def test_live_mode_probes_port_4001_with_the_configured_client_id(tmp_path: Path) -> None:
    async with running(tmp_path, TRADING_MODE="live", HEALTH_CLIENT_ID="998") as h:
        h.volume.phase("logged-in")
        await until(lambda: h.ib.connect_calls >= 1)
        assert h.ib.connect_args == ("ib-gateway", 4003, 998, 10.0)
        assert (await h.status())["trading_mode"] == "live"


async def test_gateway_metrics_are_re_exported(tmp_path: Path) -> None:
    async with running(tmp_path) as h:
        h.volume.phase("logged-in")
        h.volume.metrics(pids=41, mem_working_set_bytes=1000, mem_limit_bytes=4000)
        await until(lambda: h.app.gateway_snapshot().last_metrics is not None)
        text = (await h.get("/metrics"))[2].decode()
        assert "ibgw_pids 41" in text
        assert "ibgw_memory_working_set_bytes 1000" in text
        assert "ibgw_open_fds" not in text


async def test_stopping_is_graceful_disconnects_the_probe_and_frees_the_port(
    tmp_path: Path,
) -> None:
    harness = Harness(tmp_path, {}, webhook=True)
    await harness.start()
    harness.volume.phase("logged-in")
    await until(lambda: harness.ib.is_connected())
    await harness.shutdown()
    assert harness.ib.is_connected() is False
    assert harness.app.http_listening is False
    with pytest.raises(OSError):  # noqa: PT011 - any refusal: nothing listens any more
        await asyncio.open_connection("127.0.0.1", harness.port)


async def test_a_notification_queued_just_before_stopping_is_still_delivered(
    tmp_path: Path,
) -> None:
    harness = Harness(tmp_path, {}, webhook=True)
    await harness.start()
    harness.volume.phase("2fa-pending")
    await until(lambda: len(harness.app.notifier_snapshot().active_alerts) == 1)
    await harness.shutdown()
    assert harness.kinds() == [("twofa_pending", "firing")]


TCP_HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"


def write_socket_table(proc_root: Path, ports: list[int]) -> None:
    """Write a /proc/net/tcp with one listening socket per port."""
    (proc_root / "net").mkdir(parents=True, exist_ok=True)
    rows = "".join(
        f"   0: 00000000:{port:04X} 00000000:0000 0A 00000000:00000000 00:00000000 00000000"
        "  1000        0 1 1 0000000000000000 100 0 0 10 0\n"
        for port in ports
    )
    temporary = proc_root / "net" / "tcp.tmp"
    temporary.write_text(TCP_HEADER + rows, encoding="ascii")
    replace_file(temporary, proc_root / "net" / "tcp")


LOOPBACK = "127.0.0.1"  # GATEWAY_HOST of the shared-namespace mode


async def let_time_pass(harness: Harness, seconds: int) -> None:
    """Advance the fake clock second by second while the application keeps running."""
    for _ in range(seconds):
        harness.clock.advance(1.0)
        await asyncio.sleep(0.01)


async def test_in_the_shared_namespace_the_probe_uses_loopback_and_the_api_port(
    tmp_path: Path,
) -> None:
    async with running(tmp_path, GATEWAY_HOST=LOOPBACK) as h:
        h.volume.phase("logged-in")
        await until(lambda: h.ib.connect_calls >= 1)
        assert h.ib.connect_args == ("127.0.0.1", 4002, 999, 10.0)
        assert (await h.status())["network_mode"] == "shared_namespace"


async def test_with_its_own_network_the_mode_is_reported_and_proc_is_not_consulted(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    write_socket_table(proc_root, [4004])
    async with running(tmp_path, proc_root=proc_root) as h:
        h.volume.phase("logged-in")
        h.volume.event("container_start")
        h.volume.metrics(api_close_wait_sockets=7)
        await until(lambda: h.app.gateway_snapshot().last_metrics is not None)
        await let_time_pass(h, 6)
        assert h.app.probe_snapshot().close_wait_sockets == 7
        document = await h.status()
        assert document["network_mode"] == "own_network"
        assert document["close_wait_sockets"] == 7  # the gateway's own measurement
        # A gateway restart seen on the volume, no listener in this namespace: irrelevant.
        write_socket_table(proc_root, [])
        h.volume.event("container_start", boot="00000000000000bb")
        await let_time_pass(h, 70)
        assert h.task is not None
        assert not h.task.done()
        assert h.app.shares_network_namespace is False


async def test_a_sidecar_left_in_a_dead_network_namespace_exits_so_it_is_restarted(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    write_socket_table(proc_root, [4004, 7462])  # the gateway's listeners
    async with running(tmp_path, proc_root=proc_root, GATEWAY_HOST=LOOPBACK) as h:
        h.volume.event("container_start")
        h.volume.phase("logged-in")
        await until(lambda: h.app.shares_network_namespace)
        await let_time_pass(h, 6)
        assert h.app.exit_code == 0
        sent_before = len(h.received)

        # The gateway container restarts: a new boot id on the volume, and its sockets are
        # gone from this namespace for good.
        write_socket_table(proc_root, [])
        h.volume.event("container_start", boot="00000000000000bb")
        await let_time_pass(h, 6)
        await until(lambda: h.app.namespace_suspect)
        # What happens now cannot be announced from here; it is announced after the rejoin.
        h.volume.phase("2fa-pending")
        await let_time_pass(h, 70)
        assert h.task is not None
        await asyncio.wait_for(h.task, 5)  # the application stopped by itself
        assert h.app.exit_code == 75
        assert h.app.http_listening is False
        # Nothing was announced from the dead namespace: nobody could have received it.
        assert len(h.received) == sent_before


async def test_no_listener_without_a_gateway_restart_does_not_make_the_sidecar_exit(
    tmp_path: Path,
) -> None:
    proc_root = tmp_path / "proc"
    write_socket_table(proc_root, [4004])
    async with running(tmp_path, webhook=False, proc_root=proc_root, GATEWAY_HOST=LOOPBACK) as h:
        h.volume.event("container_start")
        h.volume.phase("login")
        await until(lambda: h.app.shares_network_namespace)
        await let_time_pass(h, 6)
        # needs-human with the command server off: the gateway listens on nothing.
        write_socket_table(proc_root, [])
        h.volume.phase("needs-human")
        await let_time_pass(h, 90)
        assert h.task is not None
        assert not h.task.done()
        assert h.app.exit_code == 0


async def test_a_stopped_gateway_does_not_make_the_sidecar_exit(tmp_path: Path) -> None:
    proc_root = tmp_path / "proc"
    write_socket_table(proc_root, [4004])
    async with running(tmp_path, webhook=False, proc_root=proc_root, GATEWAY_HOST=LOOPBACK) as h:
        h.volume.event("container_start")
        h.volume.phase("logged-in")
        await until(lambda: h.app.shares_network_namespace)
        await let_time_pass(h, 6)
        write_socket_table(proc_root, [])
        h.volume.event("container_start", boot="00000000000000bb")
        h.volume.phase("stopped")
        await until(lambda: h.app.gateway_snapshot().phase == "stopped")
        await let_time_pass(h, 70)
        assert h.task is not None
        assert not h.task.done()
        assert h.app.exit_code == 0


async def test_exiting_when_orphaned_can_be_switched_off(tmp_path: Path) -> None:
    proc_root = tmp_path / "proc"
    write_socket_table(proc_root, [4004])
    async with running(
        tmp_path, webhook=False, proc_root=proc_root, GATEWAY_HOST=LOOPBACK, EXIT_WHEN_ORPHANED="no"
    ) as h:
        h.volume.event("container_start")
        h.volume.phase("logged-in")
        await until(lambda: h.app.gateway_snapshot().phase == "logged-in")
        await let_time_pass(h, 6)
        write_socket_table(proc_root, [])
        h.volume.event("container_start", boot="00000000000000bb")
        await let_time_pass(h, 70)
        assert h.task is not None
        assert not h.task.done()


async def test_a_stuck_volume_read_is_waited_for_and_never_started_twice(tmp_path: Path) -> None:
    harness = Harness(tmp_path, {}, webhook=False, feed_read_timeout_s=0.05)
    release = threading.Event()
    calls: list[str] = []
    real_read = harness.app.feed.read
    stuck = False

    def read() -> Any:
        if stuck:
            calls.append("stuck")
            release.wait(20)
        return real_read()

    harness.app.feed.read = read  # type: ignore[method-assign]
    try:
        await harness.start()
        harness.volume.phase("logged-in")
        await until(lambda: harness.app.gateway_snapshot().phase == "logged-in")
        stuck = True
        # The read hangs: the sidecar says that it cannot see the gateway...
        await until(lambda: harness.app.gateway_snapshot().phase is None)
        assert (await harness.status())["phase"] is None
        # ...and keeps waiting for that one read through many timeouts.
        await asyncio.sleep(0.4)
        assert calls == ["stuck"]
        follow = harness.app.task_snapshot()[0]
        assert (follow.name, follow.state, follow.restarts) == ("follow", "running", 0)
        # What was written meanwhile is not lost when the read returns.
        harness.volume.phase("2fa-pending")
        harness.volume.event("twofa_initiated")
        stuck = False
        release.set()
        await until(lambda: harness.app.gateway_snapshot().phase == "2fa-pending")
        assert "twofa_initiated" in harness.app.gateway_snapshot().last_events
    finally:
        release.set()
        await harness.shutdown()


async def test_a_task_without_progress_fails_livez_and_is_visible(tmp_path: Path) -> None:
    harness = Harness(tmp_path, {}, webhook=False, feed_read_timeout_s=0.05)
    release = threading.Event()
    real_read = harness.app.feed.read
    stuck = False

    def read() -> Any:
        if stuck:
            release.wait(20)
        return real_read()

    harness.app.feed.read = read  # type: ignore[method-assign]
    try:
        await harness.start()
        harness.volume.phase("starting")
        await until(lambda: harness.app.gateway_snapshot().phase == "starting")
        assert (await harness.get("/livez"))[:1] == (200,)
        stuck = True
        await until(lambda: harness.app.gateway_snapshot().phase is None)
        # A minute and a half without one completed read of the volume.
        await let_time_pass(harness, 90)
        status, _, body = await harness.get("/livez")
        assert status == 503
        assert re.fullmatch(rb"no progress: follow \(\d+ s\)\n", body), body
        tasks = {task["name"]: task for task in (await harness.status())["tasks"]}
        assert tasks["follow"]["stalled"] is True
        assert tasks["follow"]["progress_age_s"] >= 90
        assert tasks["probe"]["stalled"] is False
        assert tasks["http"]["progress_age_s"] is None
        text = (await harness.get("/metrics"))[2].decode()
        assert 'ibgw_sidecar_task_stalled{task="follow"} 1' in text
        assert 'ibgw_sidecar_task_stalled{task="probe"} 0' in text
        assert re.search(r'ibgw_sidecar_task_progress_age_seconds\{task="follow"\} \d', text)
        stuck = False
        release.set()
        await until(lambda: harness.app.gateway_snapshot().phase == "starting")
        assert (await harness.get("/livez"))[0] == 200
    finally:
        release.set()
        await harness.shutdown()

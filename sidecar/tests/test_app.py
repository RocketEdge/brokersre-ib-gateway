"""The wired application: four isolated subsystems behind real HTTP on loopback."""

from __future__ import annotations

import asyncio
import contextlib
import json
import re
import time
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
from testkit import T0, FakeClock, free_port, http_get, iso, until

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
        for _ in range(200):
            try:
                temporary.replace(self.root / "state" / "phase")
                return
            except PermissionError:
                # Windows only: the rename is refused while the sidecar's reader has the
                # target open. A Linux rename over an open file always succeeds.
                time.sleep(0.005)
        raise AssertionError("could not replace the phase file")

    def event(self, name: str) -> None:
        self._seq += 1
        line = {
            "ts": iso(T0),
            "src": "ibc",
            "level": "info",
            "event": name,
            "msg": "CANARY_USERNAME DU7654321",
            "boot_id": "00000000000000aa",
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

    def __init__(self, tmp_path: Path, env: dict[str, str], *, webhook: bool) -> None:
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
            proc_root=tmp_path / "no-proc",
            tick_s=0.005,
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
async def running(tmp_path: Path, *, webhook: bool = True, **env: str) -> AsyncIterator[Harness]:
    harness = Harness(tmp_path, env, webhook=webhook)
    await harness.start()
    try:
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
        assert h.ib.connect_args == ("127.0.0.1", 4002, 999, 10.0)
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
        assert h.ib.connect_args == ("127.0.0.1", 4001, 998, 10.0)
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

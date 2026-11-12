"""The notifier service: rules + ladder + messages + delivery + persisted state."""

from __future__ import annotations

import json
import sys
from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest

from brokersre_sidecar.model import GatewaySnapshot
from brokersre_sidecar.model.health import ProbeSnapshot
from brokersre_sidecar.notify import (
    DeliveryError,
    Dispatcher,
    LadderConfig,
    LadderEngine,
    Message,
    MessageFactory,
    Notifier,
    NotifierStore,
    RuleConfig,
    RuleEngine,
)
from brokersre_sidecar.redaction import SecretRegistry
from brokersre_sidecar.vocab import ProbeStatus
from testkit import FakeClock, RecordingSleep, gateway_snapshot, probe_snapshot


class Collector:
    """A channel that keeps every message it is given."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.sent: list[Message] = []

    def wants(self, message: Message) -> bool:
        return True

    async def send(self, message: Message) -> None:
        self.sent.append(message)


class World:
    """A notifier wired to hand-set snapshots, collecting channels and a state directory."""

    def __init__(self, state_dir: Path | None, clock: FakeClock | None = None) -> None:
        self.clock = clock or FakeClock()
        self.gateway: dict[str, Any] = {}
        self.probe: dict[str, Any] = {}
        self.ready = True
        self.teams, self.pager = Collector("teams"), Collector("pagerduty")
        self.dispatcher = Dispatcher(
            {"teams": self.teams, "pagerduty": self.pager},
            self.clock,
            RecordingSleep(self.clock),
        )
        self.notifier = self.build_notifier(state_dir)

    def build_notifier(self, state_dir: Path | None) -> Notifier:
        """Build a notifier around the current dispatcher."""
        return Notifier(
            rules=RuleEngine(RuleConfig()),
            ladder=LadderEngine(
                LadderConfig(
                    primary_channels=("teams",),
                    escalation_channels=("pagerduty",),
                    escalate_after_s=600.0,
                    escalate_again_after_s=1800.0,
                )
            ),
            factory=MessageFactory("desk-1", "Etc/UTC", None, SecretRegistry()),
            dispatcher=self.dispatcher,
            store=NotifierStore(state_dir / "notifier-state.json") if state_dir else None,
            clock=self.clock,
            gateway=self._gateway,
            probe=self._probe,
            ready=lambda: self.ready,
        )

    def _gateway(self) -> GatewaySnapshot:
        return gateway_snapshot(self.clock.now(), **self.gateway)

    def _probe(self) -> ProbeSnapshot:
        return probe_snapshot(self.clock.now(), **self.probe)

    async def tick(self, advance: float = 0.0) -> None:
        self.clock.advance(advance)
        await self.notifier.tick()
        for name in self.dispatcher.channel_names():
            await self.dispatcher.deliver_pending(name)


async def test_two_factor_pending_notifies_escalates_and_resolves_end_to_end(
    tmp_path: Path,
) -> None:
    world = World(tmp_path)
    world.notifier.load_state()
    world.gateway = {"phase": "2fa-pending"}
    world.probe = {"status": ProbeStatus.NOT_MEASURED}
    await world.tick()
    (first,) = world.teams.sent
    assert (first.alert_class, first.kind, first.phase) == (
        "twofa_pending",
        "firing",
        "2fa-pending",
    )
    assert first.instruction.startswith("Approve the IBKR Mobile prompt now")
    assert world.pager.sent == []
    await world.tick(600)
    (escalation,) = world.pager.sent
    assert (escalation.kind, escalation.escalation_step) == ("escalation", 1)
    world.gateway = {"phase": "logged-in"}
    await world.tick(30)
    assert [message.kind for message in world.teams.sent] == ["firing", "resolved"]
    assert [message.kind for message in world.pager.sent] == ["escalation", "resolved"]
    snapshot = world.notifier.snapshot()
    assert snapshot.enabled is True
    assert snapshot.active_alerts == ()
    assert snapshot.state_persistence == "file"
    assert {channel.name: channel.sent_total for channel in snapshot.channels} == {
        "teams": 2,
        "pagerduty": 2,
    }


async def test_nothing_is_evaluated_before_the_gateway_feed_was_read_once(tmp_path: Path) -> None:
    world = World(tmp_path)
    world.ready = False
    world.gateway = {"phase": "2fa-pending"}
    await world.tick()
    assert world.teams.sent == []
    world.ready = True
    await world.tick()
    assert len(world.teams.sent) == 1


async def test_de_duplication_state_survives_a_restart_of_the_sidecar(tmp_path: Path) -> None:
    before = World(tmp_path)
    before.notifier.load_state()
    before.gateway = {"phase": "2fa-pending"}
    await before.tick()
    await before.tick(1)  # the delivery result is saved by the next evaluation
    saved = json.loads((tmp_path / "notifier-state.json").read_text(encoding="utf-8"))
    assert saved["schema"] == "brokersre.sidecar.notifier-state.v2"
    assert saved["classes"]["twofa_pending"]["delivered"] is True

    after = World(tmp_path, before.clock)
    after.notifier.load_state()
    after.gateway = {"phase": "2fa-pending"}
    await after.tick(60)
    assert after.teams.sent == []  # no duplicate announcement after the restart
    assert [alert.alert_class for alert in after.notifier.snapshot().active_alerts] == [
        "twofa_pending"
    ]
    after.gateway = {"phase": "logged-in"}
    await after.tick(60)
    assert [message.kind for message in after.teams.sent] == ["resolved"]


async def test_without_a_writable_state_directory_the_notifier_works_from_memory_and_says_so(
    tmp_path: Path,
) -> None:
    world = World(tmp_path / "missing-directory")
    world.notifier.load_state()
    world.gateway = {"phase": "needs-human"}
    await world.tick()
    assert len(world.teams.sent) == 1
    snapshot = world.notifier.snapshot()
    assert snapshot.state_persistence == "memory"
    assert snapshot.state_persistence_reason is not None
    assert "not writable" in snapshot.state_persistence_reason
    assert not (tmp_path / "missing-directory").exists()


async def test_no_state_store_at_all_also_means_memory(tmp_path: Path) -> None:
    world = World(None)
    world.notifier.load_state()
    assert world.notifier.snapshot().state_persistence == "memory"


async def test_a_corrupt_state_file_is_ignored_and_replaced(tmp_path: Path) -> None:
    (tmp_path / "notifier-state.json").write_text("{ not json", encoding="utf-8")
    world = World(tmp_path)
    world.notifier.load_state()
    world.gateway = {"phase": "exited"}
    await world.tick()
    assert [message.alert_class for message in world.teams.sent] == ["gateway_exited"]
    saved = json.loads((tmp_path / "notifier-state.json").read_text(encoding="utf-8"))
    assert saved["classes"]["gateway_exited"]["active"] is True


async def test_a_state_directory_that_turns_read_only_degrades_to_memory(tmp_path: Path) -> None:
    if sys.platform == "win32":
        pytest.skip("POSIX directory modes")
    import os

    if os.geteuid() == 0:
        pytest.skip("root ignores directory modes")
    world = World(tmp_path)
    world.notifier.load_state()
    tmp_path.chmod(0o500)
    try:
        world.gateway = {"phase": "exited"}
        await world.tick()
        assert len(world.teams.sent) == 1
        snapshot = world.notifier.snapshot()
        assert snapshot.state_persistence == "memory"
        assert snapshot.state_persistence_reason == "saving the state failed (PermissionError)"
    finally:
        tmp_path.chmod(0o700)


async def test_messages_carry_the_api_status_and_the_rule_detail(tmp_path: Path) -> None:
    world = World(tmp_path)
    world.notifier.load_state()
    world.probe = {
        "status": ProbeStatus.DOWN,
        "status_since": world.clock.now(),
        "reason": "no API handshake on 127.0.0.1:4002 within 10 s",
    }
    await world.tick()
    assert world.teams.sent == []  # five minutes have not passed
    await world.tick(301)
    (alert,) = world.teams.sent
    assert alert.alert_class == "api_unhealthy"
    assert alert.api_status == "down"
    assert alert.detail == (
        "API status down for 301 s: no API handshake on 127.0.0.1:4002 within 10 s"
    )
    assert alert.since_utc is not None
    world.probe = {"status_since": world.clock.now() - timedelta(seconds=1)}
    await world.tick(60)
    assert [message.kind for message in world.teams.sent] == ["firing", "resolved"]


class Dead:
    """A channel without a route to its service: every attempt fails as retryable."""

    name = "teams"

    def __init__(self) -> None:
        self.attempts = 0

    def wants(self, message: Message) -> bool:
        return True

    async def send(self, message: Message) -> None:
        self.attempts += 1
        raise DeliveryError("connect", retryable=True)


async def test_an_alert_no_channel_accepted_is_not_notified_and_is_sent_again(
    tmp_path: Path,
) -> None:
    """The reviewer's reproduction: delivery failed, yet the alert was recorded as notified."""
    world = World(tmp_path)
    dead = Dead()
    world.dispatcher = Dispatcher({"teams": dead}, world.clock, RecordingSleep(world.clock))
    world.notifier = world.build_notifier(tmp_path)
    world.notifier.load_state()
    world.gateway = {"phase": "2fa-pending"}
    await world.tick()
    assert dead.attempts == 4  # one try and three retries inside the dispatcher
    alert = world.notifier.snapshot().active_alerts[0]
    assert (alert.alert_class, alert.notified, alert.failed_attempts) == ("twofa_pending", False, 1)
    # The ladder sends it again, 30 s after the failure.
    before = dead.attempts
    for _ in range(40):
        await world.tick(1)
    assert dead.attempts > before
    assert world.notifier.snapshot().active_alerts[0].notified is False
    saved = json.loads((tmp_path / "notifier-state.json").read_text(encoding="utf-8"))
    assert saved["classes"]["twofa_pending"]["delivered"] is False

    # The sidecar restarts where its channel works: it announces, it does not "resolve".
    after = World(tmp_path, world.clock)
    after.notifier.load_state()
    after.gateway = {"phase": "2fa-pending"}
    await after.tick(5)
    assert [(m.alert_class, m.kind) for m in after.teams.sent] == [("twofa_pending", "firing")]
    await after.tick(1)
    assert after.notifier.snapshot().active_alerts[0].notified is True
    after.gateway = {"phase": "logged-in"}
    await after.tick(60)
    assert [m.kind for m in after.teams.sent] == ["firing", "resolved"]


async def test_an_alert_that_was_never_delivered_clears_without_a_resolved(tmp_path: Path) -> None:
    world = World(tmp_path)
    dead = Dead()
    world.dispatcher = Dispatcher({"teams": dead}, world.clock, RecordingSleep(world.clock))
    world.notifier = world.build_notifier(tmp_path)
    world.notifier.load_state()
    world.gateway = {"phase": "2fa-pending"}
    await world.tick()
    world.gateway = {"phase": "logged-in"}
    attempts = dead.attempts
    await world.tick(10)
    assert dead.attempts == attempts  # nothing more was sent: no "resolved" into the void
    assert world.notifier.snapshot().active_alerts == ()

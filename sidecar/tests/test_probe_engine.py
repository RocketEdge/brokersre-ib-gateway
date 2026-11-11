"""Fault injection against the probe engine with the scriptable fake gateway."""

from __future__ import annotations

import itertools
from datetime import UTC, datetime

import pytest

from brokersre_sidecar.probe import ProbeConfig, ProbeEngine
from brokersre_sidecar.vocab import ProbeStatus
from fakes.fake_ib import FakeIb
from testkit import FakeClock

INTERVAL = 60.0
TIMEOUT = 10.0


class Harness:
    """A probe engine wired to a fake gateway, a fake clock and scriptable surroundings."""

    def __init__(self, *, enabled: bool = True, start: datetime | None = None) -> None:
        self.clock = FakeClock(start) if start is not None else FakeClock()
        self.ib = FakeIb(self.clock)
        self.phase: str | None = "logged-in"
        self.close_wait: int | None = 0
        self.engine = ProbeEngine(
            ProbeConfig(
                enabled=enabled,
                port=4002,
                client_id=999,
                interval_s=INTERVAL,
                timeout_s=TIMEOUT,
            ),
            self.ib,
            self.clock,
            phase=lambda: self.phase,
            close_wait=lambda: self.close_wait,
            rand=lambda: 0.5,
        )

    async def run(self, seconds: float, step: float = 1.0) -> None:
        """Tick the engine once per ``step`` seconds of fake time for ``seconds`` seconds."""
        end = self.clock.monotonic() + seconds
        while self.clock.monotonic() < end:
            await self.engine.tick()
            self.clock.advance(step)

    def status(self) -> ProbeStatus:
        """Return the engine's current status (a method so type narrowing does not stick)."""
        return self.engine.snapshot().status


async def test_a_healthy_gateway_is_ready_over_one_persistent_read_only_connection() -> None:
    h = Harness()
    await h.run(5 * INTERVAL)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.READY
    assert snapshot.last_probe_ok is True
    assert snapshot.last_rtt_s == pytest.approx(0.05)
    assert snapshot.connectivity == "ok"
    assert {(farm.kind, farm.name, farm.condition) for farm in snapshot.farms} == {
        ("market_data", "usfarm", "ok"),
        ("historical_data", "ushmds", "ok"),
        ("sec_def", "secdefnj", "ok"),
    }
    assert h.ib.connect_calls == 1
    assert h.ib.connect_args == ("127.0.0.1", 4002, 999, TIMEOUT)
    assert h.ib.time_calls == 5


async def test_a_gateway_that_accepts_tcp_but_never_answers_is_down_within_two_intervals() -> None:
    h = Harness()
    h.ib.connect_behaviour = "hang"
    await h.run(2 * INTERVAL)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.DOWN
    assert snapshot.last_error == "connect_failed"
    assert "handshake" in snapshot.reason
    assert snapshot.last_probe_ok is False


async def test_a_round_trip_that_times_out_is_down_and_the_dead_connection_is_dropped() -> None:
    h = Harness()
    await h.run(INTERVAL)
    assert h.status() is ProbeStatus.READY
    h.ib.time_behaviour = "timeout"
    await h.run(2 * INTERVAL)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.DOWN
    assert snapshot.last_error == "timeout"
    assert "timed out" in snapshot.reason
    assert h.ib.is_connected() is False
    assert h.ib.disconnect_calls >= 1


async def test_a_broken_farm_degrades_and_its_recovery_restores_ready() -> None:
    h = Harness()
    await h.run(INTERVAL)
    h.ib.emit(2103, "Market data farm connection is broken:usfarm")
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.DEGRADED
    assert "market_data" in snapshot.reason
    assert "usfarm" in snapshot.reason
    h.ib.emit(2104, "Market data farm connection is OK:usfarm")
    assert h.status() is ProbeStatus.READY


@pytest.mark.parametrize("restored", [1101, 1102])
async def test_connectivity_loss_degrades_until_ibkr_reports_it_restored(restored: int) -> None:
    h = Harness()
    await h.run(INTERVAL)
    h.ib.emit(1100, "Connectivity between IBKR and the gateway has been lost")
    assert h.status() is ProbeStatus.DEGRADED
    assert h.engine.snapshot().connectivity == "lost"
    await h.run(2 * INTERVAL)
    assert h.status() is ProbeStatus.DEGRADED
    h.ib.emit(restored, "Connectivity restored")
    assert h.status() is ProbeStatus.READY
    assert h.engine.snapshot().connectivity == "ok"


async def test_an_idle_farm_is_not_a_fault() -> None:
    h = Harness()
    await h.run(INTERVAL)
    h.ib.emit(2103, "Market data farm connection is broken:usfarm")
    h.ib.emit(
        2108, "Market data farm connection is inactive but should be available upon demand.usfarm"
    )
    assert h.status() is ProbeStatus.READY


async def test_error_326_is_its_own_state_and_is_never_retried_in_a_tight_loop() -> None:
    h = Harness()
    h.ib.connect_behaviour = "client_id_in_use"
    await h.run(20 * 60)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.CLIENT_ID_IN_USE
    assert "999" in snapshot.reason
    assert "HEALTH_CLIENT_ID" in snapshot.reason
    assert snapshot.last_error == "client_id_in_use"
    # 20 minutes: the first attempt plus at most one retry every five minutes.
    assert h.ib.connect_calls <= 5
    h.ib.connect_behaviour = "ok"
    await h.run(6 * 60)
    assert h.status() is ProbeStatus.READY


@pytest.mark.parametrize(
    "phase", ["starting", "login", "2fa-pending", "restarting", "unknown", None]
)
async def test_outside_logged_in_nothing_is_measured_and_nothing_is_sent(phase: str | None) -> None:
    h = Harness()
    h.phase = phase
    await h.run(3 * INTERVAL)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.NOT_MEASURED
    assert snapshot.connectivity == "not_measured"
    assert snapshot.last_probe_ok is None
    assert h.ib.connect_calls == 0
    assert "logged-in" in snapshot.reason


async def test_leaving_logged_in_drops_the_connection_and_logging_in_again_probes_at_once() -> None:
    h = Harness()
    await h.run(INTERVAL)
    h.phase = "restarting"
    await h.engine.tick()
    assert h.status() is ProbeStatus.NOT_MEASURED
    assert h.ib.is_connected() is False
    assert h.engine.snapshot().farms == ()
    h.clock.advance(5)
    h.phase = "logged-in"
    await h.engine.tick()
    assert h.status() is ProbeStatus.READY
    assert h.ib.connect_calls == 2


async def test_before_the_first_probe_completes_the_status_is_not_measured() -> None:
    h = Harness()
    assert h.status() is ProbeStatus.NOT_MEASURED
    assert "first probe" in h.engine.snapshot().reason


async def test_a_disabled_probe_never_connects_and_reports_not_measured() -> None:
    h = Harness(enabled=False)
    await h.run(3 * INTERVAL)
    assert h.status() is ProbeStatus.NOT_MEASURED
    assert "PROBE_ENABLED" in h.engine.snapshot().reason
    assert h.ib.connect_calls == 0


async def test_failures_back_off_exponentially_up_to_a_cap_and_recover_on_success() -> None:
    h = Harness()
    h.ib.connect_behaviour = "refuse"
    attempts: list[float] = []
    seen = 0
    start = h.clock.monotonic()
    for _ in range(1800):
        await h.engine.tick()
        if h.ib.connect_calls != seen:
            seen = h.ib.connect_calls
            attempts.append(h.clock.monotonic() - start)
        h.clock.advance(1.0)
    gaps = [later - earlier for earlier, later in itertools.pairwise(attempts)]
    assert gaps[:5] == [15.0, 30.0, 60.0, 120.0, 240.0]
    assert all(gap <= 300.0 for gap in gaps)
    assert h.engine.snapshot().consecutive_failures == len(attempts)
    h.ib.connect_behaviour = "ok"
    await h.run(301)
    snapshot = h.engine.snapshot()
    assert snapshot.status is ProbeStatus.READY
    assert snapshot.consecutive_failures == 0


async def test_a_connection_dropped_between_probes_is_noticed_without_waiting_for_the_interval() -> (
    None
):
    h = Harness()
    await h.run(5)
    assert h.ib.connect_calls == 1
    h.ib.drop()
    await h.run(3)
    assert h.ib.connect_calls == 2
    assert h.status() is ProbeStatus.READY


async def test_clock_skew_is_ibkr_time_minus_local_time() -> None:
    h = Harness()
    h.ib.skew_s = 3.0
    await h.run(5)
    assert h.engine.snapshot().clock_skew_s == pytest.approx(3.0)
    h.ib.skew_s = -2.0
    await h.run(INTERVAL)
    assert h.engine.snapshot().clock_skew_s == pytest.approx(-2.0)


async def test_a_zombie_is_half_closed_sockets_for_five_minutes_plus_a_failed_round_trip() -> None:
    h = Harness()
    await h.run(INTERVAL)
    h.close_wait = 4
    await h.run(6 * 60)
    snapshot = h.engine.snapshot()
    assert snapshot.close_wait_sockets == 4
    assert snapshot.zombie is False  # the API still answers
    assert snapshot.status is ProbeStatus.READY
    h.ib.time_behaviour = "timeout"
    h.ib.connect_behaviour = "hang"
    await h.run(2 * INTERVAL)
    snapshot = h.engine.snapshot()
    assert snapshot.zombie is True
    assert snapshot.status is ProbeStatus.DOWN
    assert "half-closed" in snapshot.reason


async def test_half_closed_sockets_that_clear_restart_the_five_minute_clock() -> None:
    h = Harness()
    h.ib.connect_behaviour = "hang"
    h.close_wait = 2
    await h.run(4 * 60)
    h.close_wait = 0
    await h.run(30)
    h.close_wait = 2
    await h.run(4 * 60)
    assert h.engine.snapshot().zombie is False


async def test_close_wait_that_cannot_be_read_is_reported_as_not_measured() -> None:
    h = Harness()
    h.close_wait = None
    await h.run(INTERVAL)
    assert h.engine.snapshot().close_wait_sockets is None
    assert h.engine.snapshot().zombie is False


async def test_the_reset_window_flag_follows_the_ibkr_schedule() -> None:
    # 2026-11-12 05:30 UTC is 00:30 in New York: inside the North America window.
    inside = Harness(start=datetime(2026, 11, 12, 5, 30, tzinfo=UTC))
    assert inside.engine.snapshot().in_reset_window is True
    assert Harness().engine.snapshot().in_reset_window is False


async def test_status_since_moves_only_when_the_status_changes() -> None:
    h = Harness()
    await h.run(INTERVAL)
    since = h.engine.snapshot().status_since
    assert since is not None
    await h.run(3 * INTERVAL)
    assert h.engine.snapshot().status_since == since
    h.ib.emit(1100, "lost")
    changed = h.engine.snapshot().status_since
    assert changed is not None
    assert changed > since


async def test_shutdown_disconnects() -> None:
    h = Harness()
    await h.run(5)
    h.engine.shutdown()
    assert h.ib.is_connected() is False


async def test_farm_names_from_the_gateway_are_sanitised_and_bounded() -> None:
    h = Harness()
    await h.run(5)
    h.ib.emit(2103, "Market data farm connection is broken:CANARY USER DU1234567")
    for number in range(100):
        h.ib.emit(2105, f"HMDS data farm connection is broken:farm{number}")
    snapshot = h.engine.snapshot()
    assert len(snapshot.farms) <= 32
    text = repr(snapshot)
    assert "CANARY" not in text
    assert "DU1234567" not in text

"""An unattended second factor, replayed as the gateway really behaves.

With the gateway's defaults (prompt timeout 180 s, re-login, no prompt limit) an unanswered
prompt makes the phase flip ``2fa-pending`` -> ``login`` -> ``2fa-pending`` every three
minutes, for hours. The alert must stay one alert: announced at the first prompt, escalated
10 and 30 minutes after the FIRST prompt, and resolved only by a completed login.
"""

from __future__ import annotations

from brokersre_sidecar.model import GatewayState
from brokersre_sidecar.model.health import ProbeSnapshot
from brokersre_sidecar.notify import Condition, LadderConfig, LadderEngine, RuleConfig, RuleEngine
from brokersre_sidecar.tail import PhaseReading
from brokersre_sidecar.vocab import AlertClass, ProbeStatus
from testkit import BOOT, T0, FakeClock, gateway_event, probe_snapshot

PROMPT_S = 180
RELOGIN_S = 15
CYCLE_S = PROMPT_S + RELOGIN_S


class Timeline:
    """Model, rules and ladder driven second by second through a scripted gateway."""

    def __init__(self) -> None:
        self.clock = FakeClock()
        self.state = GatewayState(self.clock)
        self.rules = RuleEngine(RuleConfig())
        self.ladder = LadderEngine(
            LadderConfig(
                primary_channels=("teams",),
                escalation_channels=("pagerduty",),
                escalate_after_s=600.0,
                escalate_again_after_s=1800.0,
            )
        )
        self.sent: list[tuple[int, str, str, int]] = []
        self.second = 0
        self.state.observe_event(gateway_event("container_start", T0))

    def phase(self, token: str) -> None:
        self.state.observe_phase(PhaseReading(token, True, self.clock.now()))

    def event(self, name: str) -> None:
        self.state.observe_event(gateway_event(name, self.clock.now(), BOOT))

    def tick(self) -> None:
        verdicts = self.rules.evaluate(
            self.state.snapshot(),
            _not_measured(),
            now=self.clock.now(),
            mono=self.clock.monotonic(),
        )
        for due in self.ladder.step(verdicts, self.clock.now()):
            self.sent.append(
                (self.second, due.kind.value, due.alert_class.value, due.escalation_step)
            )
            self.ladder.record_result(due, delivered=True, now=self.clock.now())
        self.clock.advance(1.0)
        self.second += 1

    def unattended_prompts(self, seconds: int) -> None:
        """Run the gateway's prompt/timeout/re-login cycle for ``seconds`` seconds."""
        for _ in range(seconds):
            position = self.second % CYCLE_S
            if position == 0:
                self.phase("2fa-pending")
                self.event("twofa_initiated")
            elif position == PROMPT_S:
                self.phase("login")
                self.event("twofa_timeout")
            self.tick()

    def verdict(self, alert: AlertClass) -> Condition:
        verdicts = self.rules.evaluate(
            self.state.snapshot(),
            _not_measured(),
            now=self.clock.now(),
            mono=self.clock.monotonic(),
        )
        return verdicts[alert].state


def _not_measured() -> ProbeSnapshot:
    """A probe that measures nothing: the gateway is not logged in during these tests."""
    return probe_snapshot(status=ProbeStatus.NOT_MEASURED, clock_skew_s=None)


def test_an_unanswered_prompt_is_one_alert_escalated_from_the_first_prompt() -> None:
    t = Timeline()
    t.unattended_prompts(4 * 3600)
    assert t.sent == [
        (0, "firing", "twofa_pending", 0),
        (600, "escalation", "twofa_pending", 1),
        (1800, "escalation", "twofa_pending", 2),
    ]
    # A person finally approves the prompt.
    t.phase("logged-in")
    t.event("login_completed")
    t.tick()
    assert t.sent[-1][1:3] == ("resolved", "twofa_pending")
    assert len(t.sent) == 4
    # Hours later there is still nothing more to say.
    for _ in range(3600):
        t.tick()
    assert len(t.sent) == 4


def test_the_condition_holds_between_two_prompts() -> None:
    t = Timeline()
    t.unattended_prompts(PROMPT_S + 5)  # the first prompt timed out; the gateway logs in again
    assert t.state.phase == "login"
    assert t.verdict(AlertClass.TWOFA_PENDING) is Condition.ACTIVE
    # The gateway does not call this a stalled login, and neither does the sidecar.
    assert t.verdict(AlertClass.LOGIN_STALLED) is not Condition.ACTIVE


def test_giving_up_hands_the_alert_over_instead_of_calling_it_resolved() -> None:
    t = Timeline()
    t.unattended_prompts(2 * CYCLE_S)
    t.phase("needs-human")
    t.event("needs_human")
    t.tick()
    kinds = [(kind, alert) for _, kind, alert, _ in t.sent]
    assert kinds == [
        ("firing", "twofa_pending"),
        ("resolved", "twofa_pending"),
        ("firing", "needs_human"),
    ]
    assert t.verdict(AlertClass.TWOFA_PENDING) is Condition.INACTIVE

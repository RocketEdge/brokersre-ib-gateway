"""Tests for ``BackoffPolicy``: the pause between two connection attempts.

A client that retries too eagerly hammers a gateway that is restarting; one that retries
without jitter reconnects in lock-step with every other client of the same gateway. The
policy must therefore grow, stay under its cap and stay inside its jitter band.
"""

import random

import pytest

from resilient_client import BackoffPolicy


def test_delay_doubles_from_the_base_until_it_reaches_the_cap() -> None:
    """Without jitter the delays are base, 2x, 4x, ... and then the cap, forever."""
    policy = BackoffPolicy(base_s=1.0, cap_s=30.0, jitter=0.0)
    rng = random.Random(1)

    delays = [policy.delay(attempt, rng) for attempt in range(8)]

    assert delays == [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]


@pytest.mark.parametrize("seed", range(20))
def test_delay_stays_inside_the_jitter_band_and_under_the_cap(seed: int) -> None:
    """With jitter j the delay lies in [raw * (1 - j), raw], and raw never exceeds the cap."""
    policy = BackoffPolicy(base_s=0.5, cap_s=20.0, jitter=0.25)
    rng = random.Random(seed)

    for attempt in range(12):
        raw = min(20.0, 0.5 * 2**attempt)
        delay = policy.delay(attempt, rng)
        assert raw * 0.75 <= delay <= raw
        assert delay <= 20.0


def test_jitter_really_varies_the_delay() -> None:
    """Two draws for the same attempt differ: clients do not reconnect in lock-step."""
    policy = BackoffPolicy(base_s=1.0, cap_s=30.0, jitter=0.25)
    rng = random.Random(7)

    draws = {policy.delay(3, rng) for _ in range(10)}

    assert len(draws) == 10


def test_a_very_late_attempt_still_gives_the_cap_instead_of_overflowing() -> None:
    """After days of retries the attempt number is large; the delay is still the cap."""
    policy = BackoffPolicy(base_s=1.0, cap_s=30.0, jitter=0.0)

    assert policy.delay(100_000, random.Random(1)) == 30.0


def test_a_negative_attempt_is_a_programming_error() -> None:
    """Attempt numbers count from zero; a negative one is refused, not clamped."""
    policy = BackoffPolicy()

    with pytest.raises(ValueError, match="attempt must not be negative"):
        policy.delay(-1, random.Random(1))


@pytest.mark.parametrize(
    ("base_s", "cap_s", "jitter", "message"),
    [
        (0.0, 30.0, 0.25, "base_s must be positive"),
        (-1.0, 30.0, 0.25, "base_s must be positive"),
        (5.0, 1.0, 0.25, "cap_s must not be smaller than base_s"),
        (1.0, 30.0, -0.1, "jitter must be between 0 and 1"),
        (1.0, 30.0, 1.5, "jitter must be between 0 and 1"),
    ],
)
def test_an_impossible_policy_is_refused_when_it_is_created(
    base_s: float, cap_s: float, jitter: float, message: str
) -> None:
    """A policy that could yield a zero, negative or unbounded delay cannot be built."""
    with pytest.raises(ValueError, match=message):
        BackoffPolicy(base_s=base_s, cap_s=cap_s, jitter=jitter)


def test_the_default_policy_is_one_second_doubling_to_thirty() -> None:
    """The defaults suit a gateway restart: quick first retries, at most 30 s apart."""
    policy = BackoffPolicy()

    assert (policy.base_s, policy.cap_s, policy.jitter) == (1.0, 30.0, 0.25)

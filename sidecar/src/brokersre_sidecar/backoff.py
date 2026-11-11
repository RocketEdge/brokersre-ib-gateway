"""Capped exponential back-off with jitter (leaf module).

One policy object is shared by everything that retries: the task supervisor, the API probe
and the notification dispatcher. The random source is injected so tests are deterministic.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

# 2**64 already exceeds any sane cap; clamping the exponent keeps float arithmetic finite
# for arbitrarily large attempt counters (a task that has crashed for weeks).
_MAX_EXPONENT = 64


@dataclass(frozen=True, slots=True)
class Backoff:
    """Delay schedule ``base * factor**(attempt-1)``, spread by ``jitter`` and capped.

    Attributes:
        base_s: Delay before the first retry, in seconds (> 0).
        cap_s: Upper bound of any returned delay, in seconds (>= base_s).
        factor: Growth per attempt (>= 1).
        jitter: Relative spread in ``[0, 1)``: the nominal delay is multiplied by a value in
            ``[1 - jitter, 1 + jitter]`` so that retries of many instances do not align.
    """

    base_s: float
    cap_s: float
    factor: float = 2.0
    jitter: float = 0.2

    def delay(self, attempt: int, rand: Callable[[], float]) -> float:
        """Return the delay in seconds before retry number ``attempt``.

        Args:
            attempt: 1 for the first retry; values below 1 are treated as 1.
            rand: Returns a float in ``[0, 1]`` (``random.random`` in production).

        Returns:
            A delay in ``(0, cap_s]``.
        """
        exponent = min(max(attempt, 1) - 1, _MAX_EXPONENT)
        nominal = min(self.cap_s, self.base_s * self.factor**exponent)
        spread = 1.0 + self.jitter * (2.0 * rand() - 1.0)
        return min(self.cap_s, nominal * spread)

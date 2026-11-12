"""Delivery of notifications: one bounded outbox and one worker per channel.

Isolation is the point. Each channel has its own queue and its own worker task, so a
webhook that hangs or a mail server that is down delays only its own messages. Every send
is bounded by ``send_timeout_s``; a retryable failure is retried ``retries`` times with
exponential back-off and jitter; a full outbox drops its oldest message (the newest state
matters most). Every outcome is counted and visible in ``/status`` and ``/metrics``.

The caller can ask to be told the outcome of a message across all its channels: the
``on_done`` callback receives True when at least one channel accepted it. That is what lets
the ladder treat an alert as notified only when somebody could actually have received it.
"""

from __future__ import annotations

import asyncio
import logging
import random
from collections import deque
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from datetime import datetime

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import Clock, Sleep
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import ChannelSnapshot
from brokersre_sidecar.notify.channels.base import Channel, DeliveryError
from brokersre_sidecar.notify.message import Message

_LOGGER = logging.getLogger(__name__)

OnDone = Callable[[bool], None]
"""Called once per message with True when at least one channel accepted it."""


@dataclass(slots=True)
class _Delivery:
    """Outcome of one message across the channels it was queued for."""

    remaining: int
    on_done: OnDone | None
    accepted: bool = False

    def settle(self, accepted: bool) -> None:
        """Record the final outcome of one channel; report when every channel is done."""
        self.accepted = self.accepted or accepted
        self.remaining -= 1
        if self.remaining == 0 and self.on_done is not None:
            self.on_done(self.accepted)


@dataclass(slots=True)
class _Outbox:
    """Queue and statistics of one channel."""

    items: deque[tuple[Message, _Delivery]] = field(default_factory=deque)
    wake: asyncio.Event = field(default_factory=asyncio.Event)
    busy: bool = False
    sent_total: int = 0
    failures_total: int = 0
    dropped_total: int = 0
    last_success_at: datetime | None = None
    last_failure_at: datetime | None = None
    last_error: str | None = None


class Dispatcher:
    """Queues messages per channel and delivers them with timeout, retry and accounting.

    Threading model: single event loop. ``enqueue`` never blocks and never raises; the
    workers (``run_channel``) are separate supervised tasks. ``on_done`` callbacks run on
    the event loop, from ``enqueue`` or from a worker.
    """

    def __init__(
        self,
        channels: Mapping[str, Channel],
        clock: Clock,
        sleep: Sleep,
        *,
        rand: Callable[[], float] = random.random,
        outbox_size: int = 64,
        retries: int = 3,
        send_timeout_s: float = 10.0,
        backoff: Backoff | None = None,
    ) -> None:
        """Create the dispatcher.

        Args:
            channels: Configured channels by name.
            clock: Time source for the statistics.
            sleep: Awaitable delay used between retries.
            rand: Random source of the back-off jitter.
            outbox_size: Messages kept per channel; the oldest is dropped beyond that.
            retries: Retries after the first attempt of a message.
            send_timeout_s: Bound of one send attempt.
            backoff: Retry delays (default 1 s doubling to 30 s, 20 % jitter).
        """
        self._channels = dict(channels)
        self._clock = clock
        self._sleep = sleep
        self._rand = rand
        self._outbox_size = outbox_size
        self._retries = retries
        self._send_timeout_s = send_timeout_s
        self._backoff = backoff if backoff is not None else Backoff(base_s=1.0, cap_s=30.0)
        self._boxes = {name: _Outbox() for name in self._channels}
        self._changed = asyncio.Event()

    def channel_names(self) -> tuple[str, ...]:
        """Return the names of the configured channels."""
        return tuple(self._channels)

    def enqueue(
        self, message: Message, channels: Iterable[str], on_done: OnDone | None = None
    ) -> None:
        """Queue ``message`` for each named channel that is configured and wants it.

        Never blocks: when a channel's outbox is full its oldest message is dropped,
        counted in ``dropped_total`` and reported to its caller as not delivered there.

        Args:
            message: The message.
            channels: Channel names; unknown names are ignored.
            on_done: Called once with True when at least one channel accepted the message,
                with False when every channel failed, dropped it or none was eligible.
        """
        targets = [
            name
            for name in dict.fromkeys(channels)
            if name in self._channels and self._channels[name].wants(message)
        ]
        if not targets:
            if on_done is not None:
                on_done(False)
            return
        delivery = _Delivery(len(targets), on_done)
        for name in targets:
            box = self._boxes[name]
            if len(box.items) >= self._outbox_size:
                _dropped, dropped_delivery = box.items.popleft()
                box.dropped_total += 1
                log_event(_LOGGER, logging.WARNING, "notify_dropped", channel=name)
                dropped_delivery.settle(False)
            box.items.append((message, delivery))
            box.wake.set()

    async def run_channel(self, name: str) -> None:
        """Deliver the queue of one channel forever (a supervised task).

        Raises:
            Exception: Only an unexpected error (a bug) in the channel; it is counted as a
                failure first, and the supervisor restarts the worker.
        """
        box = self._boxes[name]
        while True:
            await self.deliver_pending(name)
            box.wake.clear()
            if not box.items:
                await box.wake.wait()

    async def deliver_pending(self, name: str) -> None:
        """Deliver everything currently queued for channel ``name``, in order."""
        box = self._boxes[name]
        channel = self._channels[name]
        while box.items:
            message, delivery = box.items.popleft()
            box.busy = True
            try:
                accepted = await self._deliver(channel, box, message)
            except asyncio.CancelledError:
                # Stopped mid-send: keep the message for the flush at shutdown (delivery is
                # at-least-once; a duplicate is better than a lost alert).
                box.items.appendleft((message, delivery))
                raise
            except BaseException:
                self._record_failure(box, "internal_error")
                delivery.settle(False)
                raise
            finally:
                box.busy = False
                self._changed.set()
            delivery.settle(accepted)

    async def send_now(self, name: str, message: Message) -> str | None:
        """Send ``message`` to one channel with a single attempt (``notify test``).

        Returns:
            None on success, otherwise the failure category (``not_configured`` when the
            channel does not exist).
        """
        channel = self._channels.get(name)
        if channel is None:
            return "not_configured"
        box = self._boxes[name]
        error = await self._attempt(channel, message)
        if error is None:
            self._record_success(box)
            return None
        self._record_failure(box, error.category)
        return error.category

    async def drain(self) -> None:
        """Wait until every outbox is empty and no send is in flight."""
        while any(box.items or box.busy for box in self._boxes.values()):
            self._changed.clear()
            await self._changed.wait()

    def snapshot(self) -> tuple[ChannelSnapshot, ...]:
        """Return the statistics of every channel."""
        return tuple(
            ChannelSnapshot(
                name=name,
                sent_total=box.sent_total,
                failures_total=box.failures_total,
                dropped_total=box.dropped_total,
                queue_depth=len(box.items),
                last_success_at=box.last_success_at,
                last_failure_at=box.last_failure_at,
                last_error=box.last_error,
            )
            for name, box in self._boxes.items()
        )

    async def _deliver(self, channel: Channel, box: _Outbox, message: Message) -> bool:
        """Send one message with retries; record and return the final outcome."""
        attempt = 0
        while True:
            attempt += 1
            error = await self._attempt(channel, message)
            if error is None:
                self._record_success(box)
                return True
            if not error.retryable or attempt > self._retries:
                self._record_failure(box, error.category)
                log_event(
                    _LOGGER,
                    logging.ERROR,
                    "notify_failed",
                    "notification could not be delivered",
                    channel=channel.name,
                    category=error.category,
                    attempts=attempt,
                    alert_class=message.alert_class,
                    kind=message.kind,
                )
                return False
            await self._sleep(self._backoff.delay(attempt, self._rand))

    async def _attempt(self, channel: Channel, message: Message) -> DeliveryError | None:
        """Make one bounded send attempt; return the error instead of raising it."""
        try:
            await asyncio.wait_for(channel.send(message), self._send_timeout_s)
        except DeliveryError as error:
            return error
        except TimeoutError:
            return DeliveryError("timeout", retryable=True)
        return None

    def _record_success(self, box: _Outbox) -> None:
        """Count a delivered message."""
        box.sent_total += 1
        box.last_success_at = self._clock.now()

    def _record_failure(self, box: _Outbox, category: str) -> None:
        """Count a message that was given up on."""
        box.failures_total += 1
        box.last_failure_at = self._clock.now()
        box.last_error = category

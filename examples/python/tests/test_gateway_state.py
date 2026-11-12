"""Tests for ``GatewayState``: what a client may do, derived from IBKR's message codes.

The rules under test (examples/README.md): 1100 means stop sending and keep the connection;
1102 means continue; 1101 means continue and re-subscribe; the data-farm codes describe market
data routes and never the API connection itself.
"""

import pytest

from resilient_client import Action, GatewayState, Readiness


def connected_state() -> GatewayState:
    """Return a state machine that has seen a successful connection."""
    state = GatewayState()
    state.on_connected()
    return state


def test_a_new_state_is_disconnected_with_no_broken_farm() -> None:
    """Before any connection nothing may be sent."""
    state = GatewayState()

    assert state.readiness is Readiness.DISCONNECTED
    assert state.broken_farms == ()


def test_a_connection_makes_the_client_ready_and_asks_for_subscriptions() -> None:
    """A fresh API session has no subscriptions: connecting always means (re-)subscribing."""
    state = GatewayState()

    action = state.on_connected()

    assert action is Action.RESUBSCRIBE
    assert state.readiness is Readiness.READY


def test_1100_stops_sending_but_keeps_the_connection() -> None:
    """Connectivity between the gateway and IBKR is lost: pause, do not disconnect."""
    state = connected_state()

    action = state.on_error(1100, "Connectivity between IBKR and the gateway has been lost")

    assert action is Action.PAUSE
    assert state.readiness is Readiness.CONNECTIVITY_LOST


def test_1102_resumes_without_resubscribing() -> None:
    """Connectivity restored, data maintained: carry on, subscriptions are intact."""
    state = connected_state()
    state.on_error(1100, "lost")

    action = state.on_error(1102, "Connectivity restored - data maintained")

    assert action is Action.RESUME
    assert state.readiness is Readiness.READY


def test_1101_resumes_and_asks_for_subscriptions_again() -> None:
    """Connectivity restored, data lost: carry on, but every subscription must be redone."""
    state = connected_state()
    state.on_error(1100, "lost")

    action = state.on_error(1101, "Connectivity restored - data lost")

    assert action is Action.RESUBSCRIBE
    assert state.readiness is Readiness.READY


def test_a_repeated_1100_keeps_the_client_paused() -> None:
    """IBKR may repeat 1100 while the outage lasts; the state does not flip."""
    state = connected_state()
    state.on_error(1100, "lost")

    action = state.on_error(1100, "lost")

    assert action is Action.PAUSE
    assert state.readiness is Readiness.CONNECTIVITY_LOST


@pytest.mark.parametrize("code", [1100, 1101, 1102, 2103, 2104, 2105, 2106, 2157, 2158])
def test_a_code_that_arrives_without_a_connection_changes_nothing(code: int) -> None:
    """A late message from a connection that is already gone must not make the client ready."""
    state = GatewayState()

    action = state.on_error(code, "Market data farm connection is broken:usfarm")

    assert action is Action.NONE
    assert state.readiness is Readiness.DISCONNECTED
    assert state.broken_farms == ()


@pytest.mark.parametrize(
    ("broken_code", "ok_code", "farm"),
    [
        (2103, 2104, "usfarm"),
        (2105, 2106, "ushmds"),
        (2157, 2158, "secdefil"),
    ],
)
def test_a_farm_code_marks_the_farm_and_leaves_readiness_alone(
    broken_code: int, ok_code: int, farm: str
) -> None:
    """A broken data farm is recorded by name and cleared by the matching OK code."""
    state = connected_state()

    broken_action = state.on_error(broken_code, f"A data farm connection is broken:{farm}")

    broken_after_the_broken_code = state.broken_farms

    assert broken_action is Action.NONE
    assert broken_after_the_broken_code == (farm,)
    assert state.readiness is Readiness.READY

    ok_action = state.on_error(ok_code, f"A data farm connection is OK:{farm}")
    broken_after_the_ok_code = state.broken_farms

    assert ok_action is Action.NONE
    assert broken_after_the_ok_code == ()
    assert state.readiness is Readiness.READY


def test_several_broken_farms_are_listed_in_name_order() -> None:
    """The list is sorted so that a log line or an assertion is stable."""
    state = connected_state()

    state.on_error(2105, "HMDS data farm connection is broken:ushmds")
    state.on_error(2103, "Market data farm connection is broken:usfarm")
    state.on_error(2103, "Market data farm connection is broken:eufarm")
    state.on_error(2104, "Market data farm connection is OK:usfarm")

    assert state.broken_farms == ("eufarm", "ushmds")


def test_a_farm_message_without_a_name_is_recorded_under_its_kind() -> None:
    """IBKR's text is not a contract; a message without ':<farm>' still leaves a trace."""
    state = connected_state()

    state.on_error(2103, "Market data farm connection is broken")

    assert state.broken_farms == ("market-data",)


def test_an_ok_code_for_a_farm_that_was_never_broken_changes_nothing() -> None:
    """After connecting the gateway lists every farm as OK; that is not a transition."""
    state = connected_state()

    action = state.on_error(2104, "Market data farm connection is OK:usfarm")

    assert action is Action.NONE
    assert state.broken_farms == ()


def test_a_farm_code_does_not_end_a_connectivity_outage() -> None:
    """Only 1101 and 1102 end an 1100; a farm coming back first does not."""
    state = connected_state()
    state.on_error(1100, "lost")

    state.on_error(2104, "Market data farm connection is OK:usfarm")

    assert state.readiness is Readiness.CONNECTIVITY_LOST


@pytest.mark.parametrize("code", [0, 200, 326, 502, 2107, 2108, 10167])
def test_any_other_code_is_not_a_connectivity_event(code: int) -> None:
    """Request errors and other notices do not move the state machine."""
    state = connected_state()

    action = state.on_error(code, "something else")

    assert action is Action.NONE
    assert state.readiness is Readiness.READY


def test_a_disconnect_pauses_and_forgets_the_farms() -> None:
    """The next connection is a new session: farm status starts from scratch."""
    state = connected_state()
    state.on_error(2103, "Market data farm connection is broken:usfarm")

    action = state.on_disconnected()

    assert action is Action.PAUSE
    assert state.readiness is Readiness.DISCONNECTED
    assert state.broken_farms == ()


def test_a_reconnect_after_an_outage_starts_ready() -> None:
    """A connection that was dropped during an 1100 does not stay paused when it returns."""
    state = connected_state()
    state.on_error(1100, "lost")
    state.on_disconnected()

    action = state.on_connected()

    assert action is Action.RESUBSCRIBE
    assert state.readiness is Readiness.READY

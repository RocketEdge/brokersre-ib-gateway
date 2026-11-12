"""Tests for the command line of ``resilient_client``: options, environment, defaults."""

import pytest

from resilient_client import parse_args


def test_the_defaults_point_at_a_paper_gateway_on_this_host() -> None:
    """No option and no environment: loopback, the paper port, a client id of its own."""
    config = parse_args([], {})

    assert (config.host, config.port, config.client_id) == ("127.0.0.1", 4002, 101)
    assert config.poll_interval_s == 30.0


def test_options_set_host_port_client_id_and_interval() -> None:
    """Every documented option reaches the configuration."""
    config = parse_args(
        ["--host", "ib-gateway", "--port", "4004", "--client-id", "7", "--interval", "5"], {}
    )

    assert (config.host, config.port, config.client_id) == ("ib-gateway", 4004, 7)
    assert config.poll_interval_s == 5.0


def test_the_environment_supplies_host_port_and_client_id() -> None:
    """IBGW_HOST and IBGW_PORT are the variables wait-for-gateway.sh reads as well."""
    config = parse_args([], {"IBGW_HOST": "gateway.test", "IBGW_PORT": "4003", "IB_CLIENT_ID": "9"})

    assert (config.host, config.port, config.client_id) == ("gateway.test", 4003, 9)


def test_an_option_wins_over_the_environment() -> None:
    """What is typed on the command line is more specific than the environment."""
    config = parse_args(["--port", "4004"], {"IBGW_PORT": "4003"})

    assert config.port == 4004


@pytest.mark.parametrize(
    "argv",
    [["--port", "not-a-number"], ["--port", "0"], ["--client-id", "-3"], ["--interval", "0"]],
    ids=["port-text", "port-zero", "client-id-negative", "interval-zero"],
)
def test_a_value_that_cannot_work_ends_with_a_usage_error(argv: list[str]) -> None:
    """The convention of argparse applies: a message on stderr and exit status 2."""
    with pytest.raises(SystemExit) as exit_info:
        parse_args(argv, {})

    assert exit_info.value.code == 2


def test_an_environment_value_that_is_not_a_number_ends_with_a_usage_error() -> None:
    """A typo in IBGW_PORT is reported like a typo in --port."""
    with pytest.raises(SystemExit) as exit_info:
        parse_args([], {"IBGW_PORT": "paper"})

    assert exit_info.value.code == 2

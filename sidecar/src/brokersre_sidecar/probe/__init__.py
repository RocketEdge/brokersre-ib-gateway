"""Probe layer: the read-only API health check.

``probe.adapter`` (the only module that imports ``ib_async``) is deliberately not imported
here: everything else depends on the ``IbClient`` protocol only, and the adapter is loaded
by the application wiring when the probe is enabled.
"""

from brokersre_sidecar.probe.engine import ProbeConfig, ProbeEngine
from brokersre_sidecar.probe.namespace import NamespaceWatch
from brokersre_sidecar.probe.protocol import (
    ErrorListener,
    IbClient,
    IbConnectError,
    IbDisconnectedError,
    IbError,
    IbTimeoutError,
)
from brokersre_sidecar.probe.sockets import count_close_wait, count_foreign_listeners
from brokersre_sidecar.probe.tracker import ApiConditionTracker, farm_name
from brokersre_sidecar.probe.windows import RESET_WINDOWS, ResetWindow, active_reset_window

__all__ = [
    "RESET_WINDOWS",
    "ApiConditionTracker",
    "ErrorListener",
    "IbClient",
    "IbConnectError",
    "IbDisconnectedError",
    "IbError",
    "IbTimeoutError",
    "NamespaceWatch",
    "ProbeConfig",
    "ProbeEngine",
    "ResetWindow",
    "active_reset_window",
    "count_close_wait",
    "count_foreign_listeners",
    "farm_name",
]

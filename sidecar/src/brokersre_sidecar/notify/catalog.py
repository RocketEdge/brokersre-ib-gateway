"""The alert catalogue: default severity, title and the instruction for the human.

Every sentence a notification carries comes from this table (plus numbers computed by the
rules). Nothing is copied from gateway output, which is what keeps usernames and account
ids out of notifications by construction.
"""

from __future__ import annotations

from dataclasses import dataclass

from brokersre_sidecar.vocab import AlertClass, Severity


@dataclass(frozen=True, slots=True)
class AlertSpec:
    """Static description of one alert class.

    Attributes:
        alert_class: The class this entry describes.
        severity: Default severity of a firing notification.
        title: Short headline.
        instruction: What the human should do, in one or two sentences.
        ladder: True for classes that need a human NOW; they are repeated to the escalation
            channels while the condition lasts.
    """

    alert_class: AlertClass
    severity: Severity
    title: str
    instruction: str
    ladder: bool = False


_SPECS = (
    AlertSpec(
        AlertClass.TWOFA_PENDING,
        Severity.CRITICAL,
        "IBKR two-factor approval needed",
        "Approve the IBKR Mobile prompt now. The gateway cannot log in until you do; "
        "nothing approves it for you.",
        ladder=True,
    ),
    AlertSpec(
        AlertClass.NEEDS_HUMAN,
        Severity.CRITICAL,
        "The gateway is waiting for a human",
        "Open the gateway screen (VNC) or its log and resolve what it is waiting on. "
        "It will not retry on its own.",
        ladder=True,
    ),
    AlertSpec(
        AlertClass.LOGIN_FAILED,
        Severity.ERROR,
        "IBKR login failed",
        "Check the username and password secrets and whether the account is locked. "
        "Repeated failed logins can lock the account.",
    ),
    AlertSpec(
        AlertClass.EXISTING_SESSION,
        Severity.ERROR,
        "Another session is using this IBKR username",
        "Log out the other session (TWS, Client Portal or another gateway) or give this "
        "gateway its own username: IBKR allows one session per username.",
    ),
    AlertSpec(
        AlertClass.LOGIN_STALLED,
        Severity.ERROR,
        "The gateway login has not completed",
        "Look at the gateway screen and log: the gateway reports that its login has been "
        "in progress for longer than its LOGIN_STALL_S.",
    ),
    AlertSpec(
        AlertClass.UNKNOWN_WINDOW,
        Severity.WARNING,
        "The gateway shows a dialog that is not recognised",
        "Look at the gateway screen (VNC), handle the dialog, and report its title so it "
        "can be classified.",
    ),
    AlertSpec(
        AlertClass.GATEWAY_EXITED,
        Severity.CRITICAL,
        "The gateway stopped unexpectedly",
        "Read the gateway container's log for the reason. If it is not running, start it "
        "when it is safe: a start needs a new login and two-factor approval.",
    ),
    AlertSpec(
        AlertClass.GATEWAY_STOPPED,
        Severity.INFO,
        "The gateway was stopped on request",
        "No action needed if the stop was intended. The gateway stays down until someone "
        "starts it; a start needs a new login and two-factor approval.",
    ),
    AlertSpec(
        AlertClass.API_UNHEALTHY,
        Severity.ERROR,
        "The gateway API is not healthy",
        "Read /status for the reason (connectivity, data farm, client id, timeouts). Do "
        "not restart blindly: a restart forces a new login and two-factor approval.",
    ),
    AlertSpec(
        AlertClass.RESTART_STORM,
        Severity.ERROR,
        "The gateway keeps restarting",
        "Stop the restart loop and read the first error in the container log. Every "
        "restart costs a login attempt.",
    ),
    AlertSpec(
        AlertClass.RESOURCE_ALERT,
        Severity.ERROR,
        "Gateway memory pressure or an out-of-memory kill",
        "Raise the container memory limit or lower the Java heap, and check the host log "
        "for the out-of-memory kill.",
    ),
    AlertSpec(
        AlertClass.DISK_LOW,
        Severity.WARNING,
        "Disk space is low on a gateway volume",
        "Free space on the log or settings volume. A full disk stops logging and can "
        "corrupt the gateway settings.",
    ),
    AlertSpec(
        AlertClass.CLOCK_SKEW,
        Severity.WARNING,
        "The host clock differs from IBKR time",
        "Fix time synchronisation on the host (chrony or NTP; on Docker Desktop or WSL2 "
        "restart the VM clock sync).",
    ),
    AlertSpec(
        AlertClass.GATEWAY_SILENT,
        Severity.ERROR,
        "The gateway has gone silent",
        "No event and no metrics sample for five minutes. Check that the gateway "
        "container is running and that the log volume is mounted.",
    ),
    AlertSpec(
        AlertClass.VOLUME_MISSING,
        Severity.ERROR,
        "The sidecar cannot read the gateway's log volume",
        "Mount the gateway's log volume read-only at GATEWAY_LOG_DIR in the sidecar and "
        "check that the gateway writes state/phase there. Until then nothing about the "
        "gateway is measured and no other alert can fire.",
    ),
    AlertSpec(
        AlertClass.HEARTBEAT,
        Severity.INFO,
        "Daily heartbeat",
        "No action needed. The sidecar is running and no alert is active.",
    ),
)

CATALOG: dict[AlertClass, AlertSpec] = {spec.alert_class: spec for spec in _SPECS}
"""Every alert class with its specification."""

CONDITION_CLASSES: tuple[AlertClass, ...] = tuple(
    spec.alert_class for spec in _SPECS if spec.alert_class is not AlertClass.HEARTBEAT
)
"""Classes that are conditions (everything but the heartbeat), in catalogue order."""

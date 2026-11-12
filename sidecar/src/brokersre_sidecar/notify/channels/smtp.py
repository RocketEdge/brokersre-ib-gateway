"""E-mail through SMTP with mandatory TLS (implicit for ``smtps://``, STARTTLS for ``smtp://``).

``smtplib`` is blocking, so a send runs in a worker thread; its socket operations are
bounded by the timeout passed to the session. Failures are mapped to ``DeliveryError``
categories; the server's reply text is never kept (it can echo addresses or credentials).
"""

from __future__ import annotations

import asyncio
import smtplib
import ssl
from collections.abc import Callable
from email.message import EmailMessage
from email.utils import format_datetime, make_msgid
from types import TracebackType
from typing import Protocol

from brokersre_sidecar.clock import parse_utc
from brokersre_sidecar.config.secrets import SmtpTarget
from brokersre_sidecar.notify.channels.base import DeliveryError
from brokersre_sidecar.notify.message import Message


class SmtpSession(Protocol):
    """The part of ``smtplib.SMTP`` the channel uses (a context manager that quits on exit)."""

    def __enter__(self) -> SmtpSession:
        """Enter the session."""
        ...

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> object:
        """Send QUIT and close the connection."""
        ...

    def login(self, user: str, password: str) -> object:
        """Authenticate."""
        ...

    def send_message(self, msg: EmailMessage) -> object:
        """Submit one e-mail."""
        ...


SmtpOpener = Callable[[SmtpTarget, float], SmtpSession]
"""Opens a TLS-protected SMTP session (``open_smtp`` in production, a fake in tests)."""


def open_smtp(target: SmtpTarget, timeout_s: float) -> smtplib.SMTP:
    """Open a TLS-protected SMTP session.

    Args:
        target: Host, port and TLS mode.
        timeout_s: Socket timeout of the connection and of every later command.

    Returns:
        A session on which TLS is already active: ``SMTP_SSL`` for implicit TLS, otherwise
        ``SMTP`` after a successful STARTTLS. Certificates are verified against the system
        trust store.

    Raises:
        smtplib.SMTPException, OSError: Connection, TLS or STARTTLS failure (a server
            without STARTTLS raises ``SMTPNotSupportedError``: mail is never sent in clear).
    """
    context = ssl.create_default_context()
    if target.implicit_tls:
        return smtplib.SMTP_SSL(target.host, target.port, timeout=timeout_s, context=context)
    session = smtplib.SMTP(target.host, target.port, timeout=timeout_s)
    try:
        session.starttls(context=context)
    except smtplib.SMTPException, OSError:
        session.close()
        raise
    return session


class SmtpChannel:
    """Sends one plain-text e-mail per message."""

    name = "smtp"

    def __init__(
        self,
        target: SmtpTarget,
        sender: str,
        recipients: tuple[str, ...],
        opener: SmtpOpener = open_smtp,
        timeout_s: float = 10.0,
    ) -> None:
        """Create the channel.

        Args:
            target: Where and how to submit mail (holds the password).
            sender: ``From`` address.
            recipients: ``To`` addresses.
            opener: Opens the session; replaced by a fake in tests.
            timeout_s: Socket timeout of the session.
        """
        self._target = target
        self._sender = sender
        self._recipients = recipients
        self._opener = opener
        self._timeout_s = timeout_s

    def wants(self, message: Message) -> bool:
        """Accept every message."""
        return True

    def build_email(self, message: Message) -> EmailMessage:
        """Render ``message`` as an e-mail (headline as subject, plain-text body)."""
        email = EmailMessage()
        email["Subject"] = message.headline
        email["From"] = self._sender
        email["To"] = ", ".join(self._recipients)
        sent_at = parse_utc(message.time_utc)
        if sent_at is not None:
            email["Date"] = format_datetime(sent_at)
        email["Message-ID"] = make_msgid(domain=self._sender.rsplit("@", 1)[-1])
        # Tell mail systems not to answer with out-of-office replies.
        email["Auto-Submitted"] = "auto-generated"
        email["X-Auto-Response-Suppress"] = "All"
        email.set_content(message.body_text())
        return email

    async def send(self, message: Message) -> None:
        """Send the e-mail from a worker thread.

        Raises:
            DeliveryError: ``smtp_auth``, ``smtp_refused`` and ``smtp_no_starttls`` and
                ``tls`` are final; ``smtp_disconnected``, ``smtp_error``, ``timeout`` and
                ``connect`` are retryable.
        """
        email = self.build_email(message)
        try:
            await asyncio.to_thread(self._send_blocking, email)
        except smtplib.SMTPAuthenticationError:
            raise DeliveryError("smtp_auth", retryable=False) from None
        except smtplib.SMTPRecipientsRefused, smtplib.SMTPSenderRefused, smtplib.SMTPDataError:
            raise DeliveryError("smtp_refused", retryable=False) from None
        except smtplib.SMTPNotSupportedError:
            raise DeliveryError("smtp_no_starttls", retryable=False) from None
        except smtplib.SMTPServerDisconnected:
            raise DeliveryError("smtp_disconnected", retryable=True) from None
        except smtplib.SMTPException:
            raise DeliveryError("smtp_error", retryable=True) from None
        except TimeoutError:
            raise DeliveryError("timeout", retryable=True) from None
        except ssl.SSLError:
            raise DeliveryError("tls", retryable=False) from None
        except OSError:
            raise DeliveryError("connect", retryable=True) from None

    def _send_blocking(self, email: EmailMessage) -> None:
        """Open the session, log in when credentials are configured, send, quit."""
        with self._opener(self._target, self._timeout_s) as session:
            if self._target.username is not None and self._target.password is not None:
                session.login(self._target.username, self._target.password.reveal())
            session.send_message(email)

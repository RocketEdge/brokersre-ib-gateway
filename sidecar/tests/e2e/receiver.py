"""Stand-in receiver for the end-to-end check: a notification channel and a dead-man check.

Writes one line per request to its standard output and answers 200:

* ``POST <body>`` for a notification (the generic webhook payload);
* ``PING body=<bytes> query=<bytes>`` for a dead-man ping (a GET below ``/ping/``).

The request path is never written: it is the secret part of both URLs.
"""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def log_line(line: str) -> None:
    """Write one line to the container log at once."""
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    """Logs what arrives; see the module docstring for the line formats."""

    def _body(self) -> bytes:
        """Read the request body (empty without a Content-Length)."""
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def _ok(self) -> None:
        """Answer 200 with an empty body."""
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:
        """Log a notification."""
        log_line("POST " + self._body().decode("utf-8", "replace").replace("\n", " "))
        self._ok()

    def do_GET(self) -> None:
        """Log a dead-man ping: only the sizes of what came with it."""
        path, _, query = self.path.partition("?")
        kind = "PING" if path.startswith("/ping/") else "GET"
        log_line(f"{kind} body={len(self._body())} query={len(query)}")
        self._ok()

    def log_message(self, format: str, *args: object) -> None:
        """Silence the default access log (it would print the secret path)."""


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

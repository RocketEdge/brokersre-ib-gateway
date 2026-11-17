#!/usr/bin/env python3
"""Fake IBKR download server for tests/bats/ci/build-image.bats (Python 3 standard library only).

Purpose: stand in for download2.interactivebrokers.com so the build helper can be tested
without contacting IBKR. It serves files from a directory and can change what a path returns
from one request to the next, which is how IBKR replacing a channel during a download is
simulated.

Contract:
    fake-ibkr.py ROOT PORT_FILE REQUEST_LOG
    - Listens on 127.0.0.1 on a free port and writes the port number to PORT_FILE once it
      accepts connections.
    - GET /<path>: when files ROOT/<path>.1, ROOT/<path>.2, ... exist, the n-th request of that
      path is answered with ROOT/<path>.<n>, and every request after the last numbered file with
      the last one; otherwise ROOT/<path>; otherwise 404. Content is read at request time, so a
      test may rewrite a file between requests.
    - Every request is appended to REQUEST_LOG as one line, `GET /<path>`.
    - Paths containing `..` are refused (404). No other method is served.
Side effects: one listening socket until the process is killed; writes PORT_FILE and REQUEST_LOG.
"""

import http.server
import os
import sys
import threading

ROOT, PORT_FILE, REQUEST_LOG = sys.argv[1], sys.argv[2], sys.argv[3]
_counts: dict[str, int] = {}
_lock = threading.Lock()


def _pick(path: str, count: int) -> str | None:
    """Return the file that answers the count-th request of path, or None for a 404."""
    base = os.path.join(ROOT, path)
    numbered = 0
    while os.path.isfile(f"{base}.{numbered + 1}"):
        numbered += 1
    if numbered:
        return f"{base}.{min(count, numbered)}"
    return base if os.path.isfile(base) else None


class Handler(http.server.BaseHTTPRequestHandler):
    """Serves GET from ROOT with per-path response sequences; logs every request."""

    def do_GET(self) -> None:  # noqa: N802 (name defined by BaseHTTPRequestHandler)
        """Answer one GET as described in the module docstring."""
        path = self.path.split("?", 1)[0].lstrip("/")
        with _lock:
            count = _counts.get(path, 0) + 1
            _counts[path] = count
            with open(REQUEST_LOG, "a", encoding="utf-8") as log:
                log.write(f"GET /{path}\n")
        chosen = None if ".." in path.split("/") else _pick(path, count)
        if chosen is None:
            self.send_error(404)
            return
        with open(chosen, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Keep the test output quiet; REQUEST_LOG is the record."""


def main() -> None:
    """Start the server, publish the port, serve until killed."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    tmp = f"{PORT_FILE}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    os.replace(tmp, PORT_FILE)
    server.serve_forever()


if __name__ == "__main__":
    main()

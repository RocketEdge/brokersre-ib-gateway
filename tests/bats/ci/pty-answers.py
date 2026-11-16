"""Type answers into a shell script through a pseudo-terminal, as a person at a terminal would.

Used by ``tests/bats/ci/doc-commands.bats`` to run the documentation's copy-paste blocks that
ask for a secret. The block runs under the shell named on the command line with its standard
input, output and error on a new pty. For each ``--answer PROMPT KIND VALUE`` in order, the
driver waits until PROMPT appears on the terminal, types VALUE and Enter (a carriage return,
which the terminal turns into a newline, as for a real keyboard), and finally waits for the
shell to exit.

Checks (one line per failure on standard error and exit 1; exit 0 when all hold):

- every prompt appears, in order, within ``PROMPT_TIMEOUT_S`` of the previous answer;
- before a ``hidden`` answer is typed the terminal has stopped echoing, within
  ``ECHO_OFF_TIMEOUT_S`` of its prompt, and no word of four or more characters of a hidden
  answer ever appears on the terminal;
- a ``shown`` answer appears on the terminal: this proves that the capture sees typed text,
  so the absence of a hidden answer means something;
- echo is on again once the shell has exited, so the person's terminal still works;
- the shell exits with status 0 within ``EXIT_TIMEOUT_S`` of the last answer.

The files the block writes are checked by the caller. Linux only: the echo flag is read from
the master side, which on Linux reports the terminal settings of the slave side.

Why a pty and not a pipe: ``stty`` and a shell's ``read -s`` act on a terminal only, bash's
``read -p`` prints its prompt only to a terminal, and whether a password is shown is a
property of the terminal. Standard library only; python3 3.9 or later (Ubuntu's runner
python is enough). No shebang: run it as ``python3 pty-answers.py``.
"""

from __future__ import annotations

import argparse
import os
import pty
import select
import signal
import sys
import termios
import time
from collections.abc import Callable

PROMPT_TIMEOUT_S = 10.0
ECHO_OFF_TIMEOUT_S = 5.0
EXIT_TIMEOUT_S = 10.0
POLL_S = 0.05
MIN_SECRET_WORD = 4


class Terminal:
    """The master side of a pty and everything the child has written to it so far.

    Attributes:
        fd: master file descriptor (owned; closed by the caller when done).
        screen: every byte read from the master, i.e. what the person would have seen,
            including the terminal's echo of typed input.
        eof: True once the slave side is closed by every process (read gives EIO or b"").

    """

    def __init__(self, fd: int) -> None:
        """Wrap the master descriptor ``fd`` of a freshly forked pty."""
        self.fd = fd
        self.screen = b""
        self.eof = False

    def read_available(self, wait_s: float) -> None:
        """Append what the child wrote within ``wait_s`` seconds; never blocks longer.

        Side effect: sets ``eof`` when the slave side has been closed.
        """
        if self.eof:
            time.sleep(wait_s)
            return
        ready, _, _ = select.select([self.fd], [], [], wait_s)
        if not ready:
            return
        try:
            chunk = os.read(self.fd, 4096)
        except OSError:
            # Linux reports EIO on the master once no process holds the slave side.
            self.eof = True
            return
        if not chunk:
            self.eof = True
            return
        self.screen += chunk

    def echo_is_on(self) -> bool | None:
        """Return the ECHO flag of the terminal, or None when it cannot be read."""
        try:
            return bool(termios.tcgetattr(self.fd)[3] & termios.ECHO)
        except termios.error:
            return None

    def wait_until(self, condition: Callable[[], bool], timeout_s: float) -> bool:
        """Read output until ``condition()`` is true or ``timeout_s`` passes; return which."""
        deadline = time.monotonic() + timeout_s
        while True:
            if condition():
                return True
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            self.read_available(min(POLL_S, left))


def secret_words(value: bytes) -> list[bytes]:
    """Return the words of ``value`` that are long enough to be recognised on a screen."""
    return [word for word in value.split() if len(word) >= MIN_SECRET_WORD]


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    """Parse the command line; see the module docstring for the meaning of each option."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--shell", required=True, help="shell that runs the script, e.g. zsh")
    parser.add_argument("--script", required=True, help="file holding the block to run")
    parser.add_argument("--cwd", required=True, help="folder the block runs in")
    parser.add_argument(
        "--answer",
        nargs=3,
        action="append",
        default=[],
        metavar=("PROMPT", "KIND", "VALUE"),
        help="KIND is 'shown' or 'hidden'; repeat for each prompt, in order",
    )
    arguments = parser.parse_args(argv)
    for _, kind, _ in arguments.answer:
        if kind not in ("shown", "hidden"):
            parser.error(f"answer kind must be 'shown' or 'hidden', not {kind!r}")
    return arguments


def start_child(shell: str, script: str, cwd: str) -> tuple[int, int]:
    """Fork ``shell script`` on a new pty in ``cwd``; return (pid, master fd).

    The child gets the caller's environment minus ``ENV`` and ``BASH_ENV``, so no start-up
    file of the test host changes what the block does.
    """
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.chdir(cwd)
            env = {k: v for k, v in os.environ.items() if k not in ("ENV", "BASH_ENV")}
            # The shell is the thing under test, named by the caller; no input reaches it.
            os.execvpe(shell, [shell, script], env)  # noqa: S606
        finally:
            os._exit(127)
    return pid, fd


def wait_for_exit(pid: int, terminal: Terminal) -> int | None:
    """Drain output until the child exits; return its exit code, or None after a kill."""
    deadline = time.monotonic() + EXIT_TIMEOUT_S
    while time.monotonic() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            terminal.read_available(0)
            return os.waitstatus_to_exitcode(status)
        terminal.read_available(POLL_S)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return None


def type_answers(terminal: Terminal, answers: list[list[str]]) -> list[str]:
    """Wait for each prompt in turn and type its answer; return the failed checks.

    A hidden answer is typed only once the terminal has stopped echoing, or after
    ``ECHO_OFF_TIMEOUT_S`` (then it is typed anyway, so that the screen check shows whether it
    was displayed). Stops at the first prompt that does not appear.
    """
    failures: list[str] = []
    seen_up_to = 0
    for prompt_text, kind, value_text in answers:
        prompt = prompt_text.encode()

        def prompt_shown(prompt: bytes = prompt, start: int = seen_up_to) -> bool:
            return prompt in terminal.screen[start:]

        if not terminal.wait_until(prompt_shown, PROMPT_TIMEOUT_S):
            failures.append(f"the prompt {prompt_text!r} did not appear")
            break
        seen_up_to = terminal.screen.index(prompt, seen_up_to) + len(prompt)
        if kind == "hidden" and not terminal.wait_until(
            lambda: terminal.echo_is_on() is False, ECHO_OFF_TIMEOUT_S
        ):
            failures.append(f"the terminal still echoed when {prompt_text!r} waited for input")
        os.write(terminal.fd, value_text.encode() + b"\r")
    return failures


def check_screen(screen: bytes, answers: list[list[str]]) -> list[str]:
    """Return the failed screen checks: shown answers visible, hidden answers never."""
    failures: list[str] = []
    for prompt_text, kind, value_text in answers:
        value = value_text.encode()
        if kind == "shown" and value.strip() not in screen:
            failures.append(f"the answer to {prompt_text!r} did not appear on the terminal")
        if kind == "hidden" and any(word in screen for word in secret_words(value)):
            failures.append(f"the answer to {prompt_text!r} appeared on the terminal")
    return failures


def run(arguments: argparse.Namespace) -> list[str]:
    """Run the block, type the answers and return the list of failed checks (empty: pass)."""
    pid, fd = start_child(arguments.shell, arguments.script, arguments.cwd)
    terminal = Terminal(fd)
    failures = type_answers(terminal, arguments.answer)
    code = wait_for_exit(pid, terminal)
    if code is None:
        failures.append(f"the shell did not exit within {EXIT_TIMEOUT_S:.0f} s of the last answer")
    elif code != 0:
        failures.append(f"the shell exited with status {code}")
    if terminal.echo_is_on() is not True:
        failures.append("echo was not on again after the block had run")
    failures += check_screen(terminal.screen, arguments.answer)
    os.close(fd)
    if failures:
        failures.append(f"terminal: {terminal.screen.decode('utf-8', 'replace')!r}")
    return failures


def main(argv: list[str]) -> int:
    """Entry point: print each failed check on standard error; exit 1 on any, else 0."""
    arguments = parse_arguments(argv)
    failures = run(arguments)
    for failure in failures:
        print(f"pty-answers: {arguments.shell}: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"pty-answers: {arguments.shell}: {len(arguments.answer)} answers typed, checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Type answers into a documented shell block through a pseudo-terminal, as a person would.

Used by ``tests/bats/ci/doc-commands.bats`` to run the documentation's copy-paste blocks that
ask for a secret. The block runs on a new pty under the shell named on the command line, in
one of two modes:

- ``script``: ``SHELL BLOCKFILE``, the block read from a file.
- ``paste``: an interactive ``SHELL -i`` with a clean environment and its own start-up file
  (prompt, history file and, for bash and zsh, bracketed paste ``on`` or ``off``). Once the
  shell shows its prompt, the whole block is written in ONE write with carriage returns as
  line ends, as a terminal emulator pastes it, wrapped in the bracketed-paste markers only
  while the shell has switched that mode on (``ESC[?2004h``). If no prompt of the block
  appears within ``ENTER_AFTER_S``, Enter is pressed, as a person does after a paste that
  waits. Without bracketed paste a shell reads a pasted block line by line, so the lines not
  yet run sit in the terminal's input and the block's first ``read`` takes one of them: what
  the person types next then runs as a command (on the screen and in the history).

For each ``--answer PROMPT KIND VALUE`` in order the driver waits until PROMPT is printed
(an occurrence right after a quote is the echo of the pasted command line and is skipped),
then for KIND ``shown`` or ``hidden`` types VALUE and Enter (a carriage return, which the
terminal turns into a newline), and for KIND ``interrupt`` presses Ctrl-C instead and types
nothing more. In paste mode it then waits for the shell's prompt and types ``exit``.

Checks (one line per failure on standard error and exit 1; exit 0 when all hold):

- every prompt appears, in order, within ``PROMPT_TIMEOUT_S`` of the previous answer;
- before a ``hidden`` answer or an ``interrupt`` the terminal has stopped echoing, within
  ``ECHO_OFF_TIMEOUT_S`` of its prompt, and no word of four or more characters of a hidden
  answer ever appears on the terminal or, in paste mode, in the shell's history file;
- a ``shown`` answer appears on the terminal: this proves that the capture sees typed text,
  so the absence of a hidden answer means something;
- in paste mode the shell's prompt comes back after the last answer, and echo is on there;
- echo is on again once the shell has exited, so the person's terminal still works;
- the shell exits within ``EXIT_TIMEOUT_S``, with status 0 unless an answer was an
  ``interrupt``.

The files the block writes are checked by the caller. Linux only: the echo flag is read from
the master side, which on Linux reports the terminal settings of the slave side.

Why a pty and not a pipe: ``stty`` and a shell's ``read -s`` act on a terminal only, bash's
``read -p`` prints its prompt only to a terminal, an interactive shell's line editor needs
one, and whether a password is shown is a property of the terminal. Standard library only;
python3 3.9 or later (Ubuntu's runner python is enough). No shebang: run it as
``python3 pty-answers.py``.
"""

from __future__ import annotations

import argparse
import os
import pty
import re
import select
import signal
import sys
import termios
import time
from collections.abc import Callable

PROMPT_TIMEOUT_S = 10.0
ECHO_OFF_TIMEOUT_S = 5.0
EXIT_TIMEOUT_S = 10.0
ENTER_AFTER_S = 1.5
SETTLE_S = 0.3
POLL_S = 0.05
MIN_SECRET_WORD = 4
SHELL_PROMPT = b"pty-answers$ "
BRACKETED_PASTE_ON = b"\x1b[?2004h"
BRACKETED_PASTE_OFF = b"\x1b[?2004l"
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"
CTRL_C = b"\x03"
QUOTES = (b"'", b'"')
# stty -a lists the local flags separated by blanks (GNU) or blanks and semicolons (busybox).
ECHO_FLAG = re.compile(rb"(^|[\s;])(-?echo)(?=[\s;]|$)", re.MULTILINE)


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
            chunk = os.read(self.fd, 65536)
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

    def settle(self, seconds: float) -> None:
        """Keep reading output for ``seconds``, e.g. while a shell sets its terminal modes."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.read_available(POLL_S)

    def bracketed_paste_on(self) -> bool:
        """Return whether the shell has switched bracketed paste on, as a terminal tracks it."""
        return self.screen.rfind(BRACKETED_PASTE_ON) > self.screen.rfind(BRACKETED_PASTE_OFF)


def printed_prompt_end(screen: bytes, prompt: bytes, start: int) -> int:
    """Return the index just after PROMPT printed at or after ``start``, or -1.

    An occurrence right after a quote character is the terminal's echo of a pasted command
    line (``printf 'IBKR password: '``), not the prompt the command prints, and is skipped.
    """
    position = start
    while True:
        found = screen.find(prompt, position)
        if found < 0:
            return -1
        if found == 0 or screen[found - 1 : found] not in QUOTES:
            return found + len(prompt)
        position = found + 1


def secret_words(value: bytes) -> list[bytes]:
    """Return the words of ``value`` that are long enough to be recognised on a screen."""
    return [word for word in value.split() if len(word) >= MIN_SECRET_WORD]


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    """Parse the command line; see the module docstring for the meaning of each option."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--shell", required=True, help="shell that runs the block, e.g. zsh")
    parser.add_argument("--script", required=True, help="file holding the block to run")
    parser.add_argument("--cwd", required=True, help="folder the block runs in")
    parser.add_argument("--mode", choices=("script", "paste"), default="script")
    parser.add_argument(
        "--bracketed-paste",
        choices=("on", "off"),
        default="off",
        help="paste mode, bash and zsh: the shell's bracketed-paste setting",
    )
    parser.add_argument("--home", help="paste mode: folder for start-up file and history")
    parser.add_argument(
        "--answer",
        nargs=3,
        action="append",
        default=[],
        metavar=("PROMPT", "KIND", "VALUE"),
        help="KIND is 'shown', 'hidden' or 'interrupt'; repeat for each prompt, in order",
    )
    arguments = parser.parse_args(argv)
    for _, kind, _ in arguments.answer:
        if kind not in ("shown", "hidden", "interrupt"):
            parser.error(f"answer kind must be shown, hidden or interrupt, not {kind!r}")
    if arguments.mode == "paste" and not arguments.home:
        parser.error("--mode paste needs --home")
    return arguments


def interactive_shell(
    shell: str, home: str, bracketed_paste: str
) -> tuple[list[str], dict[str, str]]:
    """Return argv and environment of an interactive SHELL whose start-up file lives in HOME.

    The start-up file sets the prompt (``SHELL_PROMPT``), a history file ``HOME/history`` and,
    for bash and zsh, the bracketed-paste setting. Other shells (dash, busybox sh) read it
    through ``ENV`` and have no bracketed paste. The environment is clean apart from PATH, so
    no start-up file of the test host changes what the block does.
    """
    os.makedirs(home, exist_ok=True)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TERM": "xterm-256color",
        "HOME": home,
        "LANG": "C.UTF-8",
    }
    history = os.path.join(home, "history")
    lines = [f"PS1='{SHELL_PROMPT.decode()}'", "PS2='> '", f"HISTFILE={history}"]
    name = os.path.basename(shell)
    if name == "bash":
        lines.append(f"bind 'set enable-bracketed-paste {bracketed_paste}'")
        rc = os.path.join(home, "bashrc")
        argv = [shell, "--rcfile", rc, "-i"]
    elif name == "zsh":
        lines += ["SAVEHIST=100", "HISTSIZE=100"]
        if bracketed_paste == "off":
            lines.append("unset zle_bracketed_paste")
        rc = os.path.join(home, ".zshrc")
        env["ZDOTDIR"] = home
        # .zshenv is read before /etc/zsh/zshrc: without GLOBAL_RCS no host start-up file
        # runs. Ubuntu's runs compinit, which on the GitHub runner stopped at "Ignore
        # insecure directories and continue [y] or abort compinit [n]?" (a writable fpath
        # directory), so the test's prompt never came.
        with open(os.path.join(home, ".zshenv"), "w", encoding="utf-8") as zshenv:
            zshenv.write("unsetopt GLOBAL_RCS\n")
        argv = [shell, "-i"]
    else:
        rc = os.path.join(home, "shrc")
        env["ENV"] = rc
        argv = [shell, "-i"]
    with open(rc, "w", encoding="utf-8") as start_up:
        start_up.write("\n".join(lines) + "\n")
    return argv, env


def start_child(argv: list[str], env: dict[str, str], cwd: str) -> tuple[int, int]:
    """Fork ``argv`` on a new pty in ``cwd`` with environment ``env``; return (pid, fd)."""
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.chdir(cwd)
            # The shell is the thing under test, named by the caller; no input reaches it.
            os.execvpe(argv[0], argv, env)  # noqa: S606
        finally:
            os._exit(127)
    return pid, fd


def paste_block(terminal: Terminal, block: bytes, first_prompt: bytes) -> tuple[int, list[str]]:
    """Paste BLOCK into the interactive shell; return (screen index of the paste, failures).

    Waits for the shell's prompt first. Presses Enter when FIRST_PROMPT has not been printed
    within ``ENTER_AFTER_S`` (with bracketed paste the shell waits for it).
    """
    if not terminal.wait_until(lambda: SHELL_PROMPT in terminal.screen, PROMPT_TIMEOUT_S):
        return len(terminal.screen), ["the interactive shell did not show its prompt"]
    terminal.settle(SETTLE_S)
    data = block.rstrip(b"\n").replace(b"\n", b"\r") + b"\r"
    if terminal.bracketed_paste_on():
        data = PASTE_START + data + PASTE_END
    pasted_at = len(terminal.screen)
    os.write(terminal.fd, data)
    if not terminal.wait_until(
        lambda: printed_prompt_end(terminal.screen, first_prompt, pasted_at) >= 0, ENTER_AFTER_S
    ):
        os.write(terminal.fd, b"\r")
    return pasted_at, []


def type_answers(terminal: Terminal, answers: list[list[str]], start: int) -> list[str]:
    """Wait for each prompt in turn after screen index START and answer it; return failures.

    A hidden answer or an interrupt is typed only once the terminal has stopped echoing, or
    after ``ECHO_OFF_TIMEOUT_S`` (then it is typed anyway, so that the screen check shows
    whether it was displayed). Stops at the first prompt that does not appear and after an
    interrupt.
    """
    failures: list[str] = []
    cursor = start
    for prompt_text, kind, value_text in answers:
        prompt = prompt_text.encode()

        def prompt_printed(prompt: bytes = prompt, start: int = cursor) -> bool:
            return printed_prompt_end(terminal.screen, prompt, start) >= 0

        if not terminal.wait_until(prompt_printed, PROMPT_TIMEOUT_S):
            failures.append(f"the prompt {prompt_text!r} did not appear")
            break
        cursor = printed_prompt_end(terminal.screen, prompt, cursor)
        if kind in ("hidden", "interrupt") and not terminal.wait_until(
            lambda: terminal.echo_is_on() is False, ECHO_OFF_TIMEOUT_S
        ):
            failures.append(f"the terminal still echoed when {prompt_text!r} waited for input")
        if kind == "interrupt":
            os.write(terminal.fd, CTRL_C)
            break
        os.write(terminal.fd, value_text.encode() + b"\r")
    return failures


def echo_flag(output: bytes) -> bytes | None:
    """Return ``b"echo"`` or ``b"-echo"`` as ``stty -a`` printed it in OUTPUT, or None."""
    match = ECHO_FLAG.search(output)
    return match.group(2) if match else None


def leave_shell(terminal: Terminal, after: int) -> list[str]:
    """Paste mode: wait for the shell's prompt after screen index AFTER, check echo, exit.

    At the prompt a line editor holds the terminal in raw mode, so the flag read from the
    pty says nothing about what the block left behind; ``stty -a``, run as a command, reports
    the settings the shell restores for commands. Presses Ctrl-C first when the prompt does
    not come back (a block still waiting in ``read``).
    """
    failures: list[str] = []
    if not terminal.wait_until(lambda: SHELL_PROMPT in terminal.screen[after:], PROMPT_TIMEOUT_S):
        failures.append("the shell's prompt did not come back after the last answer")
        os.write(terminal.fd, CTRL_C)
    terminal.settle(SETTLE_S)
    mark = len(terminal.screen)
    os.write(terminal.fd, b"stty -a\r")
    if not terminal.wait_until(lambda: echo_flag(terminal.screen[mark:]) is not None, 5.0):
        failures.append("stty -a showed no echo flag at the shell's prompt")
    elif echo_flag(terminal.screen[mark:]) == b"-echo":
        failures.append("echo was off at the shell's prompt after the block")
    terminal.settle(SETTLE_S)
    os.write(terminal.fd, b"exit\r")
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


def check_history(home: str, answers: list[list[str]]) -> list[str]:
    """Return a failure for each hidden answer found in the shell's history file."""
    try:
        with open(os.path.join(home, "history"), "rb") as history_file:
            history = history_file.read()
    except FileNotFoundError:
        return []
    return [
        f"the answer to {prompt_text!r} is in the shell's history"
        for prompt_text, kind, value_text in answers
        if kind == "hidden" and any(word in history for word in secret_words(value_text.encode()))
    ]


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


def run(arguments: argparse.Namespace) -> list[str]:
    """Run the block, type the answers and return the list of failed checks (empty: pass)."""
    with open(arguments.script, "rb") as block_file:
        block = block_file.read()
    if arguments.mode == "paste":
        argv, env = interactive_shell(arguments.shell, arguments.home, arguments.bracketed_paste)
    else:
        argv = [arguments.shell, arguments.script]
        env = {k: v for k, v in os.environ.items() if k not in ("ENV", "BASH_ENV")}
    pid, fd = start_child(argv, env, arguments.cwd)
    terminal = Terminal(fd)
    failures: list[str] = []
    start = 0
    if arguments.mode == "paste" and arguments.answer:
        start, failures = paste_block(terminal, block, arguments.answer[0][0].encode())
    if not failures:
        failures += type_answers(terminal, arguments.answer, start)
    if arguments.mode == "paste":
        failures += leave_shell(terminal, len(terminal.screen))
    code = wait_for_exit(pid, terminal)
    interrupted = any(kind == "interrupt" for _, kind, _ in arguments.answer)
    if code is None:
        failures.append(f"the shell did not exit within {EXIT_TIMEOUT_S:.0f} s of the last answer")
    elif code != 0 and not interrupted:
        failures.append(f"the shell exited with status {code}")
    if terminal.echo_is_on() is not True:
        failures.append("echo was not on again after the shell had exited")
    failures += check_screen(terminal.screen, arguments.answer)
    if arguments.mode == "paste":
        failures += check_history(arguments.home, arguments.answer)
    os.close(fd)
    if failures:
        failures.append(f"terminal: {terminal.screen.decode('utf-8', 'replace')!r}")
    return failures


def main(argv: list[str]) -> int:
    """Entry point: print each failed check on standard error; exit 1 on any, else 0."""
    arguments = parse_arguments(argv)
    failures = run(arguments)
    label = f"{arguments.shell} ({arguments.mode})"
    for failure in failures:
        print(f"pty-answers: {label}: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"pty-answers: {label}: {len(arguments.answer)} answers typed, checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

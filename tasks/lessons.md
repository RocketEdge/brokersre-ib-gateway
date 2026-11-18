# tasks/lessons.md — brokersre-ib-gateway

## 2026-11-01 — Test the scripts with the toolchain they ship with

**Pattern:** the bats image is Alpine-based (busybox `date`, no `envsubst`), so unit tests written
against it would pass or fail for reasons unrelated to production.

**Rule:** run the bats suite inside the built image (`tests/bats/run-in-image.sh`) with bats-core
mounted from the host; keep scripts free of GNU-only constructs where a bash builtin exists
(`EPOCHREALTIME` + `printf %(...)T` instead of `date %N`).

## 2026-11-01 — Windows checkouts put CRLF into files that run inside Linux containers

**Pattern:** `git clone` of bats-core on Windows applied `core.autocrlf=true`, so `bin/bats`
began with `#!/usr/bin/env bash\r` and the image's `env` failed with `$'bash\r': No such file
or directory`. MSYS `grep $'\r'` did not report the carriage returns (text-mode handling), which
pointed the investigation at the wrong files; `file(1)` said "with CRLF line terminators" at once.

**Rule:** clone test tooling with `git -c core.autocrlf=false -c core.eol=lf clone ...`; keep
`* text=auto eol=lf` in `.gitattributes`; diagnose line endings with `file`, never with `grep`.

## 2026-11-01 — A tmpfs mount is root-owned unless the mount options say otherwise

**Pattern:** `--tmpfs /run/brokersre` produced a `0:0` directory with mode 755; the uid-1000
entrypoint died on `mkdir` with an unstructured stderr line and the read-only container test
reported only "relay never listened".

**Rule:** every tmpfs the gateway writes to carries `uid=1000,gid=1000,mode=0750` (reference
compose and test harness); the entrypoint verifies writability first and reports
`dirs_not_writable` on stdout; the harness has a negative test for the root-owned case.

## 2026-11-12 — A Windows host does not record the execute bit, and hides that it is missing

**Pattern:** `screenshot.sh` was added from the Windows host as `100644`. Git Bash, the Docker
Desktop share and the fast local runner all ran it anyway, the image sets 0755 itself, so unit
and container suites were green locally; the first Linux run failed with "Permission denied".

**Rule:** add scripts with `git add --chmod=+x`; `scripts/check-file-modes.sh` reads the index
(`git ls-files -s`) and fails on a tracked `*.sh` without the bit, in the lint job and before a
push. Check the index, never the file system, for anything the host presents differently.

## 2026-11-16 — Containers created together are not containers started one after the other

**Pattern:** the gateway and the sidecar share a named volume. Every test started them with
`docker run`, one after the other, so the gateway had written to the volume before the sidecar
existed. `docker compose up` creates both first: the empty volume then took the owner of the
sidecar image's root-owned mount point, and the gateway could not write its own logs. The
compose files were only rendered in CI, never started together; the first real session found
it in a minute by doing what the README says.

**Rule:** a file users copy is tested the way users run it: `docker compose up` on fresh
volumes, both containers created before either starts. An image never carries a directory at
a path where another image's volume is mounted, and a reader of a shared volume mounts it with
`nocopy`.

## 2026-11-18 — A port the test picks can be taken; a readiness poll must survive errexit

**Pattern:** two unit suites started socat on a random port from 40000-59999 and probed it for
5 s. That range lies inside Linux's ephemeral range, and a client that closes first keeps its
own port in TIME_WAIT for 60 s, so now and then the drawn port was an earlier client's: socat
failed with "Address already in use" (reuseaddr does not help against a socket made without
it), exited, and its error went to /dev/null. CI showed only "serve failed" after 5.4 s, twice.
The first version of the fix then read socat's log with a bare `line="$(grep ...)"`: under
bats' errexit the first poll that found nothing ended the test. It passed on an idle machine
and failed 259 of 300 loop runs once socat started a little later (busy container, socat
behind a logging wrapper). Only the loop showed it.

**Rule:** a test listener takes port 0 and learns its port from the server (socat's
`listening on` notice), and the helper prints the server's own log when it does not come up.
Poll with `if x="$(...)"; then` in code that runs under errexit. Prove a flake fix with a loop
under the failing condition (and under load) before and after, not with one green run.

## 2026-11-18 — A test that needs a TCP state must force who closes first

**Pattern:** the regression test for the fix above needed "a port an earlier client still
holds". Its server ran `exit 0` and the test waited 2 s for `state time-wait` on the client.
The independent review's loop failed it once: when the server closed first, the TIME_WAIT was
the server's, and before the server closes the client sits in FIN-WAIT-2, which that filter
does not show. My own load loop never hit it (0 of 200); a client that closes 0.3 s late made
it fail every time.

**Rule:** when a test needs a socket state, force the order that produces it (a server that
only reads, so the client closes first), accept every state that has the property the test
needs (FIN-WAIT-2 and TIME_WAIT both hold the port), and reproduce a suspected race by
delaying one side deterministically instead of hoping a load loop hits it.

## 2026-11-18 — A probe outside bats has no errexit; a rewrite in place races exec

**Pattern:** `serve` rewrote `WORK/server.sh` in place, and a write to a file that is in
`execve()` fails with "Text file busy". A probe script that called `serve` 600 times beside 8
exec loops reported no failure: outside bats there is no errexit, so the refused write did not
stop `serve`, which went on and returned 0. Read under bats, the same loop failed 30 of 30
runs, and a tight write loop showed 43 % of writes refused.

**Rule:** a probe of a test helper runs the helper as the tests do (under errexit) or checks
its stderr whatever it returns. A file that something may execute is replaced by writing a new
file and renaming it onto the name, never rewritten in place.

**Pattern (same day):** six stress-loop containers ran `sleep infinity` as PID 1. Every
`stop_servers` orphans socat, bash, sleep, dd and od processes, and a PID 1 that never reaps
kept each as a zombie (2 to 12 per suite run, more with a logging wrapper). After about 5 h
every `fork()` failed and the loops hung without failing. In CI the suite's PID 1 is bats (a
bash process), which reaps: started that way, no zombie with parent PID 1 appeared in 179
samples. A first check through one `docker exec` per second got 4 samples per run on this host
and reported "at most 1 zombie", which the review could not reproduce: sample inside the
container, and count zombies by parent, because a test's own short-lived children show up too.

**Rule:** an experiment container gets a reaping PID 1 (`docker run --init`), every loop run
a `timeout`, the loop an overall deadline, and its log a process count every few runs.

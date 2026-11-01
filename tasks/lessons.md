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

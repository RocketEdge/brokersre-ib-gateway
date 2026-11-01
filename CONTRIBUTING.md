# Contributing

Issues and pull requests are welcome. Please read `CLAUDE.md` (the project contract, identical
to `.github/copilot-instructions.md`) first.

- **Tests first.** Behaviour changes to the scripts come with a bats unit test under
  `tests/bats/unit/` or a case in `tests/container/run.sh`; `ci.yml` runs both.
- **Lint locally.** `pre-commit run --all-files` runs hadolint, shellcheck, shfmt, gitleaks and
  markdownlint with the same versions CI uses.
- **Versions live in `versions.json` only.** Do not edit versions in the Dockerfile or
  workflows; the detection workflows open the pull requests, humans merge them.
- **Never commit a credential**, an installer or a `jts.ini` from a real account.
- **Conventional Commits** (`feat`, `fix`, `build`, `ci`, `docs`, `test`, `chore`), one logical
  change per commit; append to `docs/changes.md` with what changed, the result and what did not
  work.
- Trademark hygiene: refer to "IB Gateway" and "Interactive Brokers" nominatively; never use the
  IBKR logo.

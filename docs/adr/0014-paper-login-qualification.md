# ADR 0014 — A paper-login qualification that is not a test: one attended login, behind a reviewer

- **Status:** Accepted (2026-11-12)

## Context

Invariant 9 says "tests never log in", and the IBC smoke test runs with `--network none`. That
kept credentials out of CI, and it also meant no release of this image had ever logged in
(`docs/limitations.md` L04). The first operator-run login (2026-11-12, `docs/changes.md`)
found a login that could not complete in the documented configuration and two wrong
classifier patterns. All three were invisible to the offline tests, because the Gateway only
shows that behaviour after it has connected to IBKR.

Other images that gate releases on a login store the credentials for ordinary CI. That exposes
them to every workflow change, and a job that retries can lock the account.

## Decision

1. **Invariant 9 keeps its meaning for CI**: nothing triggered by a push or a pull request
   contacts IBKR's login servers, and no test does.
2. **Qualification is a separate act**, `scripts/qualify-paper.sh`: one login to a PAPER account
   with the read-only API, in the hardened reference configuration, followed by checks (phase,
   health check, API handshake, relay, a complete and gap-free event sequence, no unhandled
   window, graceful stop) and a result document, `brokersre.qualification.v1`.
3. **One attempt, attended**: the container has no restart policy, a second-factor timeout ends
   IBC, and the script starts nothing twice. It never answers, types or bypasses a second
   factor; when IBKR asks for one, a person approves it.
4. **In GitHub it runs only by hand** (`qualify-paper.yml`, `workflow_dispatch`), only from
   `main`, only for an image given by digest, in the environment `paper-qualification`:
   required reviewer, deployments from `main` only, credentials as environment secrets. A pull
   request, including one from a fork, cannot reach them. A concurrency group allows one run at
   a time, because IBKR allows one session per username.
5. **The API check is the protocol handshake only** (`api-handshake.sh`): it proves the API
   answers without taking a client id or making a request, so qualification cannot place,
   change or cancel an order.
6. **A passed qualification can be attached to the image** as a signed attestation of type
   `…/attestations/qualified-paper/v1`. Moving `stable` only after such an attestation exists
   is a later step; it needs a record of passes first.

## Consequences

### Positive

- A Gateway or IBC change that breaks the login can be found before users find it, with a
  record anyone can verify.
- The credentials are used by one workflow that a reviewer approves each time; a wrong password
  costs one failed login, not a lockout.
- The same script runs on a workstation and in GitHub, so a result is reproducible.

### Negative

- It is manual: nobody is told when a new IBKR build has not been qualified yet.
- A GitHub-hosted runner logs in from a changing address; IBKR may ask for a second factor
  there even if it does not on a workstation, and then a person must be at the phone.
- The qualification covers a fresh login only. The daily restart, the weekly re-authentication
  and a competing session need longer observation.
- The result and the collected events are uploaded as a workflow artifact of a public
  repository. They hold no username, password or account id by contract; a defect in that
  contract would be public.

## Revisit trigger

Three consecutive passes exist (then gate `stable` on the attestation); or IBKR objects to
automated paper logins; or a second maintainer needs to run it (then move the credentials to a
store with its own audit trail).

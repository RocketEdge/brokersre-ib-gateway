# Is a newer image available?

Gateways pin the image by digest, so a new build never reaches them by itself
([upgrade policy](upgrade-policy.md)). `scripts/check-upgrade.sh` answers one question: does
the channel tag (`stable` or `latest`, IBKR's channel names) point at something else than the
digest this gateway runs?

It only asks and reports. It never pulls, starts, stops, restarts or edits anything; whether
and when to move to the new digest stays a person's decision
([verifying an image](../README.md#verifying-an-image) comes first).

## Use

```bash
# A container on this Docker host; the channel comes from the image's label.
scripts/check-upgrade.sh --container ib-gateway

# A digest from a deployment file; nothing has to run here.
scripts/check-upgrade.sh --image ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<digest> --channel stable

# A gateway that runs from your own mirror: ask the publishing repository's tag.
scripts/check-upgrade.sh --container ib-gateway --repository ghcr.io/rocketedge/brokersre-ib-gateway
```

A reference with only a tag is refused: a tag says what the registry serves now, not what
you run. For a container that was created from a tag, the script uses the registry digest
Docker recorded for the image the container really runs.

It needs bash 4 or newer, Docker with the buildx plugin and `sha256sum` (or `shasum`); the
registry is read with the credentials `docker` already has. One run makes one registry
request: `docker buildx imagetools inspect --raw <repository>:<channel>` returns the tag's
manifest without pulling anything, and the tag's digest is the SHA-256 of those bytes.

## Answer

One JSON document on one line on stdout, in every case:

```json
{"schema":"brokersre.upgrade-check.v1","checked_at":"2026-11-12T06:49:04Z","result":"upgrade-available","up_to_date":false,"repository":"ghcr.io/rocketedge/brokersre-ib-gateway","channel":"stable","channel_source":"label","running_digest":"sha256:<what runs>","registry_digest":"sha256:<what the tag points at>"}
```

| Exit status | `result` | `up_to_date` | Meaning |
|---|---|---|---|
| 0 | `up-to-date` | `true` | The gateway runs what the channel tag points at (or one platform of that multi-arch image). |
| 10 | `upgrade-available` | `false` | The tag points at another digest. Channel tags only move forward, so that is a newer image. |
| 2 | `undetermined` | `null` | No answer: bad arguments, no such container, an image without a registry digest (built locally), the registry not reachable or refusing (a rate limit, for example), or an answer that is no manifest. `error` says which; an unknown value is `null`. |

A check that failed is never reported as "up to date".

## Run it on a schedule, to be told and nothing more

Both examples only write the answer down and raise a flag; neither changes the gateway.

Linux, in the crontab of a user who may use Docker (07:15 on weekdays; a line in the system
log when the answer is not "up to date"):

```text
15 7 * * 1-5 cd /opt/brokersre-ib-gateway && scripts/check-upgrade.sh --container ib-gateway >/var/tmp/ibgw-upgrade.json 2>/dev/null; rc=$?; [ "$rc" -eq 0 ] || logger -t ibgw-upgrade -p user.warning "exit $rc: $(cat /var/tmp/ibgw-upgrade.json)"
```

Windows with Docker Desktop and Git for Windows: save this as
`C:\ibgw\Check-GatewayUpgrade.ps1` and adjust the two paths.

```powershell
Set-Location 'C:\ibgw\brokersre-ib-gateway'
$document = & 'C:\Program Files\Git\bin\bash.exe' scripts/check-upgrade.sh --container ib-gateway 2>$null
$status = $LASTEXITCODE
Set-Content -Path 'C:\ibgw\upgrade-check.json' -Value $document -Encoding utf8
exit $status
```

Register it once (07:15 every day):

```powershell
schtasks /Create /TN "IB Gateway upgrade check" /SC DAILY /ST 07:15 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ibgw\Check-GatewayUpgrade.ps1"
```

Task Scheduler then shows the last run result `0x0` (up to date), `0xA` (a newer image is
available) or `0x2` (no answer), and `C:\ibgw\upgrade-check.json` holds the document. Attach
the alert your site uses to a non-zero result.

Watching the releases is the other way to be told, without running anything:
[Get notified of new images](../README.md#get-notified-of-new-images).

## What was tested

- Every case above with a stand-in `docker` that records each call
  (`tests/bats/ci/check-upgrade.bats`): equal and different digests, a platform digest, a
  container created from a tag, a missing container, a registry error, an answer that is no
  manifest, a tag-only reference, hostile input, and that only three read-only Docker commands
  are ever run, the registry one exactly once.
- By hand on 2026-11-12, with the real Docker CLI (29.9.3, buildx 0.38.1) against public
  multi-arch images of other projects: exit 0, 10 and 2 (an unknown host, a tag that does not
  exist); the hash of the raw manifest equalled the digest buildx prints on three registries.
  A first version asked for the formatted digest, which makes buildx fetch every platform's
  manifest: two registries answered that with "429 Too Many Requests", and the script
  reported exit 2, not "up to date". The raw request is one request and went through. The
  PowerShell wrapper passed all three exit statuses through under Windows PowerShell 5.1 and
  PowerShell 7.
- Not tested: the crontab line and the `schtasks` registration on a real schedule, a private
  registry, and `shasum` in place of `sha256sum`.

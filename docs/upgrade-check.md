# Is a newer IB Gateway available?

RocketEdge no longer distributes a public image: you build it ([README, "Build the image"](../README.md#build-the-image)),
and nothing you run changes until you build again. Two questions, two tools; both only ask and
report, and neither downloads, builds, pulls, starts, stops or restarts anything. Whether and
when to rebuild and move stays a person's decision
([verifying what you built](../README.md#verifying-what-you-built) comes after every build).

## An image you built: does IBKR serve another Gateway?

```bash
scripts/build-image.sh --print-plan | grep '^version:'
docker image inspect brokersre-ib-gateway:stable --format '{{index .Config.Labels "com.rocketedge.brokersre.ibkr.version"}}'
```

The first line is the build IBKR's channel serves now, the second the build in your image.
In PowerShell (the label is read as JSON: Windows PowerShell 5.1 drops the inner double quotes
of a `--format` argument):

```powershell
pwsh -NoProfile -File scripts/build-image.ps1 -PrintPlan | Select-String '^version:'
(docker image inspect brokersre-ib-gateway:stable --format '{{json .Config.Labels}}' | ConvertFrom-Json).'com.rocketedge.brokersre.ibkr.version'
```

Different values: a rebuild brings the new Gateway; the plan's `pinned:` line says whether
this project has qualified it (`yes`) or not (`no`, see
[what the last lines mean](../README.md#what-the-last-lines-mean)). The plan asks IBKR's
`version.json` once and builds the small helper image if it is missing; when IBKR cannot be
reached it reports the cached version with `ibkr_reachable: no`.

A crontab line that only writes to the system log when IBKR serves another build than your
image holds (07:15 on weekdays; nothing when the two agree or IBKR does not answer):

```text
15 7 * * 1-5 cd /opt/brokersre-ib-gateway && served="$(scripts/build-image.sh --print-plan 2>/dev/null | sed -n 's/^version: //p')" && built="$(docker image inspect brokersre-ib-gateway:stable --format '{{index .Config.Labels "com.rocketedge.brokersre.ibkr.version"}}')" && [ -n "$served" ] && [ "$served" != "$built" ] && logger -t ibgw-upgrade -p user.warning "IBKR serves IB Gateway $served; brokersre-ib-gateway:stable holds $built"
```

## An image in your registry: does the channel tag point at another digest?

`scripts/check-upgrade.sh` answers one question: does a channel tag (`stable` or `latest`,
IBKR's channel names) in a registry point at something else than the digest this gateway runs?
Use it when you push your builds to your own private registry and move a channel tag there. An
image that was built locally and never pushed has no registry digest; the script answers exit 2
for it (use the section above).

## Use

```bash
# A container on this Docker host that runs an image pulled from your registry; the channel
# comes from the image's label, the repository from the image the container runs.
scripts/check-upgrade.sh --container ib-gateway

# A digest from a deployment file; nothing has to run here.
scripts/check-upgrade.sh --image <registry>/brokersre-ib-gateway@sha256:<digest> --channel stable
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
{"schema":"brokersre.upgrade-check.v1","checked_at":"2026-11-12T06:49:04Z","result":"upgrade-available","up_to_date":false,"repository":"<registry>/brokersre-ib-gateway","channel":"stable","channel_source":"label","running_digest":"sha256:<what runs>","registry_digest":"sha256:<what the tag points at>"}
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

Watching the releases is the other way to be told, without running anything: a release means
this repository pins a new Gateway version
([Get notified of new versions](../README.md#get-notified-of-new-versions)).

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
- Against this repository's registry, in the paper sessions of 2026-11-15/16 UTC:
  `--container` on a gateway running an image RocketEdge published then answered
  `up-to-date`, exit 0 ([limitations](limitations.md), L27).
- The comparison for an image you built (2026-11-17, Git Bash and PowerShell 7 on Windows 11
  with Docker Desktop): the plan said `version: 10.50.1h` and the label of the image built
  that day said `10.50.1h`. The crontab line was run in bash with `logger` replaced by `echo`:
  silent while the two agreed, one line when the image was `brokersre-ib-gateway:latest`
  (10.52.1d) instead.
- Not tested: the crontab lines and the `schtasks` registration on a real schedule, a private
  registry, a mirror, and `shasum` in place of `sha256sum`.

# Disk space is low on a gateway volume

Alert class `disk_low` · default severity warning · [all runbooks](../README.md)

## What it means

The gateway reports that the free space of its log volume or of its settings volume is below
`DISK_MIN_FREE_PCT` (10 %). A full disk stops the logging, and with it everything that reads
the logs, and can damage the Gateway's settings.

## Check first

- Which volume: `docker compose ... exec ib-gateway df -h /var/log/ibgateway /home/ibgateway/Jts/settings`.
- What uses the disk on the host: `docker system df`, and the host's own tools.

The gateway's own files are bounded: every log is capped at `LOG_MAX_BYTES` with `LOG_KEEP`
older generations, and at most `SCREENSHOT_KEEP` screenshots are kept. So the space is
usually taken by something else on the same disk: images, the logs of other containers,
other data.

## What to do

1. Free space on the host: remove what is not needed (unused images, old logs of other
   containers, old downloads).
2. If the volumes share a disk with data that grows, give the gateway's volumes a disk or a
   quota of their own.
3. If the gateway's own logs are the large part, lower `LOG_MAX_BYTES` or `LOG_KEEP`
   ([env-vars](../../env-vars.md)); that takes effect at the next start.

## What not to do

- Do not delete the settings volume, and do not delete files under `state/` or `events/` on
  the log volume by hand: `state/` holds the phase and the record of a rejected login.
- Do not restart the gateway to free space: nothing is freed by that, and every start is a
  login.

## When it clears

When the gateway reports `disk_ok`: both volumes are above the threshold again.

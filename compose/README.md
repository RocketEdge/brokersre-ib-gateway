# Compose files

Ready-to-copy Docker Compose files for brokersre-ib-gateway. Every file is started as shipped
by the test suite (`tests/container/run.sh`, `tests/compose/run.sh`), so each setting in them
is a tested one.

## Table of Contents

- [Which file to use](#which-file-to-use)
- [The one rule: one username per gateway](#the-one-rule-one-username-per-gateway)
- [Live and paper together](#live-and-paper-together)
- [Check each gateway](#check-each-gateway)
- [Ports and settings](#ports-and-settings)
- [More usernames](#more-usernames)
- [Cold standby](#cold-standby)
- [If something is wrong](#if-something-is-wrong)

## Which file to use

| You want | File | Start |
|---|---|---|
| One gateway (live or paper) | [docker-compose.example.yml](docker-compose.example.yml) | README of the repository, "Quick start" |
| Live and paper at the same time, or several IBKR usernames on one host | [docker-compose.multi.yml](docker-compose.multi.yml) | this page |
| A gateway and your strategy on the same host, the API not published at all | [../examples/compose-with-client.yml](../examples/compose-with-client.yml) | [../examples/README.md](../examples/README.md) |
| A person's look at the Gateway's screen when it is stuck (break-glass; added to the one-gateway file with a second `-f`) | [docker-compose.console.yml](docker-compose.console.yml) | [../docs/console.md](../docs/console.md) |

Copy the file you need and pin the image by digest (`IBGW_IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway@sha256:...`)
before you rely on it.

## The one rule: one username per gateway

IBKR allows **one brokerage session per username**, and this image runs one session per
container. "Live and paper together" is therefore two gateways with two usernames, and so is
"two desks". **Two services must never use the same username:** the second one to log in takes
the session, the other one is logged out and shows the phase `existing-session`.

For live and paper at the same time that means two usernames: give the paper gateway the
paper trading account's own username (IBKR shows it in that account's settings), not the live
one.

Check the secret files before you start anything. The script compares hashes and never prints
a username:

```bash
scripts/check-compose-usernames.sh compose/secrets
```

It prints `ok: 2 instances, 2 different usernames` and exits 0, or names the instances that
share a username and exits 1.

## Live and paper together

### 1. Store the secrets, one directory per gateway

```text
compose/secrets/live/ib-username     compose/secrets/live/ib-password
compose/secrets/paper/ib-username    compose/secrets/paper/ib-password
```

`compose/secrets/` is ignored by git. Write the files as UTF-8 **without** a byte-order mark.
On Windows do not use `>` or `echo`: Windows PowerShell 5.1 writes UTF-16 that way, and the
gateway refuses such a file (`secret_unreadable`) rather than send IBKR a wrong password.

Windows (PowerShell 5.1 or 7), from the repository folder:

```powershell
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($instance in 'live', 'paper') {
  $dir = "$PWD\compose\secrets\$instance"
  New-Item -ItemType Directory -Force $dir | Out-Null
  [IO.File]::WriteAllText("$dir\ib-username", (Read-Host "IBKR username for $instance"), $utf8)
  $secure = Read-Host "IBKR password for $instance" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { [IO.File]::WriteAllText("$dir\ib-password", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), $utf8) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
```

Linux, macOS, WSL or Git Bash:

```bash
for instance in live paper; do
  mkdir -p "compose/secrets/${instance}"
  read -r -p "IBKR username for ${instance}: " u && printf '%s' "$u" > "compose/secrets/${instance}/ib-username"
  read -r -s -p "IBKR password for ${instance}: " p && printf '%s' "$p" > "compose/secrets/${instance}/ib-password" && echo
done
unset u p
```

You should see four files, and no password appeared on screen. Then run the username check
from the section above.

### 2. Start

A gateway starts only when its profile is named, so nothing logs in by accident:

```bash
docker compose -f compose/docker-compose.multi.yml --profile live --profile paper up -d
docker compose -f compose/docker-compose.multi.yml --profile live --profile paper logs -f
```

Only paper: name `--profile paper` alone. To avoid repeating the profiles, set
`COMPOSE_PROFILES=live,paper` in your shell or in a `.env` file next to the compose file.

Each gateway logs in on its own. If IBKR asks for a second factor you get **one prompt per
username** in IBKR Mobile (event `twofa_dialog` in that gateway's log); the image never
answers a second factor for you.

### 3. Stop

```bash
docker compose -f compose/docker-compose.multi.yml --profile live --profile paper down
```

`down` asks each gateway to log out and waits up to 90 seconds. The volumes (settings and
logs) stay; add `-v` only if you want to delete them.

## Check each gateway

```bash
docker compose -f compose/docker-compose.multi.yml --profile live --profile paper ps
docker compose -f compose/docker-compose.multi.yml exec ib-gateway-live cat /var/log/ibgateway/state/phase
docker compose -f compose/docker-compose.multi.yml exec ib-gateway-paper cat /var/log/ibgateway/state/phase
```

You should see `logged-in` for each, and `(healthy)` in the status column of `ps`. While the
phase is `login` or `2fa-pending` a gateway reports `unhealthy` on purpose. The phases are
`starting`, `login`, `2fa-pending`, `logged-in`, `restarting`, `existing-session`,
`needs-human`, `stopping`, `stopped`, `exited` and `test-mode`
([docs/log-contract.md](../docs/log-contract.md)).

Every gateway labels its events with its instance name: the first event of each start,
`container_start`, carries `"data": {"instance": "live", ...}`, which is how a log collector
tells the gateways apart.

## Ports and settings

Each gateway publishes its API relay on one host port, bound to `PRIVATE_IP` (loopback by
default). The relay listens only while that gateway is logged in.

| Instance | Profile | `TRADING_MODE` | Host port | Relay port in the container |
|---|---|---|---|---|
| `live` | `live` | `live` | 4001 | 4003 |
| `paper` | `paper` | `paper` | 4002 | 4004 |

| Variable | Default | Meaning |
|---|---|---|
| `IBGW_IMAGE` | `ghcr.io/rocketedge/brokersre-ib-gateway:stable` | Image of every gateway. Pin a digest in production. |
| `IBGW_SECRETS_DIR` | `./secrets` (next to the compose file) | Directory that holds one sub-directory of secrets per instance. |
| `PRIVATE_IP` | `127.0.0.1` | Host address the relays are bound to. Use the private address your strategy host can reach; never `0.0.0.0` on a host the internet can reach. |
| `IBGW_LIVE_PORT`, `IBGW_PAPER_PORT` | `4001`, `4002` | Host ports, for a host where these are taken. |
| `LIVE_READ_ONLY_API`, `PAPER_READ_ONLY_API` | `yes`, `yes` | Read-Only API per gateway. Set `no` only for a gateway that must take orders. |
| `IBGW_MEM_LIMIT` | `2g` | Memory limit **per gateway**: two gateways need twice the memory. |
| `AUTO_RESTART_TIME`, `TIME_ZONE` | `11:45 PM`, `America/New_York` | Daily restart of every gateway and the time zone it is read in. |

Everything else is fixed in the file and identical for every gateway: read-only root
filesystem, no capabilities, `no-new-privileges`, limits, health check. Both services merge
one block (`x-gateway`), so they cannot drift apart.

## More usernames

One more username is one more service. The file carries a third gateway as comments, in three
places marked `# >>> one more username`: the service, its two secrets and its two volumes.
Remove the comment signs in all three, then replace `desk-a` (the instance name) and `4011`
(the host port). This is the service block:

<!-- third-gateway:start -->
```yaml
  ib-gateway-desk-a:
    <<: *gateway
    profiles: ["desk-a"]
    environment:
      <<: *gateway-environment
      IBGW_INSTANCE: desk-a
      TRADING_MODE: live                        # with paper, the relay port below is 4004
      READ_ONLY_API: "yes"
    secrets:
      - source: desk-a-ib-username
        target: ib-username
      - source: desk-a-ib-password
        target: ib-password
    volumes:
      - ibgw-desk-a-settings:/home/ibgateway/Jts/settings
      - ibgw-desk-a-logs:/var/log/ibgateway
    ports:
      - "${PRIVATE_IP:-127.0.0.1}:4011:4003"
```
<!-- third-gateway:end -->

Four things are specific to an instance, and each must be unique on the host:

| What | Where | Example for `desk-a` |
|---|---|---|
| Instance name and profile | service name, `profiles`, `IBGW_INSTANCE` | `desk-a` |
| Host port | `ports` | `4011` |
| Secrets | `secrets` of the service and the two entries under `secrets:` | `compose/secrets/desk-a/ib-username`, `.../ib-password` |
| Volumes | `volumes` of the service and the two entries under `volumes:` | `ibgw-desk-a-settings`, `ibgw-desk-a-logs` |

The container side of the port is not free to choose: it is `4003` for `TRADING_MODE: live`
and `4004` for `paper`. A port plan that stays readable:

| Instance | Host port |
|---|---|
| `live` | 4001 |
| `paper` | 4002 |
| `desk-a` | 4011 |
| `desk-b` | 4012 |
| `desk-c` | 4013 |
| `standby` | 4021 |

Create the secret files as in step 1 (put the new instance name into the loop), run
`scripts/check-compose-usernames.sh compose/secrets`, then start it:

```bash
docker compose -f compose/docker-compose.multi.yml --profile desk-a up -d
```

## Cold standby

A cold standby is the same thing: one more service with a **second username** (never the
primary's), its own secrets, volumes and host port, and a profile you name only when you need
it. Kept stopped, it holds no session. When you start it, it logs in from scratch, so expect
the second-factor prompt for that username:

```bash
docker compose -f compose/docker-compose.multi.yml --profile standby up -d
```

Because it uses another username it can never take the primary's session. Point your strategy
at the standby's host port after you have started it; nothing here does that on its own.

## If something is wrong

| You see | Cause | Fix |
|---|---|---|
| `no service selected` | No profile was named | Add `--profile live --profile paper` or set `COMPOSE_PROFILES` |
| `down` returns at once and the gateways keep running | `down` without a profile stops nothing | Name the same profiles as for `up`, or set `COMPOSE_PROFILES` |
| Phase `existing-session` in one gateway | Two gateways (or a gateway and another program) hold the same username | Run `scripts/check-compose-usernames.sh compose/secrets`; give every gateway its own username |
| Event `secret_unreadable` | A secret file is empty or UTF-16 | Write it again with the commands in step 1 |
| `port is already allocated` | The host port is taken (another gateway, the single-gateway example) | Set `IBGW_LIVE_PORT` / `IBGW_PAPER_PORT`, or stop the other stack |
| One gateway `unhealthy`, the other healthy | That gateway is not logged in (second factor pending, wrong password) | Read its phase and its log; the gateways are independent |

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive
Brokers.

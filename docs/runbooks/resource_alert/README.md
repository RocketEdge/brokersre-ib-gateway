# Gateway memory pressure or an out-of-memory kill

Alert class `resource_alert` · default severity error · [all runbooks](../README.md)

## What it means

One of two things, both reported by the gateway itself:

- `memory_high`: the container's working set has been above `MEM_HIGH_PCT` (85 %) of its
  memory limit for `MEM_HIGH_FOR_S` (600 seconds);
- `oom_kill`: the kernel killed a process of the container because the limit was reached,
  in the last 15 minutes.

## Check first

- Now: `docker stats --no-stream <container>`.
- The gateway's last sample (`mem_working_set_bytes`, `mem_limit_bytes`, `java_rss_bytes`,
  `oom_kills`):
  `docker compose ... exec ib-gateway tail -n 1 /var/log/ibgateway/metrics/metrics.jsonl`.
- The two settings that decide it: the container's memory limit (`IBGW_MEM_LIMIT` in the
  reference compose file, 2g by default) and the Java heap (`JAVA_HEAP_MB`).
- After a kill: does the Gateway still run? If the kernel killed the Gateway itself,
  [gateway_exited](../gateway_exited/README.md) follows.

## What to do

1. Raise the memory limit, or lower the heap, so that the heap is at most 75 % of the limit
   (the preflight warns above that, and refuses a heap as large as the limit).
   `JAVA_HEAP_MB=auto` takes half of the limit.
2. A changed limit or heap takes a new start of the container, which is a new login. After
   a kill do it now; for pressure without a kill plan it for the next maintenance window,
   with the person who approves the second factor ready.
3. If the pressure grows over days, look at what the API clients ask for: many market-data
   subscriptions and large historical requests are held in the Gateway's memory.

## What not to do

- Do not remove the memory limit to silence the alert: the pressure then moves to the host
  and to everything else on it.
- Do not set the heap as large as the limit: the Gateway needs memory beyond its heap. How
  much a logged-in Gateway needs has not been measured with this image
  ([limitations](../../limitations.md), L13).

## When it clears

- Pressure: when the gateway reports `memory_ok`.
- A kill: 15 minutes after it. Nothing was fixed by that: the next kill is a new alert.

# novhub-local-stack

Brings up the full local NovHub stack for manual validation — the weld-data path (PLCSIM →
NovData → an OpenSearch loader → NOVAPI → NovApp) and the control path (LUNA → `plc-node` →
PLCSIM) — in the order the stack actually needs, idempotently. Replaces hand-walking
`~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` step by step.

Not a standalone application: it orchestrates seven other checkouts
(`~/dev/NovApi`, `~/dev/NovData`, `~/dev/NovSync`, `~/dev/novhub`, `~/dev/plc_simulator`,
`~/dev/plc-node`, and this repo's own `luna/run-luna.sh`) plus Docker and the robot's own
`/var/opt/novarc/configure`. `start` builds, installs, configures, and starts everything it can —
including PLCSIM and `plc-node` (real builds, real `apt install`, real service starts). Any
`sudo` call happens inside the script itself: it prompts you directly, in your own terminal,
only when something actually needs it. Only LUNA stays manual — its frontend needs the real
desktop display, which nothing running non-interactively can check or start.

## Scripts

| Script | Purpose |
| --- | --- |
| `run-novhub.sh` | Main entrypoint — `start`/`stop`/`status`, whole stack or one `[component]` |
| `prereqs.sh` | Pre-flight check — runs automatically before each component command |
| `opensearch.sh`, `novdata.sh`, `novapi.sh`, `novapp.sh`, `plcsim.sh`, `plcnode.sh`, `luna.sh` | Thin per-component wrappers — `<name>.sh start\|stop\|status`, same effect as `run-novhub.sh start\|stop\|status <name>` |
| `sync.sh` | One-shot job — run after the stack is up to reflect a new simulated weld |
| `weld.sh` | One-shot job — `start`/`stop`/`status` a hot weld on PLCSIM's REST API, so NovData sees a run without needing `plc-node`/LUNA |
| `setup-host.sh` | One-time host sysctl setup (the three kernel limits below) |
| `reset.sh` | Dev-hygiene: selectively wipe containers/data, or stop just PLCSIM+`plc-node` |
| `loader.py` | OpenSearch loader — reads NovData's Postgres, posts to `novhub-local` (used by `sync`, never run directly) |
| `perf-setup.sh` | HUB-106: one-time install of Playwright (owner-run) for browser HAR/trace capture |
| `perf-seed.sh` | HUB-106: seed/remove a frozen synthetic dataset (10 robots × 2,000 runs, ids 900001-900010) by writing OpenSearch docs directly |
| `perf-seed.py` | The actual seed/remove logic `perf-seed.sh` calls — not run directly |
| `novapi-psql.sh` | Opens `psql` against NovApi's own Postgres (`cloud_db_dev`) — no password needed, runs inside the container |
| `perf-harness-a.sh` | HUB-106: times variant A (today's per-run call pattern, fired 6 at a time) against the seeded dataset |
| `perf-harness-a.py` | The actual timing logic `perf-harness-a.sh` calls — not run directly |
| `perf-ingester-seed.sh` | HUB-106: seed/remove the minimal robot + preset rows `perf-ingester-load.sh` needs (ids 910001+, separate range from `perf-seed.sh`'s) |
| `perf-ingester-seed.py` | The actual seed/remove logic `perf-ingester-seed.sh` calls — not run directly |
| `perf-ingester-load.sh` | HUB-106: runs `opensearch-ingester` (`~/dev/opensearch-ingester`) in-process over synthetic Hermit V2 payloads, writing to a separate index so it never touches `perf-seed.sh`'s data |
| `opensearch-resize-heap.sh` | HUB-106: bumps the local OpenSearch container's JVM heap without losing data (stop, commit, recreate — see the Appendix) |
| `brand-check.sh` | HUB-106: prints NovApi/NovApp's brand (NovAI vs SWR), exit 0 only if both are NovAI — TAS runs NovAI only |
| `perf-sweep.sh` | HUB-106: sweeps `weld_run` page size and both batch endpoints' batch size on the existing seeded dataset (no re-ingest) |
| `perf-sweep.py` | The actual sweep logic `perf-sweep.sh` calls — not run directly |
| `perf-slowlog.sh` | HUB-106: `on`/`off`/`status` toggle for OpenSearch/Postgres slow-query logging, for `perf-report.sh`'s NovApi/OpenSearch/Postgres breakdown |
| `perf-capture.sh` | HUB-106: Playwright capture of a real page (Analytics or QC Report) — HAR + Performance trace + a `*-metrics.json` (time to usable, DOM-based list/detail-usable on Analytics, request counts, scripting time, longest task), then runs `perf-report.sh` on the result |
| `perf-capture.js` | The actual Playwright driver `perf-capture.sh` calls — not run directly |
| `perf-after.sh` | HUB-106: repeats the exact BEFORE measurement set (brand + frozen-dataset check, endpoint baseline, size sweep, both pages' Playwright capture) in one command, into one `after-<timestamp>` folder |
| `perf-rank-robots.sh` | HUB-106: read-only - ranks a `--target`'s robots by `weld_run` total over a wide fixed date range, to pick a BEFORE/AFTER robot on a target whose data we don't control |
| `perf-rank-robots.py` | The actual ranking logic `perf-rank-robots.sh` calls — not run directly |
| `cloud-tunnel.sh` | HUB-106: read-only SSH local-port-forward (`open`/`status`/`close`) through the cat-dev bastion to one environment's DB + OpenSearch, for `cloud-check.sh` |
| `cloud-check.sh` | HUB-106: read-only credential check for one environment through its tunnel - DB `SELECT 1` + robot count, OpenSearch health + count tried via basic auth and AWS SigV4 |
| `cloud-check.py` | The actual check logic `cloud-check.sh` calls — not run directly |
| `cloud-bastion-check.sh` | HUB-106: plain TCP reachability check from the cat-dev bastion to one environment's DB/OpenSearch hosts, via `exec_ubuntu` |
| `perf-report.sh` | HUB-106: ONE zero-install `report.html` from any combination of a NovApi log slice, a HAR, a Performance trace, and OpenSearch/Postgres slow logs — or, with `--compare`, a BEFORE-vs-AFTER comparison report from the same inputs on both sides |
| `perf-report.py` | The actual report-building logic `perf-report.sh` calls — not run directly |
| `trace-secret-scan.sh` | HUB-106: scans a Chrome Performance trace for an Authorization header/cookie/Bearer token/JWT without ever printing the value — run before sharing any trace file |
| `trace-secret-scan.py` | The actual scan logic `trace-secret-scan.sh` calls — not run directly |
| `steps/*.sh` | One file per component (`opensearch`, `novdata`, `novapi`, `novapp`, `plcsim`, `plcnode`, `luna`, `sync`, `prereqs`) — sourced by `run-novhub.sh`/`reset.sh`, not run directly |

Every script meant to be run directly takes `-h`/`--help`.

## The startup sequence

One-time host setup:

```bash
./novhub-local-stack/setup-host.sh          # persists the three kernel limits below
```

Bring the stack up manually, one component at a time, in the order it actually needs:

| # | Component | Command | Notes |
| --- | --- | --- | --- |
| 0 | Prerequisites | *(automatic — runs before every command below)* | Docker, Node.js/npm, .NET 6 SDK, `git-lfs`, `python3`, `gh`, Docker Compose; the three sysctl limits; `ulimit -n` (raised automatically) |
| 1 | OpenSearch | `./novhub-local-stack/opensearch.sh start` | Container `os-local`, port `9200`. See the Appendix for manual/recovery detail |
| 2 | NovData | `./novhub-local-stack/novdata.sh start` | First run prompts for the Postgres superuser password; every run needs `SWR_DB_KEY` (read automatically — see "The four secrets") |
| 3 | NovApi | `./novhub-local-stack/novapi.sh start` | First run prompts for the robot API key and the NovApp sign-in password. Also brings up a local MinIO container (S3 mock for attachment listing) and points NovApi's `.env` at it - no manual step |
| 4 | NovApp | `./novhub-local-stack/novapp.sh start` | Vite dev server, port `5173` |
| 5 | PLCSIM | `./novhub-local-stack/plcsim.sh start` | Fully automated build + install + start, prompts for `sudo` |
| 6 | plc-node | `./novhub-local-stack/plcnode.sh start` | Fully automated build + install + start, prompts for `sudo` — see below for `SWR_TYPE` |
| 7 | LUNA | `./novhub-local-stack/luna.sh start` | Always prints manual instructions — starts nothing itself |

Each line above is identical in effect to `./novhub-local-stack/run-novhub.sh start <component>`.
`prereqs` runs automatically before each one, every time — nothing to run separately for it.

The whole-stack entrypoint does the same sequence in one call:

```bash
./novhub-local-stack/run-novhub.sh start     # bring everything up, in order (prompts for sudo as needed)
./novhub-local-stack/run-novhub.sh status    # report every component's state, change nothing
./novhub-local-stack/run-novhub.sh stop      # stop everything this script started; keeps data
```

`start` stops at the first step that genuinely fails (or at LUNA's manual reminder); rerun it
once that's done and it continues from there. `status` never stops early and never changes
anything.

Afterward — once the stack is up, each time you want a new simulated weld to show up in NovApp:

```bash
./novhub-local-stack/weld.sh start               # trigger a weld on PLCSIM's REST API
./novhub-local-stack/weld.sh stop                # after a few seconds
./novhub-local-stack/run-novhub.sh start sync     # or: ./novhub-local-stack/sync.sh start
```

Neither `weld` nor `sync` is a persistent service — they're one-shot jobs, not part of the
startup sequence above, and their own `stop`/`status` (where they have one) just report state
and change nothing.

### Controlling one component

Every component also takes a `[component]` argument on `run-novhub.sh`, or has its own thin
wrapper script that does the same thing standalone — both forms call the exact same code:

```bash
./novhub-local-stack/run-novhub.sh start novapi   # only NovApi (+ its own Postgres) changes state
./novhub-local-stack/novapi.sh start              # identical - standalone, no run-novhub.sh needed
./novhub-local-stack/opensearch.sh status         # read-only, changes nothing
```

Valid components: `opensearch novdata novapi novapp plcsim plcnode luna sync`. `prereqs` isn't
one of these — it's the pre-flight check that runs automatically before every real
`start`/`stop`/`status` call, standalone or not; `./novhub-local-stack/prereqs.sh status` runs
just that check on its own.

`vm.max_map_count >= 262144` (OpenSearch) and two separate `fs.inotify` limits
(`max_user_watches >= 524288`, `max_user_instances >= 1024`, both needed by `nodemon`/`vite`'s
file watchers) are the three kernel limits `setup-host.sh` persists via `/etc/sysctl.d/`.
`max_user_instances` is the one that actually caused `EMFILE` crashes here — a different limit
from `max_user_watches`, and easy to miss.

## The four secrets

Each is prompted once, only for the step that still needs it, read with no echo, and never
written to disk or logged by this script:

| Secret | Prompted by | What it's for |
| --- | --- | --- |
| Postgres superuser password | `novdata_up`, first run only | NovData's own Postgres container |
| `novdata` role password (`SWR_DB_KEY`) | `novdata_up`, every run | NovData's app process, and the loader/NovSync in `sync` |
| Robot API key (`SECRET_KEY`) | `novapi_up`, first run only | Seeded into NOVAPI as the robot's `api_key`; also what NovSync sends as `x-api-key` in `sync` |
| NovApp sign-in password (`LOCAL_PASSWORD`) | `novapi_up`, first run only | The seeded NovApp user's password |

The robot's own identity (`SWR_ID`, `SWR_NUMBER`, `SWR_CUSTOMER`, `SWR_LOCATION`) is read
read-only from `/var/opt/novarc/configure` — never invented, never defaulted. If that file is
missing or malformed, the script stops rather than guessing. That file's other entries (cloud
credentials, `SWR_DB_KEY` for a different, installed database) are never read, printed, or
copied anywhere.

## PLCSIM and `plc-node` tag maps

`plc-node` picks its entire PLC tag map from the `SWR_TYPE` env var it's started with — the two
sets are never merged: unset (the default here) loads the full `mem-map.cfg`/`alarms.cfg`
(`weld_Mode_Current`, `Estop_Pressed`, etc. — what LUNA needs); `SWR_TYPE=NOVAI` loads the small
`novai-mem-map.cfg`/`novai-alarms.cfg` instead (`HMI_NovAI_Mode`, etc.). This machine's own
`/var/opt/novarc/configure` says `SWR_TYPE=NOVAI`, but LUNA's backend/frontend read that file
directly and independently of what gets passed to `plc-node` — the two don't have to match.
Override with `PLCNODE_SWR_TYPE=NOVAI ./novhub-local-stack/run-novhub.sh start` if NovAI-mode
tags are needed instead; doing so brings back "could not find the item" errors for the
full-map-only tags.

## Stopping and resetting

`stop` (whole stack, no component) stops every component this script started or manages —
`docker stop` (not `rm`) for OpenSearch/NovData/NOVAPI's Postgres containers, a pidfile-tracked
process-group kill for NovData/NOVAPI/NovApp's background processes, `sudo systemctl stop` for
PLCSIM, and `sudo pkill` (as the `novarc` user) for `plc-node` — leaving data and installs
intact so the next `start` picks up where it left off. It never uninstalls anything, never
removes a container, and never touches LUNA (it never started it). The runbook's full "Cleanup"
section (removing containers, uninstalling PLCSIM/`plc-node`, deleting NovSync's venv) stays
manual — see the runbook directly.

For dev-hygiene resets between test runs (wiping a container's data entirely, not just stopping
it, or stopping just PLCSIM+`plc-node`), use `./novhub-local-stack/reset.sh` — see its own
`--help`.

## HUB-106 perf-testing tools

```bash
./novhub-local-stack/perf-setup.sh          # one-time: install Playwright (prompts for sudo on the Chromium/apt step)
./novhub-local-stack/perf-seed.sh seed      # create the frozen synthetic dataset (10 robots x 2,000 runs)
./novhub-local-stack/perf-seed.sh remove    # delete exactly what seed created, nothing else
./novhub-local-stack/novapi-psql.sh -c "select count(*) from weld_test_reports;"   # one-shot query, no password
./novhub-local-stack/novapi-psql.sh         # interactive psql prompt, no password
./novhub-local-stack/perf-harness-a.sh      # time variant A (today's per-run calls) against the seeded data
```

`perf-seed.sh seed` writes directly to OpenSearch and NovApi's own Postgres — never through
LUNA/PLCSIM/plc-node or NovData — so it needs OpenSearch and NovApi's own `docker compose`
stack running first, not the whole local stack. Everything it creates is tagged (a reserved
robot-id range, one synthetic group/user) so `remove` can undo it cleanly; it's idempotent,
re-running `seed` on an already-seeded stack just prints `already seeded`. The synthetic test
user's login is written to `.state/secrets/perf-test-user.secret` (0600, in a 0700 directory) —
never printed twice, never logged elsewhere.

`perf-seed.sh` writes OpenSearch docs by hand, in a shape that doesn't match production (no
`robot_type`, no preset-matching). `opensearch-ingester`
(`~/dev/opensearch-ingester`, `github.com/Novarc-Software/opensearch-ingester`) is the
production ingestion path, usable locally the same way:

```bash
./novhub-local-stack/perf-ingester-seed.sh seed        # robot + matching preset rows (ids 910001+)
./novhub-local-stack/perf-ingester-load.sh \            # generate + ingest synthetic Hermit V2 runs
  -template /path/to/a/real/Hermit_V2_sample.json \     # read-only - never copy a real sample into a repo
  -robot-id-start 910001 -robot-count 2 -runs-per-robot 10 -points-per-run 10
./novhub-local-stack/perf-ingester-seed.sh remove       # undo exactly what seed created
```

`perf-ingester-load.sh` builds synthetic Hermit V2 JSON payloads using a real sample file as the
structural template (`-template`, required: real schema/field order, real `weld_summary` keys,
real value-row patterns cycled for variation) and feeds them through the ingester's own
`RouteAndProcess` in-process (see `~/dev/opensearch-ingester/cmd/perfload`). The template file
is only ever read, never copied or committed anywhere. Writes to `ES_INDEX` (default
`novhub-local-ingester`, separate from `perf-seed.sh`'s `novhub-local`, so the two never
collide) and needs NovApi's own Postgres and the local OpenSearch container up first. Point
NovApi at either index via its own `OPENSEARCH_INDEX` env var.

**Known gap, worked around by default:** the real sample file's `robot` object is shaped
`{"id":..., "model":...}`. The ingester's `ComputeWSID` (used to match `weld_presets_associations`
rows) only reads a `robot_id` key, not `id` — so with that real shape it silently drops `robot_id`
from the hash, and the association it writes never matches what NovApi recomputes from the
stored OpenSearch doc (which does carry `robot_id`, written by a different code path). By default
the generator adds `robot_id` alongside `id` in the payload (`cmd/perfload/main.go`,
`includeRobotID`) — a generator-only workaround, no `opensearch-ingester` code changed. Pass
`-include-robot-id=false` to reproduce the real gap. Whether real production payloads actually
use this `id`/`model` shape (vs. the ingester's own test fixtures, which use `robot_id`/
`robot_type`) is unconfirmed as of 2026-11-17 — owner decision pending via COORDINATOR.

### Measuring and reporting (size sweep, page capture, the graphical report)

```bash
./novhub-local-stack/brand-check.sh                               # NovAI on both sides? exit 0 only if so
./novhub-local-stack/perf-sweep.sh                                 # how time grows with request size, same dataset
./novhub-local-stack/perf-slowlog.sh on                            # OpenSearch/Postgres slow-query logging, for the breakdown below (off when done)
./novhub-local-stack/perf-capture.sh --page analytics --out <dir>  # Playwright: HAR + trace + metrics.json, then builds <dir>/report.html itself
./novhub-local-stack/perf-after.sh                                 # brand+dataset check, baseline, sweep, both pages' capture - one after-<ts> folder
./novhub-local-stack/trace-secret-scan.sh <trace.json>              # run before sharing ANY Performance trace - never prints the match, only where
./novhub-local-stack/perf-report.sh --har <har> --novapi-log <log> --trace <trace> --out <dir>           # combine any of these into one report.html
./novhub-local-stack/perf-report.sh --compare --before-har-analytics <har> --after-har-analytics <har> --out <dir>  # BEFORE vs AFTER, same inputs both sides - see --help for every --before-X/--after-X pair
```

`perf-report.sh --compare` is the same tool as the single-run form, not a second one — pass
`--before-X`/`--after-X` pairs (HAR, NovApi-log slice, Playwright `--capture-*` metrics —
repeatable for multiple trials, Performance trace) instead of the plain flags; anything present
on only one side is listed in the report as not yet comparable, never silently dropped.
`perf-capture.sh`'s own `*-metrics.json` on the Analytics page carries DOM-based `list_usable_ms`/
`detail_usable_ms` (QC-status badge filled + row count stable) alongside the older
`time_to_usable_ms` (network-idle proxy, kept as a labelled secondary number — exposed to
request-ordering/waterfall timing, not just work volume). QC Report has no equivalent QC-status
badge column, so it keeps `time_to_usable_ms` as its only usable signal.

`perf-capture.sh`/`perf-rank-robots.sh` take `--target NAME` (`perf-after.sh` is always `local`).
`--target local` (the default) uses `perf-targets.env` — one file, git-ignored, auto-created on
first run from the committed `perf-targets.env.example` (local defaults only). Any other target
(e.g. `test`, `dev`) uses `perf-targets.<target>.env`, which you create yourself first (same
`KEY=value` format: `PERF_ROBOT_NAME`, `NOVAPP_URL`, `NOVAPI_URL`) — nothing about a named target
is ever committed, and there's no hardcoded fallback for one. Credentials stay only in a 0600
secret file, never in either config file: `.state/secrets/perf-test-user.secret` for `local`,
`.state/secrets/perf-test-user-<target>.secret` for any other target (both overridable with
`PERF_SECRET_FILE`). No script hardcodes a robot-name default anywhere anymore.

`perf-capture.sh --target <name other than local>` targets an environment other than this local
stack: it skips `brand-check.sh` and the local NovApi-log pairing — both only know how to read
this stack's own local state — and says so in its output. It refuses up front, before contacting
anything, if that target's config is missing the robot name, either URL, or the date range (see
below), or if its secret file is missing or its mode isn't exactly 0600 — there is no local
fallback for a named target. Pass a log slice yourself with `perf-report.sh --novapi-log`
afterwards if you have one — a named target has none to pair automatically.

Analytics has no URL param for its date-range filter — it always opens on a relative "last 7
days" default, so a real BEFORE/AFTER comparison needs that pinned explicitly. `PERF_RANGE_START`/
`PERF_RANGE_END` (`YYYY-MM-DD`, per-target config, both or neither) make `perf-capture.sh` set the
range through the picker UI itself after the page settles on its default — required together for
any non-local `--target`, optional locally. `*-metrics.json` reports `date_range_used` and
`range_change_usable_ms` (measured from right before the committing change, network cleared at
that moment, to list-usable + network-idle again — the same way as a manual DevTools BEFORE
recording); `detail_usable_ms` is measured after the range change, so it reflects the pinned
range, not the default one.

`perf-rank-robots.sh --target NAME` is read-only: logs into that target, lists its robots, and
ranks them by `weld_run` total over a wide fixed date range — for picking a BEFORE/AFTER robot on
a target whose data isn't ours to seed. One robot at a time, a short pause between each, never
retries, never writes, never prints the login or token.

`cloud-tunnel.sh open|status|close --env dev|test` opens a read-only SSH local forward through
the cat-dev bastion to that environment's DB and OpenSearch, reading hosts from
`.state/secrets/novai-<env>/{DB,OPENSEARCH}.secrets` at run time and local ports from
`cloud-tunnel-ports.env` (git-ignored, auto-created from the committed
`cloud-tunnel-ports.env.example`). `cloud-check.sh --env dev|test` then checks that tunnel: DB
`SELECT 1` + a robot count, and OpenSearch health + a count tried both as basic auth and AWS
SigV4 (NovApi itself only ever uses SigV4 for OpenSearch - see `osRepo/queries.js`). Neither tool
ever prints a secret value. `cloud-bastion-check.sh --env dev|test` is a separate plain-TCP
reachability check run from the bastion itself, for confirming it can even reach a given
environment's hosts before trying to tunnel to them.

The full before/after procedure (frozen-dataset check, folder layout, when to use which tool) is
documented once, in `~/dev/presentations/novhub-local-stack/hub106-perf-results/README.md` — this
section is the tool reference, that doc is the procedure.

## Appendix: OpenSearch manual operations

Hand-run equivalents of what `opensearch.sh`/`steps/opensearch.sh` do automatically — use this
when you want to do it yourself, or to verify/recover without going through either script.
[`steps/opensearch.sh`](steps/opensearch.sh) is the single source of truth for the container
name, port, image, index name, and default heap (`OPENSEARCH_CONTAINER`, `OPENSEARCH_PORT`,
`OPENSEARCH_IMAGE`, `OPENSEARCH_INDEX`, `OPENSEARCH_HEAP`, all overridable by env var of the
same name).

The container is `os-local`, port `127.0.0.1:9200`. It has **no data volume** — its index data
lives only in the container's own writable layer. That one fact drives every procedure below:
stopping the container is always safe, but removing it without first preserving its filesystem
loses the data permanently. Each scenario below is independent — check which one you're in
before running any commands.

### Check current state (always do this first)

1. `docker ps -a --filter name=os-local --format '{{.Names}}  {{.Status}}  {{.Image}}'`
   - No output at all → go to **Scenario B** (container doesn't exist).
   - Shows `Up ...` → go to **Scenario A, step 3** (already running, just verify health).
   - Shows `Exited ...` → go to **Scenario A** (exists but stopped).
2. Note the `{{.Image}}` value from step 1's output — if it is `os-local-preheap:<tag>` rather
   than `opensearchproject/opensearch:2.19.0`, this container is running from a heap-resize
   snapshot that carries real data (see "Resizing the heap" below). Do not discard that image.

### Scenario A: container exists, just needs starting

1. `docker start os-local`
   - Expected: prints `os-local`, no error.
   - If it errors `No such container` → you're actually in Scenario B, use that instead.
2. Poll for it to answer (bounded, 60s):

   ```bash
   for i in $(seq 1 30); do
     curl -s -o /dev/null http://127.0.0.1:9200 && break
     sleep 2
   done
   ```

   - Expected: loop exits within a few seconds.
   - If it never exits: `docker logs os-local --tail 50` and read the error — do not keep
     waiting past 60s, something is wrong (see "Recovering from a stale-lock failure" if the
     error mentions `AlreadyClosedException` or `node.lock`).
3. `curl -s http://127.0.0.1:9200/_cluster/health?pretty`
   - Expected: `"status": "yellow"` or `"green"`, `"number_of_data_nodes": 1`. `yellow` is normal
     for this single-node setup (no replicas to assign) — not a problem.
   - If `red`, or the command fails to connect: stop and investigate `docker logs os-local`
     before doing anything else to this container.
4. `curl -s "http://127.0.0.1:9200/_cat/indices?h=index,docs.count"` — confirms your expected
   indices and doc counts are there (e.g. `novhub-local-ingester` should show the count from your
   last seed/ingest run).

### Scenario B: container doesn't exist (fresh host, or after `docker rm`)

**Stop and think before running this** — if an `os-local-preheap:*` image exists
(`docker images --filter reference='os-local-preheap*'`) and holds data you still need, use that
image in place of `opensearchproject/opensearch:2.19.0` below, or you will start from an empty
index.

1. ```bash
   docker run -d --name os-local -p 127.0.0.1:9200:9200 \
     -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
     -e OPENSEARCH_JAVA_OPTS="-Xms4g -Xmx4g" \
     opensearchproject/opensearch:2.19.0
   ```

   - Expected: prints a container ID, no error.
2. Poll and verify health exactly as Scenario A steps 2–3.
3. Create the index (only needed once, idempotent — check first):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200/novhub-local
   ```

   - `200` → already exists, skip to step 4.
   - anything else (e.g. `404`) →

     ```bash
     curl -s -X PUT http://127.0.0.1:9200/novhub-local \
       -H 'Content-Type: application/json' \
       -d @novhub-local-stack/opensearch-mapping.json
     ```

     Expected: `{"acknowledged":true, ...}`.
4. Re-run the "Check current state" `_cat/indices` command — a fresh container should show
   `novhub-local 0` and nothing else of note.

### Resizing the heap (on an already-running container, without losing data)

The default heap for a freshly-created container (Scenario B, or any future `run-novhub.sh start`
on a clean host) comes from `OPENSEARCH_HEAP` in [`steps/opensearch.sh`](steps/opensearch.sh)
(currently `4g`, was `512m`). To change an *already-running* container's heap without recreating
it from scratch (and losing its data), use the scripted path:
`./novhub-local-stack/opensearch-resize-heap.sh [heap-size]` (default `4g`, `--help` for
details) — idempotent, no-ops if already at that size. To do it by hand instead:

1. Record current doc counts so you can verify nothing was lost:
   `curl -s "http://127.0.0.1:9200/_cat/indices?h=index,docs.count" | sort > /tmp/before.txt`
2. **Stop the container first — do not commit a running one.** A graceful stop lets OpenSearch
   release its own Lucene lock files; committing while it's still running bakes stale locks into
   the image and the new container will refuse to start (see the recovery scenario below).
   `docker stop os-local`
3. `docker commit os-local "os-local-preheap:$(date -u +%Y%m%dt%H%M%Sz)"` — note the tag it
   prints; this is your rollback copy, keep it.
4. `docker rm os-local`
5. ```bash
   docker run -d --name os-local -p 127.0.0.1:9200:9200 \
     -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
     -e OPENSEARCH_JAVA_OPTS="-Xms8g -Xmx8g" \
     "os-local-preheap:<the tag from step 3>"
   ```

   (replace `8g` with whatever size you actually want)
6. Poll and verify health as in Scenario A steps 2–3.
7. `curl -s "http://127.0.0.1:9200/_cat/indices?h=index,docs.count" | sort > /tmp/after.txt`
   then `diff /tmp/before.txt /tmp/after.txt` — expect no output (no difference). Any difference
   means data was lost; stop and don't reuse this container until you understand why.

### Recovering from a stale-lock failure

Only needed if you (or a script) committed a container while it was still running, and the new
container now fails to start with `docker logs os-local` showing
`org.apache.lucene.store.AlreadyClosedException` and `node.lock` or `write.lock`. The data is not
lost — it's sitting in the image you committed — but the lock files inside it are stale and must
be removed from a throwaway container before OpenSearch will start from that image again.

1. `docker rm -f os-local` (the failed one; it's not serving anything).
2. Start a disposable shell container from the bad image (replace `<bad-image>`):

   ```bash
   docker run -d --name os-local-fix --entrypoint sh <bad-image> -c "sleep 3600"
   ```

3. Delete every lock file in the data directory (this image has no `find` binary; `python3` is
   present, use it):

   ```bash
   docker exec os-local-fix python3 -c "
   import os
   for root, dirs, files in os.walk('/usr/share/opensearch/data'):
       for f in files:
           if f.endswith('.lock'):
               os.remove(os.path.join(root, f))
   "
   ```

   Expected: no output, no error. (You can list them first with the same `os.walk` loop and a
   `print()` instead of `os.remove()` if you want to see what will be deleted before deleting.)
4. Commit the fixed container **with the original entrypoint restored** — the throwaway
   container's entrypoint was overridden to `sh` in step 2, and a plain `docker commit` would
   bake that in, leaving an image that no longer starts OpenSearch at all:

   ```bash
   docker commit \
     --change='ENTRYPOINT ["./opensearch-docker-entrypoint.sh"]' \
     --change='CMD ["opensearch"]' \
     os-local-fix "os-local-preheap:fixed"
   docker rm -f os-local-fix
   ```
5. Run the real container from `os-local-preheap:fixed` (same `docker run` form as Scenario B
   step 1 / resize step 5, using this image), then poll and verify as usual.
6. Clean up stray images once you've confirmed the new container is healthy and has the right
   data: `docker images --filter reference='os-local-preheap*'` to list them,
   `docker rmi <repo:tag>` for any you no longer need as a rollback point.

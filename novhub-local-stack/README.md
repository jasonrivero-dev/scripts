# novhub-local-stack

Brings up the full local NovHub stack for manual validation — the weld-data path (PLCSIM →
NovData → an OpenSearch loader → NOVAPI → NovApp) and the control path (LUNA → `plc-node` →
PLCSIM) — in the order the stack actually needs, idempotently. Replaces hand-walking
`~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` step by step.

Not a standalone application: it orchestrates seven other checkouts
(`~/dev/NovApi`, `~/dev/NovData`, `~/dev/NovSync`, `~/dev/novhub`, `~/dev/plc_simulator`,
`~/dev/plc-node`, and this repo's own `luna/run-luna.sh`) plus Docker and the robot's own
`/var/opt/novarc/configure`. `up` builds, installs, configures, and starts everything it can —
including PLCSIM and `plc-node` (real builds, real `apt install`, real service starts). Any
`sudo` call happens inside the script itself: it prompts you directly, in your own terminal,
only when something actually needs it. Only LUNA stays manual — its frontend needs the real
desktop display, which nothing running non-interactively can check or start.

## Scripts

| Script | Purpose |
| --- | --- |
| `run-novhub.sh` | Main entrypoint — `up`/`status`/`down`/`sync` the whole stack |
| `setup-host.sh` | One-time host sysctl setup (the three kernel limits below) |
| `reset.sh` | Dev-hygiene: selectively wipe containers/data, or stop just PLCSIM+`plc-node` |
| `loader.py` | OpenSearch loader — reads NovData's Postgres, posts to `novhub-local` (used by `sync`, never run directly) |
| `perf-setup.sh` | HUB-106: one-time install of Playwright (owner-run) for browser HAR/trace capture |
| `perf-seed.sh` | HUB-106: seed/remove a frozen synthetic dataset (10 robots × 2,000 runs, ids 900001-900010) by writing OpenSearch docs directly — superseded by `perf-ingester-load.sh` (below) per the lead dev, kept for the existing variant-A baseline until the owner decides to remove it |
| `perf-seed.py` | The actual seed/remove logic `perf-seed.sh` calls — not run directly |
| `novapi-psql.sh` | Opens `psql` against NovApi's own Postgres (`cloud_db_dev`) — no password needed, runs inside the container |
| `perf-harness-a.sh` | HUB-106: times variant A (today's per-run call pattern, fired 6 at a time) against the seeded dataset |
| `perf-harness-a.py` | The actual timing logic `perf-harness-a.sh` calls — not run directly |
| `perf-ingester-seed.sh` | HUB-106: seed/remove the minimal robot + preset rows `perf-ingester-load.sh` needs (ids 910001+, separate range from `perf-seed.sh`'s) |
| `perf-ingester-seed.py` | The actual seed/remove logic `perf-ingester-seed.sh` calls — not run directly |
| `perf-ingester-load.sh` | HUB-106: runs the real `opensearch-ingester` (`~/dev/opensearch-ingester`) in-process over synthetic Hermit V2 payloads — the real path for filling OpenSearch, writes to a separate index so it never touches `perf-seed.sh`'s data |
| `opensearch-resize-heap.sh` | HUB-106: bumps the local OpenSearch container's JVM heap without losing data (stop, commit, recreate — see below) |
| `steps/*.sh` | One file per component (`opensearch`, `novdata`, `novapi`, `novapp`, `plcsim`, `plcnode`, `luna`, `sync`, `prereqs`) — sourced by `run-novhub.sh`/`reset.sh`, not run directly |

Every script meant to be run directly takes `-h`/`--help`.

## Usage

```bash
./novhub-local-stack/setup-host.sh          # one-time: persist the three kernel limits below
./novhub-local-stack/run-novhub.sh up        # bring everything up, in order (prompts for sudo as needed)
./novhub-local-stack/run-novhub.sh status    # report every component's state, change nothing
./novhub-local-stack/run-novhub.sh down      # stop everything this script started; keeps data
./novhub-local-stack/run-novhub.sh sync      # load the latest weld into OpenSearch, then NovSync
./novhub-local-stack/reset.sh --all          # dev-hygiene: wipe containers/data for a clean retest
./novhub-local-stack/reset.sh --plc-stop     # stop just PLCSIM + plc-node, leave the rest running
```

Every script has `--help`. `up` stops at the first step that genuinely fails (or at LUNA's
manual reminder); rerun it once that's done and it continues from there. `status` never stops
early and never changes anything. `sync` is not part of `up` — run it after each simulated weld
to see it reflected in NovApp.

## Prerequisites

`up`/`status` check these first (`prereqs_check`) and stop if any are missing. All four were
found live during testing, not anticipated up front:

- Docker, Node.js/npm, the .NET 6 SDK, `git-lfs`, `python3`, `gh`, Docker Compose
- Three sysctl kernel limits — `vm.max_map_count >= 262144` (OpenSearch), and two separate
  `fs.inotify` limits (`max_user_watches >= 524288`, `max_user_instances >= 1024`) that
  `nodemon`/`vite` both need for their file watchers. `max_user_instances` is the one that
  actually caused `EMFILE` crashes here — a different kernel limit from `max_user_watches`,
  and easy to miss. Fix all three at once: `./novhub-local-stack/setup-host.sh` (persists via
  `/etc/sysctl.d/`, survives reboot, calls `sudo` internally only if needed).
- Open-file limit (`ulimit -n >= 65536`) — raised automatically by `prereqs_check`, no `sudo`
  needed; NovData+NOVAPI+NovApp's file watchers together can exceed a typical shell's 1024-fd
  default.

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

## What `down` does and doesn't do

`down` stops every component this script started or manages — `docker stop` (not `rm`) for
OpenSearch/NovData/NOVAPI's Postgres containers, a pidfile-tracked process-group kill for
NovData/NOVAPI/NovApp's background processes, `sudo systemctl stop` for PLCSIM, and `sudo pkill`
(as the `novarc` user) for `plc-node` — leaving data and installs intact so the next `up` picks
up where it left off. It never uninstalls anything, never removes a container, and never touches
LUNA (it never started it). The runbook's full "Cleanup" section (removing containers,
uninstalling PLCSIM/`plc-node`, deleting NovSync's venv) stays manual — see the runbook directly.

For dev-hygiene resets between test runs (wiping a container's data entirely, not just stopping
it, or stopping just PLCSIM+`plc-node`), use `./novhub-local-stack/reset.sh` — see its own
`--help`.

## PLCSIM and `plc-node`: what `up` actually does

Both are fully automated — `up` builds, installs, configures, and starts them for real,
prompting for `sudo` directly in your terminal only when needed:

- **PLCSIM**: build the `.deb` (`git lfs pull && ./build.sh`, no `sudo`) → `sudo apt install` it
  → move its REST port to `127.0.0.1:8081` (a scripted `sed`, not interactive editing — the
  service won't start at all without this) → `sudo systemctl enable --now plc-simulator`.
- **`plc-node`**: build the `.deb` (`deps`/`generate`/`build`/`sudo chown`/`package.sh` — the
  runbook's own one-liner shortcut doesn't actually work, confirmed) → `sudo apt install` it →
  point its config at PLCSIM (`sudo sed`, re-applied automatically if a later reinstall reverts
  it) → `sudo install -d` its log directory → start it as the `novarc` user in the background.

  `plc-node` picks its entire PLC tag map from the `SWR_TYPE` env var it's started with — the two
  sets are never merged: unset (the default here) loads the full `mem-map.cfg`/`alarms.cfg`
  (`weld_Mode_Current`, `Estop_Pressed`, etc. — what LUNA needs); `SWR_TYPE=NOVAI` loads the small
  `novai-mem-map.cfg`/`novai-alarms.cfg` instead (`HMI_NovAI_Mode`, etc.). This machine's own
  `/var/opt/novarc/configure` says `SWR_TYPE=NOVAI`, but LUNA's backend/frontend read that file
  directly and independently of what we pass to `plc-node` — the two don't have to match. Override
  with `PLCNODE_SWR_TYPE=NOVAI ./novhub-local-stack/run-novhub.sh up` if NovAI-mode tags are needed
  instead; doing so will bring back "could not find the item" errors for the full-map-only tags.

## OpenSearch: starting, checking, and recovering it by hand

`./run-novhub.sh up`/`status` bring OpenSearch up automatically by calling `opensearch_up`/
`opensearch_check` in [`steps/opensearch.sh`](steps/opensearch.sh) — that file is the single
source of truth for the container name, port, image, index name, and default heap
(`OPENSEARCH_CONTAINER`, `OPENSEARCH_PORT`, `OPENSEARCH_IMAGE`, `OPENSEARCH_INDEX`,
`OPENSEARCH_HEAP`, all overridable by env var of the same name). It is sourced, not run directly
(see the `steps/*.sh` row in Scripts above) — the manual commands below are the same operations
`steps/opensearch.sh` runs, written out by hand for when you want to do this yourself, or verify/
recover without going through the script.

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

The default heap for a freshly-created container (Scenario B, or any future `run-novhub.sh up`
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
LUNA/PLCSIM/plc-node or NovData — so it needs `run-novhub.sh up`'s OpenSearch container and
NovApi's own `docker compose` stack running first, not the whole local stack. Everything it
creates is tagged (a reserved robot-id range, one synthetic group/user) so `remove` can undo it
cleanly; it's idempotent, re-running `seed` on an already-seeded stack just prints
`already seeded`. The synthetic test user's login is written to
`.state/secrets/perf-test-user.secret` (0600, in a 0700 directory) — never printed twice, never
logged elsewhere.

### The real path: `opensearch-ingester`

`perf-seed.sh` writes OpenSearch docs by hand, in a shape that doesn't match production (no
`robot_type`, and it never exercises the real preset-matching logic). The real local path uses
`~/dev/opensearch-ingester` (`github.com/Novarc-Software/opensearch-ingester`) itself:

```bash
./novhub-local-stack/perf-ingester-seed.sh seed        # robot + matching preset rows (ids 910001+)
./novhub-local-stack/perf-ingester-load.sh \            # generate + ingest synthetic Hermit V2 runs
  -template /path/to/a/real/Hermit_V2_sample.json \     # read-only - never copy a real sample into a repo
  -robot-id-start 910001 -robot-count 2 -runs-per-robot 10 -points-per-run 10
./novhub-local-stack/perf-ingester-seed.sh remove       # undo exactly what seed created
```

`perf-ingester-load.sh` builds synthetic Hermit V2 JSON payloads - using a real sample file as
the structural template (`-template`, required: real schema/field order, real `weld_summary`
keys, real value-row patterns cycled for variation) - and feeds them through the ingester's own
`RouteAndProcess` in-process (see `~/dev/opensearch-ingester/cmd/perfload`) — real doc shapes,
real preset-matching/association code, no hand-written OpenSearch docs. The template file is
only ever read, never copied or committed anywhere. It writes to `ES_INDEX` (default
`novhub-local-ingester`, a separate index from `perf-seed.sh`'s `novhub-local`, so the two never
collide) and needs NovApi's own Postgres and the local OpenSearch container up first. Point
NovApi at either index via its own `OPENSEARCH_INDEX` env var.

## Manual steps (LUNA only)

LUNA's frontend needs the real desktop display, which nothing running non-interactively can
check or start — `up`/`status` always print the reminder:

- Start the backend (T5, `run-luna.sh backend`) and confirm the frontend window is open (T6,
  `run-luna.sh frontend`, needs the real desktop display).

See `~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` for the full procedure
these steps are drawn from, including starting a simulated weld and the closing validation.

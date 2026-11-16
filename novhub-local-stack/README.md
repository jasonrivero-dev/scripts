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
| `perf-seed.sh` | HUB-106: seed/remove a frozen synthetic dataset (10 robots × 2,000 runs) in OpenSearch + NovApi's Postgres, for perf testing |
| `perf-seed.py` | The actual seed/remove logic `perf-seed.sh` calls — not run directly |
| `novapi-psql.sh` | Opens `psql` against NovApi's own Postgres (`cloud_db_dev`) — no password needed, runs inside the container |
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

## HUB-106 perf-testing tools

```bash
./novhub-local-stack/perf-setup.sh          # one-time: install Playwright (prompts for sudo on the Chromium/apt step)
./novhub-local-stack/perf-seed.sh seed      # create the frozen synthetic dataset (10 robots x 2,000 runs)
./novhub-local-stack/perf-seed.sh remove    # delete exactly what seed created, nothing else
./novhub-local-stack/novapi-psql.sh -c "select count(*) from weld_test_reports;"   # one-shot query, no password
./novhub-local-stack/novapi-psql.sh         # interactive psql prompt, no password
```

`perf-seed.sh seed` writes directly to OpenSearch and NovApi's own Postgres — never through
LUNA/PLCSIM/plc-node or NovData — so it needs `run-novhub.sh up`'s OpenSearch container and
NovApi's own `docker compose` stack running first, not the whole local stack. Everything it
creates is tagged (a reserved robot-id range, one synthetic group/user) so `remove` can undo it
cleanly; it's idempotent, re-running `seed` on an already-seeded stack just prints
`already seeded`. The synthetic test user's login is written to
`.state/secrets/perf-test-user.secret` (0600, in a 0700 directory) — never printed twice, never
logged elsewhere.

## Manual steps (LUNA only)

LUNA's frontend needs the real desktop display, which nothing running non-interactively can
check or start — `up`/`status` always print the reminder:

- Start the backend (T5, `run-luna.sh backend`) and confirm the frontend window is open (T6,
  `run-luna.sh frontend`, needs the real desktop display).

See `~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` for the full procedure
these steps are drawn from, including starting a simulated weld and the closing validation.

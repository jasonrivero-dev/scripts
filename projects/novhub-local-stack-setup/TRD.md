# TRD: novhub-local-stack-setup

**Status:** Draft
**Author:** Jaguar Rivero
**Date:** 2026-11-12
**Related PRD:** [PRD.md](PRD.md)

---

## Note on template fit

This repo has no database and no HTTP API of its own (`CLAUDE.md` → `## Structural Overrides`:
Bash scripts, no framework). This feature is a CLI tool that orchestrates seven *other*
repositories' own services as a client. **Data Model** is mostly N/A (this script owns no
schema); **API Contract** is adapted to document the external calls this tool makes (Docker,
Postgres, OpenSearch, systemd) rather than an API this repo exposes.

All facts below marked "confirmed" came from a read-only research pass against the real repos
and live machine state on 2026-11-12 (not assumed from the runbook alone). Everything marked
⚠️ ASSUMPTION is unresolved and must be confirmed during `/implement`, recorded in this TRD's
Clarifications table.

## Architecture Overview

```
run-novhub.sh {up|status|down|sync}
   │
   ├─ lib/common.sh ─ log/warn/error (reused from ../lib/dev-log-lib)
   │                  have_container / container_running / listening
   │                  pidfile start/stop/is_running
   │                  prompt_secret (hidden read, only when a step still needs it)
   │                  read_identity (parses /var/opt/novarc/configure; hard stop, no fallback)
   │
   ├─ steps/prereqs.sh     ── check-only: tool presence (docker/node/npm/dotnet/git-lfs/gh/
   │                          python3) + OpenSearch's vm.max_map_count (sudo) — runs ONCE before
   │                          `up`/`status` walk the component list below, not a walked component
   │                          itself (nothing to start/stop, so it has no `_down`)
   │
   ├─ steps/opensearch.sh  ── docker run os-local ──▶ OpenSearch :9200 ──▶ PUT novhub-local index
   ├─ steps/novdata.sh     ── docker run novdata-pg ──▶ roles (initial-roles.sql)
   │                          ──▶ background `dotnet run --project NovData` (pidfile)
   ├─ steps/novapi.sh      ── docker compose up -d db_cloud_dev ──▶ SQL migration loop
   │                          ──▶ SQL seed (robot/api_key/groups/role/user)
   │                          ──▶ .env check/fix ──▶ background `npm run dev` (pidfile)
   ├─ steps/novapp.sh      ── .env check/fix ──▶ background `npm run dev` (vite) (pidfile)
   ├─ steps/plcsim.sh      ── check-only: build/install/port-config/service (all owner-run)
   ├─ steps/plcnode.sh     ── check-only: build/install/log-dir/service (all owner-run)
   ├─ steps/luna.sh        ── check-only: `run-luna.sh backend`/`frontend` (owner-run)
   └─ steps/sync.sh        ── loader.py (NovData Postgres ──▶ OpenSearch _bulk)
                              ──▶ NovSync db_sync_to_rds.py (NovData Postgres ──▶ NOVAPI /api/v1/sync)

`up` runs `prereqs_check` once first (stops on failure), then walks the component list top to
bottom, stopping at the first non-`already`/`created` result (`failed` or `manual`). `status`
walks the same list calling only `_check`, never stopping early. `down` walks the component
list in reverse calling `_down`, continuing past failures (best effort, reports what it could
not stop) — for `plcsim`/`plcnode`/`luna`, `_down` is a no-op that prints `nothing to stop (never
started by this script)`, since the script never starts any of those three itself. `sync` runs
only steps/sync.sh, standalone.
```

Resolved (confirmed directly by the NOVAPI peer session, see Clarifications #1): `db_cloud_dev`
sets `POSTGRES_PASSWORD=postgres` as a fixed literal in `docker-compose.yml` — the same literal
across all 4 DB services, no volumes declared (data is lost if the container is removed). This
is a shared, non-secret dev default, not something this script needs to prompt for or protect.

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | Bash for orchestration (`run-novhub.sh` + `lib/`, `steps/*.sh`), Python for the loader (`loader.py`) | Matches this repo's existing convention (`luna/run-luna.sh`, `telemetry/telemetry.sh`); the loader needs safe NDJSON/date/number handling, better served by Python, same as this repo's `tools/md2word/drive_upload.py` precedent |
| Logging | Reuse `lib/dev-log-lib`'s `log`/`warn`/`error` (no new log levels) | Only functions that exist repo-wide today; adding a 4th (`success`/`fatal`) would diverge from every other script for no behavioral gain |
| Background-process management | New: pidfile + log file under `novhub-local-stack/.state/` (gitignored), `nohup ... &`, `kill -0`/`kill` | Confirmed nothing like this exists anywhere in the repo yet — this is the first script that needs to track a backgrounded process instead of a Docker container or a human-held terminal |
| Loader's Python dependencies | Share one script-managed venv (`novhub-local-stack/.venv/`, gitignored) with `psycopg2-binary`+`requests` — also used to invoke NovSync's own `db_sync_to_rds.py` | NovSync's own `requirements.txt` (confirmed) already needs exactly these two libraries; one venv avoids installing `psycopg2-binary` twice. Deliberately placed inside the repo (matching `luna/.cache/`), not at `~/novsync-venv` like the runbook's manual instructions — the runbook's location was a manual-session convenience, not a rule this script must follow |
| Step contract | Each step module exposes `<name>_check()`, `<name>_up()`, `<name>_down()`; `_up()`/`_check()` return 0 (printed message says `created`/`already ...`), 1 (`failed`), or 2 (`manual` — stopped, needs the owner) | Matches the owner's own proposed shape from the runbook, made concrete: distinguishing exit code 1 from 2 lets `up`'s driver report "this needs you" differently from "this broke," while both still halt the sequence |
| `.env` key handling | A shared `ensure_env_kv(file, KEY, VALUE)` helper appends a missing key or corrects one whose value doesn't match a runbook-mandated fixed value (ports, hosts, `IS_NOVAI`, `VITE_*` settings, and — confirmed via the NOVAPI peer session — `DB_USERNAME=postgres`/`DB_PASSWORD=postgres`, the same fixed literal `docker-compose.yml` sets on all 4 DB services); it never touches a key that holds a real, non-fixed secret (`JWT_SECRET`, the `NOVAPI_ADMIN_*` sample values this stack never calls) | Confirmed via research that `.env.sample` is missing `OPENSEARCH_HOST`/`OPENSEARCH_INDEX`/`IS_NOVAI` entirely (append case) and that `novhub`'s sample defaults `VITE_PORT=5000` against the runbook's required `5173` (correct-mismatch case); confirmed via NOVAPI that `DB_USERNAME`/`DB_PASSWORD` are also a fixed, shared, non-secret dev default, not a real credential — all of these are mechanical, not judgment calls |
| Identity source | `/var/opt/novarc/configure`, parsed by `grep`+`sed` line-by-line, never `source`d | Per rev 0.5 of the runbook and the PRD's Goal 6; confirmed on this machine: file exists, all 21 fields are single-quoted, the 4 fields this script needs (`SWR_ID`, `SWR_NUMBER`, `SWR_CUSTOMER`, `SWR_LOCATION`) are present |

## Data Model

N/A — this script owns no schema. It applies NOVAPI's own pre-existing migration files
unmodified (confirmed: 80 files under `~/dev/NovApi/db/migrations`, first by name
`20191115-110000-initial-centralisation-db.aggr_migration`) and seeds rows into NOVAPI's own
existing tables using the exact `INSERT ... WHERE NOT EXISTS` statements from the runbook
(robot, `api_key`, `robot_tier`, `groups`, `group_resource`, `roles`, `users`, `role_resource`).

NovData's schema is likewise untouched by this script — `res/initial-roles.sql` (confirmed,
verbatim) creates the `novdata`/`noveye` roles; NovData's own migrations (run by NovData itself
on first start, not by this script) are what seed its `robot`/`replication_config` tables.

Resolved (confirmed directly by the NovData peer session, see Clarifications #2 — corrected
after an arithmetic slip in the first answer): a fully migrated database ends up with **10**
`replication_config` rows, not the runbook's originally assumed 6 — the original 6 (`robot` 0,
`migration` 100, `weld_run` 200, `weld_data` 300, `replication_config` 400,
`replication_history` 500) plus `weld_run_end` (250, from
`20190417-160000-add_weld_run_end.sql_migration`) plus `stop_sources`/`stop_device_types`/
`stop_reasons` (850/860/870, from `20220503-093000-add_stop_reasons.sql_migration`) — no
migration ever deletes a row. Matches runbook rev 0.6's step 2.5, which now lists all ten by
name. Step 3's verify checks the specific rows this stack needs (`robot`, `weld_run`,
`weld_run_end` present and enabled) and separately asserts the total is 10, as a canary for a
future migration changing that count, rather than hardcoding the runbook's original 6.

## External Integrations

### OpenSearch (local, security disabled)

| Call | Purpose |
|------|---------|
| `GET http://127.0.0.1:9200/` | readiness check (Step 1 check/verify) |
| `GET http://127.0.0.1:9200/novhub-local` (expect `200`) | index-exists check |
| `PUT http://127.0.0.1:9200/novhub-local` + `novhub-local-stack/opensearch-mapping.json` | index creation (this script carries its own copy of the mapping, not a reference into `~/dev/presentations/`, so the script has no runtime dependency on that directory) |
| `POST http://127.0.0.1:9200/_bulk` (loader, NDJSON body) | per-document idempotent upsert, `_id` built from robot+run(+data point), per the runbook's field mapping (its step 8.3, reproduced in Step 9 below) |

### NOVAPI's Postgres (`db_cloud_dev`, host port 5433)

Accessed only via `docker compose exec -T db_cloud_dev psql -U postgres -d swrdb_aggr`
(confirmed service/user/db names) — never a direct host-side `psql`, matching the runbook.
Migration loop and seed statements are the runbook's own, unmodified (see Implementation Plan
Step 4).

### NOVAPI's own HTTP API

| Call | Purpose |
|------|---------|
| `GET http://127.0.0.1:3000/api/v1/ping` → `{"status":"/pong"}` | liveness check for `status`/`up`'s verify phase |

`POST /api/v1/admin/robot` (confirmed to exist, `middlewares/config/policy.admin.js`) is
deliberately never called — the seed goes directly to Postgres instead, matching the runbook
(that route needs an admin user this script never creates).

### NovData's Postgres (`novdata-pg`, host port 5432)

`docker exec novdata-pg psql -U postgres -d swrdb` for role creation/verification and
`replication_config`/`robot` checks — the runbook's own commands, unmodified.

### Robot identity file (`/var/opt/novarc/configure`)

Read-only, four fields only (`SWR_ID`, `SWR_NUMBER`, `SWR_CUSTOMER`, `SWR_LOCATION`), parsed
line-by-line (see `lib/common.sh`'s `read_identity`, Stack Decisions above). Every other field
in that file (confirmed present: `AWS_IAM_KEY`, `SWR_API_KEY`, `SWR_DB_KEY`, `PG_PASSWORD`,
`SWR_API_URL`, etc.) is never read, printed, logged, or copied anywhere by this script.

## Implementation Plan

> Ordered steps. Each step is a commit boundary.

### Step 0: Scaffolding and shared helpers

- **Files:** `novhub-local-stack/lib/common.sh`, `novhub-local-stack/.gitignore` entry (add
  `novhub-local-stack/.state/` and `novhub-local-stack/.venv/` to the repo root `.gitignore`,
  matching the existing `luna/.cache/` entry)
- **What:** `have_container`, `container_running`, `listening` (ports, via `ss -ltnu`);
  pidfile helpers (`start_background`, `is_running`, `stop_background`); `prompt_secret`
  (`read -rs`, skips when the variable is already set); `read_identity` (parses
  `/var/opt/novarc/configure`, hard stop per Stack Decisions); sources `../lib/dev-log-lib` for
  `log`/`warn`/`error`, following the exact sourcing idiom already used by `luna/run-luna.sh`.
- **Verify:** source the file standalone in a throwaway shell and call each helper manually
  against the machine's current real state (e.g. `have_container novdata-pg` should currently
  be true, `listening 3000` should currently be false — both confirmed by research above).

### Step 1: Prerequisites (`novhub-local-stack/steps/prereqs.sh`)

- **Files:** `steps/prereqs.sh`
- **What:** `prereqs_check` only (no `_up`/`_down` — nothing to start or stop). Tool-presence
  check (`docker`, `node`, `npm`, `dotnet`, `git-lfs`, `python3`, `gh`; `docker compose version`),
  reporting any missing tool and stopping (`manual`, exit 2). OpenSearch's `vm.max_map_count`
  check (PRD AC3's named example): if `sysctl -n vm.max_map_count` is below `262144`, print the
  exact `sudo sysctl -w vm.max_map_count=262144` command and stop (`manual`); otherwise `already
  set`. Called once by `run-novhub.sh` before walking the component list for both `up` and
  `status` — it is a one-time gate, not a walked component, so it is absent from
  `ORDERED_STEPS` and has no role in `down`.
- **Verify:** on this machine, `vm.max_map_count` was not checked during research — confirm its
  current value during `/implement` and exercise both branches (below/above `262144`).

### Step 2: OpenSearch (`novhub-local-stack/steps/opensearch.sh`)

- **Files:** `steps/opensearch.sh`, `novhub-local-stack/opensearch-mapping.json` (copied in,
  the script's own canonical copy)
- **What:** `opensearch_check`/`_up`/`_down` — the runbook's docker-run/wait/PUT-index
  commands, unmodified, using `have_container os-local` / `container_running os-local`.
- **Verify:** against this machine's current state (`os-local` already up per research),
  `opensearch_up` must print `already exists` and change nothing; `opensearch_down` must
  `docker stop os-local` without removing it.

### Step 3: NovData (`steps/novdata.sh`)

- **Files:** `steps/novdata.sh`
- **What:** container start (`novdata-pg`) — when the container doesn't exist yet, prompts for
  the **Postgres superuser password** via `prompt_secret` (one of the PRD's four named secrets,
  distinct from the `novdata` role password below) and passes it as `POSTGRES_PASSWORD` to
  `docker run`, exactly as the runbook's step 2.1 does; when the container already exists, this
  prompt is skipped entirely. Then `initial-roles.sql` application/verify, identity via
  `read_identity`, environment construction (`SWR_NUMBER`/`SWR_ID`/etc., plus
  `SWR_REPL_FILE_SRC_PATH` pointed at `novhub-local-stack/.state/novdata-logs/`, created by this
  step, replacing the runbook's `~/novdata-dev`), the **`novdata` role password** (the second,
  distinct secret) read via `prompt_secret` only when the roles check fails, background start of
  `dotnet run --project NovData` (pidfile), verify via `listening 8000` + the `robot` row query.
- **Verify:** run against the real `~/dev/NovData` checkout; verify query asserts `robot`,
  `weld_run`, and `weld_run_end` are present and enabled, plus a total-row-count canary of 10
  (see Data Model, resolved via the NovData peer session).

### Step 4: NOVAPI (`steps/novapi.sh`)

- **Files:** `steps/novapi.sh`
- **What:** `docker compose up -d db_cloud_dev` (confirmed service/port/user, password per
  Clarifications #1); the migration loop (confirmed: 80 files, first-by-name ordering matches
  the runbook exactly); `.env` creation from `.env.sample` if missing, then `ensure_env_kv` for
  `OPENSEARCH_HOST`, `OPENSEARCH_INDEX`, `IS_NOVAI` (confirmed: absent from `.env.sample`, must
  be appended), `DB_USERNAME=postgres`/`DB_PASSWORD=postgres` (confirmed fixed dev default, not
  a secret — see Stack Decisions), and `DB_PORT`/`DB_NAME` (confirmed: `.env.sample` already
  matches, kept as checks for safety); the SQL seed (robot/`api_key`/groups/role/user, runbook's
  own statements, unmodified) gated on the `sim@example.com` existence check; `SECRET_KEY`/
  `LOCAL_PASSWORD` via `prompt_secret` only when the seed check fails; password hash via
  NOVAPI's own `bcryptjs`, exactly as the runbook does (`node -e "..."`); background
  `npm install && npm run dev`; verify via `GET /api/v1/ping`.
- **Verify:** none — the open question on `db_cloud_dev`'s Postgres password is resolved.

### Step 5: NovApp (`steps/novapp.sh`)

- **Files:** `steps/novapp.sh`
- **What:** `.env` creation from `.env.sample` if missing, `ensure_env_kv` for
  `VITE_SERVER_URL`, `VITE_IS_NOVAI`, `VITE_PRODUCTION`, `VITE_PORT` (confirmed: sample's
  `VITE_PORT=5000` must be corrected to `5173`); background `npm install && npm run dev`
  (vite); verify via `listening 5173`.
- **Verify:** confirm `npm run dev` → `vite` (confirmed in `package.json`) actually honors
  `VITE_PORT` from `.env` rather than a CLI flag, during `/implement`.

### Step 6: PLCSIM (`steps/plcsim.sh`)

- **Files:** `steps/plcsim.sh`
- **What:** check-only for every stage (`.deb` build via `git lfs pull && ./build.sh`; install
  via `sudo apt install`; the `[rest].bind` port-move via `sudoedit`; `sudo systemctl enable
  --now plc-simulator`) — each prints the runbook's exact command, the terminal to run it in
  (T1, this runbook has no dedicated PLCSIM terminal beyond T1), and the expected result, then
  returns `manual` (exit 2) if not yet done. Verify phase (no `sudo`) checks `listening 9600`,
  `listening 8081`, and `GET http://127.0.0.1:8081/api/status`. `plcsim_down` is a no-op
  (`nothing to stop (never started by this script)`) — this script never runs
  `systemctl enable --now`, so it has nothing of its own to stop.
- **Verify:** none of this needs root to *check* — only to act — so `plcsim_check` can run
  freely; confirm during `/implement` once a real build/install has happened on this machine
  (currently neither has: no `dist/`, service `inactive`, confirmed by research).

### Step 7: `plc-node` (`steps/plcnode.sh`)

- **Files:** `steps/plcnode.sh`
- **What:** check-only for build (`./build_docker.sh package`, which runs `deb/package.sh`
  after the build stages — confirmed, not a literal `deps/generate/build/package` case inside
  `build_docker.sh` itself), install (`sudo apt install`), log directory (`sudo install -d`),
  and service start — same check-and-instruct shape as Step 5. The build-output check looks for
  `package/plc_node-ubuntu_22.04-x64-*.deb` (confirmed path and naming from the PLCNODE peer
  session, see Clarifications #3; `package/` is git-ignored and created by the build, version
  is the CMake project version plus a build number, e.g. `1.0.2.dev` when unset). The
  config-verify check does **not** assume `plc-address` is already correct: confirmed (PLCNODE
  peer session) the shipped template has the **real** PLC address active
  (`192.168.250.1:9600`), simulator address (`127.0.0.1:9600`) only commented out, and nothing
  in the install path rewrites it — so this check always inspects the live value and, when it
  isn't `127.0.0.1:9600`, prints the exact `sudoedit` instruction (same shape as PLCSIM's own
  port-move step) rather than skipping. `grpc-bind-address`/`listening 9601` checks unchanged.
  `plcnode_down` is a no-op (`nothing to stop (never started by this script)`), same reasoning
  as PLCSIM.
- **Verify:** none — both open questions for this step are now resolved (see above).

### Step 8: LUNA (`steps/luna.sh`)

- **Files:** `steps/luna.sh`
- **What:** check-only — `pgrep -x luna` for the backend, a printed "confirm the window
  opened" reminder for the frontend (no process check attempted, per the PRD). Prints the exact
  `~/dev/scripts/luna/run-luna.sh backend`/`frontend` commands and which terminal (T5/T6) when
  not yet up; returns `manual` (exit 2). `luna_down` is a no-op (`nothing to stop (never started
  by this script)`) — LUNA is always started by the owner, in their own terminals.
- **Verify:** confirmed no `luna`/`flutter` process is running on this machine right now, so the
  first real `up` run will exercise the "not yet up, print instructions" branch, not the
  "already running" branch — both must be manually exercised before this step is done.

### Step 9: `run-novhub.sh` (entrypoint)

- **Files:** `novhub-local-stack/run-novhub.sh`
- **What:** sources `lib/common.sh` and every `steps/*.sh`; defines `ORDERED_STEPS=(opensearch
  novdata novapi novapp plcsim plcnode luna)` — `prereqs` is deliberately not in this array (see
  Step 1); `up` calls `prereqs_check` once, then walks `ORDERED_STEPS` calling `<name>_up`,
  stopping at the first non-zero; `status` calls `prereqs_check` then walks the list calling
  `<name>_check` only, printing a table, never stopping early; `down` walks `ORDERED_STEPS` in
  reverse calling `<name>_down`, continuing past failures (best-effort, matching Goal 4's "leave
  the machine in a stable state") and reporting what it could not stop — for `plcsim`/`plcnode`/
  `luna` this is always the documented no-op (Steps 6–8); dispatch follows the exact
  `cmd="${1:-...}"; case "$cmd" in ... esac` idiom already used by `luna/run-luna.sh`.
- **Verify:** run `up`, `status`, `down`, `up` again end-to-end (see Test Plan).

### Step 10: OpenSearch loader + `sync` (`steps/sync.sh`, `novhub-local-stack/loader.py`)

- **Files:** `steps/sync.sh`, `loader.py`, `novhub-local-stack/requirements.txt`
  (`psycopg2-binary`, `requests` — matching NovSync's own pinned versions where practical)
- **What:** `sync_up` (only subcommand that calls this) — (1) creates/reuses
  `novhub-local-stack/.venv/` and installs `requirements.txt` if needed; (2) runs `loader.py`,
  which connects to NovData's Postgres, reads `weld_run` joined to `weld_run_end` and
  `weld_data`, builds the exact field mapping from the runbook's step 8.3 (run documents keyed
  `${robot_id}_${run_number}_run`, data points keyed by robot+run+point so reposting replaces
  rather than duplicates), and `POST`s one `_bulk` request to `novhub-local`; (3) invokes
  NovSync's `db_sync_to_rds.py init` (idempotent) and then a plain run, with its environment
  built from the shared identity (`read_identity`) plus `prompt_secret` for `SWR_API_KEY`/
  `SWR_DB_KEY` only when NovSync's own state requires it, and `SWR_REPL_FILE_SRC_PATH` pointed
  at `novhub-local-stack/.state/novsync/` instead of the runbook's `~/novsync-var`.
- **Verify:** the runbook's own idempotency claim for the loader ("loading the same rows again
  replaces the documents") must be exercised twice in a row during `/implement`, confirming the
  `novhub-local` document count does not grow on the second call.

### Step 11: Documentation

- **Files:** `novhub-local-stack/README.md`, root `README.md` (new H2 section, matching the
  one-section-per-folder convention), `CLAUDE.md` → `## Application Overview` (add
  `novhub-local-stack/` to Main components)
- **Source:** no PRD Goal/AC names this directly — it follows this repo's own established,
  repeatedly-applied convention (every prior feature this session got the same README/CLAUDE.md
  treatment), not a PRD requirement. Flagged here explicitly per `/trd-review` rather than left
  an unbacked step.
- **What:** usage table (`up`/`status`/`down`/`sync`), prerequisites, the four secrets, what
  `down` does and doesn't do, and the manual steps for PLCSIM/`plc-node`/LUNA.
- **Verify:** `grep -n "^## " README.md` confirms H2 order matches the top table, per this
  repo's existing convention (checked after every prior README update this session).

## Test Plan

No automated test framework in this repo (Structural Overrides) — manual, end-to-end, against
the real machine and real sibling repos, per this repo's established verification convention.

### Manual / Integration Scenarios

| Scenario | How | PRD Criterion |
|----------|-----|----------------|
| Prerequisites gate | With `vm.max_map_count` below `262144`, run `up`; confirm it prints the exact `sudo sysctl` command and stops before touching OpenSearch | AC3 |
| Fresh `up` from a clean state | `docker rm -f os-local novdata-pg`, stop any running NOVAPI/NovApp processes, then run `up` end to end; every step should print `created`, not `already ...`; confirm the Postgres-superuser prompt appears once (for `novdata-pg`'s creation) and the `novdata`-role-password prompt appears separately (for the roles check) — two distinct prompts, not one | AC1, AC8 |
| `up` against already-running state | Run `up` a second time immediately; every step must print `already ...` and change nothing | AC2 |
| Sudo/build step reached | Run `up` on a machine where PLCSIM/`plc-node` aren't built/installed; confirm it prints the exact command/terminal/expected result and stops (exit 2), without attempting the action | AC3 |
| `.env` missing a key | Temporarily remove `OPENSEARCH_HOST` from NovApi's `.env`; confirm `up` names it exactly and does not start NOVAPI | AC4 |
| `down` then `up` | Run `down`, confirm containers are `Exited` not removed and pidfiles' processes are gone, `docker ps -a` still lists them, then `up` again brings everything back via the `already exists (started if it was stopped)` branch | AC5 |
| LUNA not running | With LUNA stopped, run `up`; confirm it prints the exact `run-luna.sh` commands and terminal, and stops; start LUNA by hand, rerun `up`, confirm it now continues | AC6 |
| `sync` idempotency | Run `sync` once after a manual weld, note the `novhub-local` document count, run `sync` again with no new weld; confirm the count is unchanged | AC7 |
| Secrets skipped when unneeded | With all roles/seeds already in place, run `up`; confirm no secret prompt appears | AC8 |
| `status` after full `up` | Run `status`; confirm it reports every component including LUNA's check-only state, and changes nothing (verify via `docker ps`/`ss` before and after) | AC9 |

## Rollout

- [ ] No migration to run against this repo itself (the feature only applies *other* repos'
      existing migrations, at runtime, when the owner runs `up`)
- [ ] Owner reviews and merges the PR (docs-first per `~/.claude/CLAUDE.md`'s Git Safety section
      is N/A here — this PR carries both the PRD/TRD and the implementation, since `/implement`
      branches from this same docs branch per the owner's instruction to skip a separate branch)
- [ ] Smoke test: run `up`, `status`, `down`, `sync` end to end on this machine per the Test Plan
      above, with the owner present for every `sudo`/build/LUNA step
- [ ] Rollback: `down` (stops everything, no data loss); if the script itself needs reverting,
      `git revert` the implementation commit(s) — nothing it does is irreversible except what the
      owner explicitly chose to run by hand (installs, `sudo` steps), which this script never
      performs itself

## Clarifications

> Answers to UNBACKED assumptions raised during `/implement`. Each row backs later steps and
> sessions as `TRD: Clarifications #<n>`. Never record secret values here.

| # | Step | Question | Answer | Source | Date |
|---|------|----------|--------|--------|------|
| 1 | Step 4 (NOVAPI) | Does `db_cloud_dev` set a `POSTGRES_PASSWORD`, and how? | Fixed literal `postgres` in `docker-compose.yml`, same across all 4 DB services, no volumes declared, not trust auth. NovApi's own `.env` needs matching `DB_USERNAME`/`DB_PASSWORD` written in. | NOVAPI peer session | 2026-11-12 |
| 2 | Step 3 (NovData) | How many `replication_config` rows after a fresh, fully-migrated start — 6 or 7? | Neither — 10 (corrected from an initial "9", an arithmetic slip: 6+1+3=10). Original 6 (robot/migration/weld_run/weld_data/replication_config/replication_history) + `weld_run_end`(250) + `stop_sources`/`stop_device_types`/`stop_reasons`(850/860/870). No migration deletes a row. Matches runbook rev 0.6. | NovData peer session | 2026-11-12 |
| 3 | Step 7 (plc-node) | Does the installed config already point at the simulator? What's the real build output path? | No — shipped template has the real PLC address active; needs an edit every time, nothing rewrites it post-install. Output: `package/plc_node-ubuntu_22.04-x64-<ver>.deb` (git-ignored, created by `./build_docker.sh package`; `<ver>` = CMake project version + build number, e.g. `1.0.2.dev`). | PLCNODE peer session | 2026-11-12 |

## Traceability Matrix

| PRD Acceptance Criterion | TRD Step | Test |
|--------------------------|----------|------|
| Clean machine → `up` brings OpenSearch/NovData/NOVAPI/NovApp up in order, `created`/`already ...` | Steps 2–5, 9 | AC1 |
| Existing state → `up` prints `already ...`, changes nothing | Steps 2–9 (every component check, not just the background-process ones) | AC2 |
| Sudo/build step → prints command/terminal/expected result, stops | Steps 1 (`vm.max_map_count`), 6, 7 | AC3 |
| `.env` missing/placeholder key → stops, names it, doesn't start NOVAPI | Steps 4, 5 | AC4 |
| `down` stops via pidfile/`docker stop`, no data/install loss | Step 9 (down path), Steps 3–5 | AC5 |
| LUNA not up → prints commands/terminal, `up` stops; rerun detects and continues | Steps 8, 9 | AC6 |
| Loader run twice → document count does not grow | Step 10 | AC7 |
| Secret steps already done → prompt skipped (4 distinct secrets: Postgres superuser, `novdata` role, robot API key, sign-in password) | Steps 3, 4 | AC8 |
| `status` reports every component including LUNA, no action taken | Step 9 (status path) | AC9 |

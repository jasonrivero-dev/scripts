# PRD: novhub-local-stack-setup

**Status:** Draft
**Author:** Jaguar Rivero
**Date:** 2026-11-12
**Tickets:** (none)
**Track:** Standard
**Related TRD:** [TRD.md](TRD.md) | Not yet created

---

## Problem Statement

Validating the full local NovHub stack — the weld-data path (PLCSIM → NovData → an OpenSearch
loader → NOVAPI → NovApp) and the control path (LUNA → `plc-node` → PLCSIM) — today means
manually working through a 9-part runbook
(`~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md`) by hand: pasting SQL/curl/
shell blocks into 6 terminals in a fixed order, across 7 repositories, remembering which steps
need `sudo`, which need a typed secret, and which are safe to skip because they're already done.

If this isn't built: every local validation run continues to mean re-deriving, from the runbook
or from memory, what's already up and what still needs doing, with no single way to check
overall status or bring everything down to a stable state afterward.

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|---------------|
| Tool operator | The repo owner, validating the full local stack on one machine | One command brings the automatable parts of the stack up, in order, idempotently; a second reports status; a third stops everything cleanly |

## Goals

1. `novhub-local-stack/run-novhub.sh up` brings every component to a running (or, for LUNA,
   confirmed-running) state in the runbook's documented order (OpenSearch → NovData+Postgres →
   NOVAPI+Postgres+migrations+seed → NovApp → PLCSIM → `plc-node` → LUNA), stopping at the first
   step that fails or needs a manual action, and continuing correctly on a rerun once that
   action is done.
2. Every step is check → act-only-if-missing → verify, printing `created` or `already ...`,
   matching this repo's idempotency rule (`~/.claude/CLAUDE.md`) and the runbook's own shape.
3. `run-novhub.sh status` runs every check/verify with no action, and reports every component's
   state in one pass.
4. `run-novhub.sh down` stops every component this script started or manages, leaving the
   machine in a stable, re-`up`-able state without deleting data or uninstalling anything. That
   fuller teardown remains the runbook's separate, manual "Cleanup" section, out of scope here.
5. NovData, NOVAPI's own process, and NovApp run as background-managed services this script can
   start, check, and stop on its own, without needing a dedicated terminal — the same way the
   Docker-based components already run detached.
6. NOVAPI's database is fully migrated and seeded (robot, `api_key`, group, role, user) before
   its API process starts, so the API never has to initialize itself against an empty database.
   The robot identity shared by NovData, the NOVAPI seed, and NovSync (id, name, customer,
   location) is sourced from the robot's own existing configuration, never invented and never
   defaulted — if that configuration is missing or unusable, the script stops rather than
   guessing, and it never exposes any of that configuration's other, unrelated entries (it holds
   cloud credentials out of scope for this local stack). This script does not depend on or call
   `run-novapi.sh` — that tool is a separate, already-approved script for day-to-day NovApi-only
   dev work (its `migrate` stays print-only and its `api_key` step stays manual-only, by that
   PRD's own decision), and reusing its single atomic `up` here doesn't fit a sequence that needs
   migration and seeding between Postgres and the API.
7. Every `sudo`-gated step, and every build step (PLCSIM's and `plc-node`'s package builds,
   regardless of the runbook's own "no sudo needed" note on those two), is check-and-instruct
   only: the script prints the exact command, which terminal to run it in, and what to expect,
   then stops. The script performs only the non-privileged checks/verifies around them.
8. LUNA is check-only in every case (backend: the runbook's own `pgrep -x luna`; frontend: a
   manual "confirm the window opened" — it needs the real desktop display). The script never
   starts or backgrounds LUNA. It prints the exact `run-luna.sh backend`/`frontend` commands and
   which terminal, stops there, and picks up once the owner has started them and reruns
   `up`/`status`.
9. A new OpenSearch loader reads `weld_run`/`weld_run_end`/`weld_data` from NovData's Postgres
   and posts idempotent per-document `_bulk` requests to the `novhub-local` index, built to the
   field mapping the runbook documents (its step 8.3) — this is the one piece of genuinely new
   code in this feature; everything else orchestrates tools that already exist.
10. A separate `run-novhub.sh sync` subcommand runs the loader and then NovSync's
    `db_sync_to_rds.py`, once per call, so the owner can run it after each simulated weld to see
    it reflected in NovApp. It is not part of `up` — starting a weld and syncing its data is a
    repeatable validation action, not a one-time "bring the stack up" step.
11. The four secrets this stack needs (Postgres superuser, `novdata` role password, robot API
    key, NovApp sign-in password) are read once via hidden prompts, only for the steps that
    still have work left, and are never placed on a command line or written to a file the
    script creates.

## Non-Goals (Explicitly Out of Scope)

- Does not perform the runbook's full "Cleanup" section (removing Docker containers,
  uninstalling the PLCSIM/`plc-node` packages, deleting the NovSync venv or log directories) —
  `down` stops services only and leaves everything installed for the next `up`.
- Does not automate any `sudo`-gated step's action, or either build step (PLCSIM's, `plc-node`'s)
  — check, print the exact command/terminal/expected result, and stop. The owner runs builds
  and anything `sudo`-gated, per this repo's global rules.
- Does not automate starting an actual simulated weld (runbook 8.1) — that stays a manual action
  via PLCSIM's REST API, exactly as the runbook documents it; `sync` only covers the
  loader+NovSync half.
- Does not modify `run-novapi.sh`, `run-luna.sh`, or `build-backend.sh`.
- Does not automate confirming NovApp's UI (sign-in, a weld-run page listing a run) — that stays
  a manual visual check, named as a reminder in `status`'s output.
- Does not support more than one instance of this stack on one machine — one fixed set of ports
  and container names, matching the runbook.

## User Stories

### Must Have (P0)

- As the tool operator, I want one command to bring every automatable component of the stack up,
  in the right order, so I don't re-walk the runbook by hand each time.
- As the tool operator, I want every `sudo`-gated or build step to stop and tell me exactly what
  to run, in which terminal, and what to expect, so I stay in control of anything that touches my
  live system or installs something.
- As the tool operator, I want a `status` command that tells me what's up and what isn't, without
  starting or changing anything.
- As the tool operator, I want `down` to stop everything cleanly without uninstalling anything, so
  I can bring the stack back up quickly next time.
- As the tool operator, I want the four secrets prompted once, only when a step still needs one,
  and never written to disk or logged.
- As the tool operator, I want LUNA's step to tell me exactly what to run and in which terminal,
  and to pick up automatically once I've started it myself, so `up`/`status` cover the control
  path too, not just the weld-data path.

### Should Have (P1)

- As the tool operator, I want a `sync` command that loads the latest weld data into OpenSearch
  and pushes it through NovSync, so I can see a simulated weld reflected in NovApp without
  re-reading the runbook.

### Nice to Have (P2)

(none yet)

## Acceptance Criteria

- GIVEN a clean machine, WHEN `up` runs, THEN OpenSearch, NovData+Postgres, NOVAPI+Postgres
  (with migrations and seed applied), and NovApp are each brought up through check/act/verify,
  in the runbook's order, each printing `created` or `already ...`.
- GIVEN any step whose check finds existing state, WHEN `up` reaches it, THEN it prints
  `already ...` and changes nothing.
- GIVEN a `sudo`-gated or build step (OpenSearch's `vm.max_map_count`; PLCSIM's build, install,
  port config, service start; `plc-node`'s build, install, log directory, service start), WHEN
  `up` reaches it and the check finds the work missing, THEN the script prints the exact
  command, the terminal to run it in, and the expected result, and stops without running it.
- GIVEN NOVAPI's `.env` is missing a key this stack's steps need, or one is still a sample
  placeholder, WHEN `up` reaches the NOVAPI step, THEN it stops, names exactly which key(s), and
  does not start NOVAPI.
- GIVEN NovData, NOVAPI, or NovApp was started by this script, WHEN `down` runs, THEN each is
  stopped via its pidfile and its Docker container (if any) is stopped, not removed — data and
  installs are left intact.
- GIVEN LUNA's backend/frontend are not yet running, WHEN `up` or `status` reaches that step,
  THEN it prints the exact `run-luna.sh backend`/`frontend` commands and which terminal, and
  `up` stops there; rerunning `up` after the owner starts them detects them and continues.
- GIVEN the OpenSearch loader runs against the same `weld_run`/`weld_data` rows twice, WHEN
  `sync` is called a second time, THEN the document count in `novhub-local` does not grow.
- GIVEN any of the four secrets' steps already has its work done, WHEN `up` runs, THEN that
  secret's prompt is skipped entirely.
- GIVEN `up` has finished, WHEN the owner runs `status`, THEN it reports every component's
  current state, including LUNA's check-only state, without taking any action.

## Constraints

- **Deadline:** none.
- **Tech stack:** Bash, matching this repo's existing conventions (`lib/dev-log-lib`, subcommand
  dispatch, the idiom already used in `luna/run-luna.sh`/`telemetry/telemetry.sh`). The
  OpenSearch loader's SQL/HTTP logic may be a small Python or Bash+`psql`+`curl` helper — a TRD
  decision.
- **Dependencies:** `~/dev/NovApi`, `~/dev/NovData`, `~/dev/NovSync`, `~/dev/novhub` (NovApp),
  `~/dev/plc_simulator`, `~/dev/plc-node`, `~/dev/scripts/luna/run-luna.sh` (referenced only
  for its printed instructions, never invoked to start anything), and the robot's own
  `/var/opt/novarc/configure` (read-only, four fields by text parsing — see Goal 6); Docker,
  `git lfs`, `gh` (for `plc-node`'s `GH_TOKEN`), the .NET 6 SDK, `python3`.
- **Other:** per this repo's security rules, no secret is ever read from, written to, or logged
  by this script beyond what each originating tool already does in its own `.env`/config; the
  four prompted secrets live only in the script's own process environment for the run that needs
  them. `/var/opt/novarc/configure` additionally holds cloud credentials unrelated to this
  stack (including a `SWR_DB_KEY` that belongs to a different, installed database, not the dev
  `novdata` role) — this script reads only the four identity fields from it, by line, never
  sources it, and never prints, logs, or copies any of its other entries anywhere, including
  into NovSync's environment (NovSync gets the local NOVAPI URL and `NOVSYNC_DB` only).

## Open Questions

> Must be empty (all answered) before TRD generation begins.

(None — all resolved during `/prd-init`:)

- Location/name: new top-level `novhub-local-stack/run-novhub.sh`.
- Reconciliation with `novapi-dev-tooling`: `run-novapi.sh` unchanged; this script carries its
  own NOVAPI bootstrap steps directly (see Goal 6).
- OpenSearch loader: new code, in scope.
- LUNA: stays entirely manual; check-only (see Goal 8).
- NovData/NOVAPI/NovApp: script-managed background processes with pidfiles (see Goal 5).
- Weld/loader/NovSync: a separate on-demand `sync` subcommand, not part of `up` (see Goal 10).
- `down` scope: stop only, no uninstall (see Goal 4 and Non-Goals).

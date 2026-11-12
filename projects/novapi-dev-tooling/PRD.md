# PRD: novapi-dev-tooling

**Status:** Draft
**Author:** Jaguar Rivero
**Date:** 2026-11-10
**Tickets:** (none)
**Track:** Standard
**Related TRD:** [TRD.md](TRD.md) | Not yet created

---

## Problem Statement

Starting a local NovApi (Node/Express + Postgres) dev environment currently takes several
manual, error-prone steps: bring up 4 separate Postgres containers via `docker-compose` in
`~/dev/NovApi`, run `npm install` if dependencies are stale, start the API with `npm run dev`,
and separately remember to apply migrations against the correct DB via the API's own `/admin`
route. There is no quick way to check whether the stack is already running, no check that all
required `.env` keys are present before any of this is attempted, and no reminder of the
manual `api_key` row a replication DB needs after setup.

If this isn't built: every NovApi dev session requires re-remembering and re-typing the same
multi-step sequence, with failures surfacing late (e.g. partway through, on a missing `.env`
key) instead of up front, and no consistent way to tell if the stack is already up before
trying to use it.

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|---------------|
| Tool operator | The repo owner, running this locally against their own NovApi checkout, same as `luna/run-luna.sh` and `telemetry/telemetry.sh` | One command each to bring the stack up, check it, tear it down, or fully reset it |

## Goals

1. `novapi/run-novapi.sh up` starts all 4 required Postgres containers (`db_cloud`:5432,
   `db_cloud_dev`:5433, `db_swr`:5431, `db_swr171`:5430) via `docker-compose` in `~/dev/NovApi`,
   runs `npm install` only if needed, and starts the API via `npm run dev` — one command instead
   of three manual steps.
2. `novapi/run-novapi.sh status` accurately reports each container's up/down state and whether
   the API responds, without starting, stopping, or modifying anything.
3. `novapi/run-novapi.sh down` stops the API process and all containers without touching the
   Compose volumes or any data in them.
4. `novapi/run-novapi.sh reset` is the only subcommand that destroys data — `down`, then removal
   of the Compose volumes — and must be invoked explicitly and separately; no other subcommand
   implies it.
5. `novapi/run-novapi.sh migrate` prints the exact `/admin`-route endpoint/command to apply
   migrations against the currently configured DB, since that route's exact contract is
   unverified; it does not call the endpoint automatically.
6. Before any subcommand acts, the script verifies all 13 required `.env` keys are present by
   name only, and fails clearly — naming exactly which keys are missing — without ever reading,
   printing, or logging a key's value.
7. After `up` succeeds, the script prints a manual reminder of the `api_key` table row a
   replication DB needs (`robot_id`, `api_key`, `iam_access_key_id`, `iam_secret_access_key`),
   naming where to do it (pgAdmin or the sibling NovData repo's `NovSystemSetup` tool), without
   attempting to perform it.

## Non-Goals (Explicitly Out of Scope)

- Does not install or manage Docker, Docker Compose, Node, or npm — all are pre-existing
  prerequisites this script checks for but never installs.
- Does not generate, modify, or print the contents of `.env` — only checks that the 13 required
  key names are present.
- Does not automate the `/admin` migrate call — prints the endpoint/command only, since the
  route's exact contract hasn't been verified.
- Does not automate the `api_key`/`NovSystemSetup` manual step — printed as a reminder only.
- Does not manage the sibling NovData repo in any way.
- Does not add any automated test framework to this repo — verification is a manual
  run-through, per this repo's Structural Overrides.
- Does not support multiple simultaneous NovApi environments/profiles — one local Compose stack,
  matching the existing `~/dev/NovApi` layout.

## User Stories

### Must Have (P0)

- As the tool operator, I want one command to boot the full NovApi stack (containers + API) so
  I don't have to remember or retype multiple manual steps.
- As the tool operator, I want `down` to stop everything without losing data, so day-to-day
  stop/start doesn't risk wiping my local DB state.
- As the tool operator, I want `reset` to be a separate, explicit, clearly destructive action,
  so I never wipe my local DB volumes by accident.
- As the tool operator, I want `status` to tell me accurately whether the stack is up before I
  try to use it, so I don't waste time debugging a service that was never running.
- As the tool operator, I want the script to check for all required `.env` keys up front and
  tell me exactly which ones are missing, so a misconfigured environment fails fast and clearly
  instead of partway through.

### Should Have (P1)

- As the tool operator, I want `migrate` to show me the exact endpoint/command to run
  migrations, so I don't have to go hunting for the right route every time.
- As the tool operator, I want a printed reminder about the manual `api_key` step after `up`, so
  I don't forget it exists.

### Nice to Have (P2)

- As the tool operator, I want console output that matches the style of `luna/run-luna.sh` and
  `telemetry/telemetry.sh` (shared log helpers, colors), so this tool feels consistent with the
  rest of the repo.

## Acceptance Criteria

- GIVEN a `.env` in `~/dev/NovApi` missing one or more of the 13 required keys, WHEN any
  subcommand runs, THEN the script fails immediately, naming exactly which key(s) are missing,
  without printing any key's value.
- GIVEN all 13 required `.env` keys are present, WHEN `up` runs, THEN all 4 Postgres containers
  (`db_cloud`, `db_cloud_dev`, `db_swr`, `db_swr171`) start via `docker-compose`, `npm install`
  runs only if dependencies are missing/stale, and the API starts via `npm run dev`.
- GIVEN the stack is already running, WHEN `status` runs, THEN it reports each container's
  up/down state and whether the API responds on its configured port, without starting,
  stopping, or modifying anything.
- GIVEN the stack is running, WHEN `down` runs, THEN the API process and all containers stop,
  and the Compose volumes (and their data) are left untouched.
- GIVEN the stack is stopped or running, WHEN `reset` runs, THEN it performs `down` and then
  removes the Compose volumes, and no other subcommand can delete data.
- GIVEN the API is up and connected to a configured DB, WHEN `migrate` runs, THEN the script
  prints the exact endpoint/command to apply migrations via the `/admin` route, without calling
  it automatically.
- GIVEN `up` completes successfully, WHEN the script finishes, THEN it prints a reminder of the
  manual `api_key` table step and where to perform it (pgAdmin or NovData's `NovSystemSetup`),
  without attempting to perform it.
- GIVEN Docker Compose, Node, or npm is missing or an unmet version requirement, WHEN any
  subcommand runs, THEN the script reports the specific missing/unmet prerequisite and stops,
  without attempting to install anything.

## Constraints

- **Deadline:** none.
- **Tech stack:** Bash, matching `luna/run-luna.sh` / `telemetry/telemetry.sh` conventions
  (shared `lib/dev-log-lib` log helpers, subcommand dispatch style). Docker Compose v2, Node,
  and npm are pre-existing prerequisites, not installed by this script.
- **Dependencies:** the sibling `~/dev/NovApi` repo (`docker-compose.yml`, `package.json`, the
  `/admin` route) and, for the manual `api_key` step only, the sibling NovData repo's
  `NovSystemSetup` tool.
- **Other:** per this repo's security rules (`CLAUDE.md`), `.env` is never read, logged, or
  committed — only checked for the presence of the 13 required key names; no secret value ever
  appears in script output.

## Open Questions

> Must be empty (all answered) before TRD generation begins.

(None — all resolved during `/prd-init`:)

- Migrate automation: **prints the endpoint/command only**, does not call it automatically (see
  Acceptance Criteria and Non-Goals).
- Success definition: **manual run-through against the real NovApi repo** — no automated test
  framework in this repo (see Structural Overrides).

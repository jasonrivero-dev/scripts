# PRD: HUB-106 Local Cloud-Data Launcher

**Status:** Approved
**Author:** Jason Rivero
**Date:** 2026-11-20
**Tickets:** HUB-106
**Track:** Standard
**Related TRD:** [TRD.md](TRD.md) | In Review

---

## Problem Statement

The owner needs to validate local NovApi and NovApp changes against the
2,260-run NovAI-1555 dataset in dev OpenSearch and Postgres without deploying
those changes.
The existing automated capture against the deployed dev site currently fails
before the page receives its robot list, so it cannot measure the local branch.
The cause of that browser failure has not been proven. Without a safe local-against-
dev launch path, the branch cannot be exercised against the same cloud data before
deployment.

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|--------------|
| Local developer | The owner running NovApi and NovApp from a local workstation for HUB-106 validation | Run local changes against dev data and capture usable AFTER evidence without deploying |

## Goals

1. Provide a separate launcher mode for running local NovApi and NovApp against the
   existing dev OpenSearch and Postgres data through already-open tunnels.
2. Keep the existing local-stack launch behavior unchanged.
3. Allow the owner to capture AFTER evidence manually with Chrome DevTools or
   automatically with the existing `perf-capture.sh` workflow using a `dev-local`
   target.
4. Make a successful automated Analytics capture show the selected dev robot and
   date range, report `applied: true` with both usable-time metrics, and show the
   expected branch request pattern: no per-run `weld_test_reports` calls and about
   five batch calls for 2,260 runs.

## Non-Goals (Explicitly Out of Scope)

- Run the BEFORE capture or generate a BEFORE/AFTER comparison report. The owner
  performs those tasks separately with the reporting tools.
- Deploy, merge, or modify NovApi or NovApp application code in their repositories.
- Ingest or delete dev data, run migrations, or connect to the test environment.
- Open or close AWS tunnels automatically; required tunnels must already be open.
- Change or replace the existing local-stack launch mode.

## User Stories

### Must Have (P0)

- As the local developer, I want to launch local NovApi and NovApp against the
  existing dev OpenSearch and Postgres data so that I can test the local branch
  without deploying it.
- As the local developer, I want the launcher to stop with a clear error if the
  required dev tunnel, OpenSearch host mapping, or AWS session is unavailable so
  that it does not silently use the local or test environment.
- As the local developer, I want the existing local-stack mode to remain unchanged
  so that local testing still works as before.
- As the local developer, I want to choose manual DevTools capture or the
  `dev-local` automated capture target so that I can save the AFTER HAR and
  Performance evidence for analysis.
- As the local developer, I want dev credentials kept out of command output and
  protected in local runtime configuration so that the launcher does not expose
  secrets.
- As the local developer, I want automated capture to use the date range configured
  for the dev target so that the local AFTER measurement covers the same data range.

### Should Have (P1)

- None identified.

### Nice to Have (P2)

- None identified.

## Acceptance Criteria

- GIVEN the dev AWS session is valid, the dev OpenSearch host mapping exists, and
  both dev tunnels are open, WHEN the owner starts the cloud-data mode, THEN local
  NovApi and NovApp run against the dev data and NovApp uses the local NovApi.
- GIVEN any required dev access precondition is missing, WHEN the owner starts the
  cloud-data mode, THEN it exits nonzero, identifies the missing precondition,
  stops before starting cloud-connected services, and does not fall back to local
  or test data.
- GIVEN the existing local-stack mode is selected, WHEN it is started, THEN its
  behavior is unchanged and no dev credentials are introduced into that mode.
- GIVEN the cloud-data mode is running, WHEN the owner opens Analytics manually in
  Chrome and captures Network and Performance activity, THEN a sanitized HAR and a
  raw Chrome Performance trace can be saved for the selected dev robot and range.
- GIVEN the cloud-data mode is running and the `dev-local` capture configuration
  and secret are valid, WHEN the owner runs an automated Analytics capture, THEN
  the output includes a HAR, Playwright zipped trace, and metrics with
  `applied: true`, non-empty `list_usable_ms` and `detail_usable_ms`, zero per-run
  `weld_test_reports` requests, and about five `weld_test_reports_batch` requests
  for 2,260 runs.
- GIVEN the automated capture is configured, WHEN it selects its Analytics date
  range, THEN its start and end dates match the range configured in
  `perf-targets.dev.env`.
- GIVEN the launcher is run, WHEN it prepares or starts local services, THEN it
  never runs a database migration, ingests or deletes dev data, or opens/closes
  tunnels.

## Constraints

- **Deadline:** None specified.
- **Tech stack:** Existing Bash tooling in `novhub-local-stack`; use current NovApi,
  NovApp, and performance-capture workflows without changing their application code.
- **Dependencies:** Local NovApi and NovApp checkouts; an active `novai-dev` AWS SSO
  session; already-open dev tunnels and the dev OpenSearch host mapping; existing
  dev secret files; and the `perf-capture.sh` Playwright setup for automated capture.
- **Other:** All launcher development stays on the current branch. Dev/local
  runtime configuration must be local and protected; credentials must not be
  printed or committed. Automated local and deployed-dev timings use different
  network paths and must not be presented as a code-only timing comparison.
  Automated Playwright traces are zipped; raw DevTools trace JSON is obtained
  through the owner's manual capture.

## Open Questions

- None. The capture date range follows `perf-targets.dev.env`; the launcher enables
  AFTER capture only and does not own the BEFORE/AFTER comparison.

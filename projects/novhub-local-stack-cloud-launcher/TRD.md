# TRD: HUB-106 Local Cloud-Data Launcher

**Status:** In Review
**Author:** Jason Rivero
**Date:** 2026-11-20
**Related PRD:** [PRD.md](PRD.md)

---

## Architecture Overview

The cloud-data launcher is an independent mode. It does not call the local-stack
startup functions that create containers, seed data, or run migrations.

```text
Owner
  |
  +-- cloud-local.sh start --env dev
        |
        +-- Read-only preflight
        |     AWS SSO identity, dev host mapping, both open tunnels,
        |     cloud-check connectivity, required local checkouts/config
        |
        +-- NovApi process (local port 3000)
        |     DB -> 127.0.0.1:<dev DB forward>
        |     OpenSearch -> dev hostname, SigV4 via novai-dev
        |
        +-- NovApp process (local port 5173)
              API -> http://localhost:3000

Owner -- perf-capture.sh --target dev-local --> local NovApp/NovApi
Owner -- Chrome DevTools ---------------------> local NovApp/NovApi
```

`start`, `status`, and `stop` manage only launcher-owned processes and state
under `novhub-local-stack/.state/cloud-local/`. The owner remains responsible
for AWS login, host mapping, and opening or closing the tunnels.

NovApi's development entry point calls `dotenv.config()`. The launcher writes
the cloud-only NovApi environment to a private runtime directory and starts the
application with that directory as its working directory. This keeps the
checkout's existing `.env` untouched and prevents its local MinIO/static AWS
settings from entering the cloud process. NovApi reads `./db_init.sql` relative
to its working directory, so the runtime directory also contains a symlink to
the checked-out file; this file is read by the app but no migration is run.
Before launch, audit for other CWD-relative runtime files and account for them
without modifying the application checkout. The runtime environment contains no
static AWS access keys; AWS SDK clients use the `novai-dev` profile.

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Entry point | New `novhub-local-stack/cloud-local.sh` with `start`, `status`, and `stop` | Separate command surface; local-stack mode remains unchanged |
| Implementation | New `novhub-local-stack/steps/cloud_local.sh` | Follows the existing wrapper/step organization |
| Process state | Separate PID and log files under `.state/cloud-local/` | Prevents stopping or confusing local-stack NovApi/NovApp processes |
| Cloud configuration | Read existing dev tunnel, host, and secret configuration; create a private cloud-only NovApi runtime `.env` and link required CWD-relative app files into that runtime directory | Avoids duplicating endpoints or changing the app checkout's `.env` |
| AWS identity | `AWS_PROFILE=novai-dev`, `AWS_DEFAULT_REGION=us-west-2`; no static AWS credentials | Matches the NovApi SigV4 client and the approved dev SSO workflow |
| Capture configuration | `perf-targets.dev-local.env`, copied from the dev target and changed only to local app URLs; separate 0600 login secret | Keeps robot and date range aligned with dev without embedding credentials |
| Application code | No changes in NovApi or NovApp repositories | Launcher-only scope from the PRD |

### CLI Contract

```text
./cloud-local.sh start --env dev
./cloud-local.sh status --env dev
./cloud-local.sh stop --env dev
```

Only `dev` is supported. Invalid arguments or another environment fail
nonzero. Status and error output may identify failed checks, but must not show
secret values, environment contents, database URLs containing credentials, or
AWS credentials.

There are no new HTTP endpoints. The launcher invokes the existing local
applications; manual DevTools capture and `perf-capture.sh` remain separate
owner-run commands.

## Data Model

### New / Changed Schemas

None. The launcher does not change database schemas or application APIs.

### Migration Steps

None. In particular, the launcher must not call NovApi's admin migration route.

## Security

- Sensitive values come only from the existing git-ignored dev secret files and
  the owner's AWS SSO profile. The assistant and launcher must never print or
  log their contents.
- Create the generated NovApi runtime `.env` with `umask 077` and mode `0600`.
  Keep it under `.state/cloud-local/`, which is git-ignored, and remove it after
  the managed NovApi process stops. A failed cleanup leaves it protected in the
  ignored state directory; `status` must report that state without displaying
  its contents.
- Start NovApi with a controlled environment that supplies
  `AWS_PROFILE=novai-dev` and `AWS_DEFAULT_REGION=us-west-2` but does not inherit
  static AWS credentials from the shell or the NovApi checkout. Do not put
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_SESSION_TOKEN` in the
  runtime `.env`. This is required because NovApi's OpenSearch and S3 clients
  use the AWS SDK credential chain.
- The configured dev role is broad. The launcher itself performs no S3 or
  application data writes. Its supported test flow is Analytics; do not use
  upload, delete, robot-provisioning, or other mutation controls. The
  handoff-approved sign-in may update the dev user's row.
- The launcher must not run ingestion, deletion, migrations, or tunnel
  open/close commands. It must fail closed if AWS identity, host mapping,
  tunnels, or connectivity checks do not match dev.
- The dev-local capture login secret is separate from target configuration,
  stored at `.state/secrets/perf-test-user-dev-local.secret`, and mode `0600`.
  No secret values belong in this document, examples, command arguments, or
  committed files.

## Implementation Plan

### Step 1: Add cloud-mode preflight and private runtime configuration

- **Files:** `novhub-local-stack/steps/cloud_local.sh`
- **What:** Add read-only validation for the dev AWS identity/session, OpenSearch
  host mapping, both already-open dev forwards, `cloud-check.sh` connectivity,
  required checkouts, and dev secret-file permissions. Build the NovApi runtime
  `.env` from `.state/secrets/novai-dev/DB.secrets` and
  `.state/secrets/novai-dev/OPENSEARCH.secrets` without printing values or
  copying static AWS credentials. Set `DB_HOST=127.0.0.1`, the configured dev
  DB forward port, and `IS_NOVAI=true`; preserve the dev OpenSearch hostname and
  index from its secret configuration. Create the required `db_init.sql`
  symlink in the private runtime directory and audit for other CWD-relative
  runtime files. Require the caller identity to be in account `905418409424`
  with an `AWSReservedSSO_AdministratorAccess_` role. Use the existing shared
  process/config helpers where applicable.
- **Verify:** With stubbed external commands and fake secret fixtures, valid
  configuration creates a mode-0600 runtime file; missing or invalid
  prerequisites return nonzero before any application process starts. Verify
  the symlink targets the current NovApi checkout and captured output contains
  no fixture secret values.

### Step 2: Add isolated cloud NovApi/NovApp lifecycle commands

- **Files:** `novhub-local-stack/cloud-local.sh`,
  `novhub-local-stack/steps/cloud_local.sh`,
  `novhub-local-stack/tests/test_cloud_local.py`
- **What:** Implement `start`, `status`, and `stop` for NovApi on port 3000 and
  NovApp on port 5173. Start NovApi with
  `node "$NOVAPI_REPO/bin/www"` from the private runtime directory and a
  controlled environment with `NODE_ENV=development`, `IS_NOVAI=true`, the approved AWS
  profile, and region. Start NovApp from its checkout with
  `VITE_SERVER_URL=http://localhost:3000` and `VITE_IS_NOVAI=true`. Use distinct
  process state from the local stack. Restart NovApi to pick up source changes.
  On startup failure, stop only processes started by this mode. `stop` removes
  the generated runtime `.env` and symlink after NovApi stops and never closes
  tunnels.
- **Verify:** Stubbed lifecycle tests prove that start refuses unhealthy
  preconditions, starts the two local services only after preflight, and
  stop/status do not affect local-stack processes or invoke tunnel, ingestion,
  deletion, or migration commands.

### Step 3: Document and verify manual and automated AFTER capture

- **Files:** `novhub-local-stack/CLOUD-LOCAL-LAUNCHER.md`,
  `novhub-local-stack/README.md`,
  `novhub-local-stack/tests/test_cloud_local.py`
- **What:** Document the dev-local setup and owner-run sequence. Copy
  `perf-targets.dev.env` to `perf-targets.dev-local.env`, change only
  `NOVAPP_URL` and `NOVAPI_URL` to the local ports, preserve the robot and date
  range, and create the separate 0600 dev-local login secret. Document manual
  Chrome DevTools export and the existing automated
  `perf-capture.sh --target dev-local --page analytics` command. Do not change
  `perf-capture.js` or generate comparison reports as part of this feature.
- **Verify:** The owner checks that the capture's reported `date_range_used`
  matches the current `perf-targets.dev.env` values. The owner performs one
  live smoke capture only after manually confirming the dev preconditions.

## Test Plan

### Unit Tests

| Test | File | PRD Criterion |
|------|------|---------------|
| Valid dev configuration produces a private runtime file without exposing fixture secrets | `novhub-local-stack/tests/test_cloud_local.py` | Credentials remain protected; cloud mode starts against dev |
| NovApi child receives the dev AWS profile but no inherited static AWS credentials | `novhub-local-stack/tests/test_cloud_local.py` | Credentials remain protected; cloud mode uses dev |
| Missing AWS identity, host mapping, tunnel, or connectivity check prevents startup | `novhub-local-stack/tests/test_cloud_local.py` | Missing preconditions fail closed |
| Cloud process state is separate; stop removes only cloud-mode processes and runtime configuration | `novhub-local-stack/tests/test_cloud_local.py` | Local-stack behavior is unchanged |

### Integration Tests

| Scenario | Tool | PRD Criterion |
|----------|------|---------------|
| `bash -n` on the new shell entry point and step file | Bash | Launcher parses correctly |
| Run focused cloud-launcher tests with fake commands/config; no real AWS or dev writes | `python3 -m unittest discover -s novhub-local-stack/tests -p 'test_cloud_local.py'` | Fail-closed behavior, isolation, and secret handling |
| Owner verifies `cloud-check.sh --env dev`, starts the mode, confirms NovApi reports NovAI, and opens local NovApp to confirm NovAI-1555 data appears for the configured range | Manual, owner-run | Local code uses dev Postgres/OpenSearch through existing tunnels |
| Owner runs one `perf-capture.sh --target dev-local --page analytics`; verify `applied: true`, both usable-time metrics, zero per-run `weld_test_reports` requests, and about five batch requests for 2,260 runs | Manual, owner-run | Automated Analytics capture evidence |
| Owner compares the capture's `date_range_used` with the current `perf-targets.dev.env` values | Manual, owner-run | Automated capture uses the dev date range |
| Owner captures Analytics in Chrome DevTools and saves sanitized HAR plus raw Performance trace | Manual, owner-run | Manual AFTER evidence |

No test in this plan opens tunnels, ingests/deletes data, runs migrations, or
targets the test environment. Local-vs-deployed timings use different network
paths and must not be presented as a code-only timing comparison.

## Rollout

1. The owner logs in with `aws sso login --profile novai-dev`, verifies an ARN
   beginning with
   `arn:aws:sts::905418409424:assumed-role/AWSReservedSSO_AdministratorAccess_`,
   and manually confirms the dev host mapping and both open forwards.
2. The owner runs `./cloud-check.sh --env dev`; it must pass before starting
   the launcher.
3. The owner runs `./cloud-local.sh start --env dev`, checks status, and opens
   `http://localhost:5173`.
4. The owner captures manually or runs the documented dev-local automated
   capture. The launcher does not capture or compare reports automatically.
5. The owner runs `./cloud-local.sh stop --env dev`. The tunnels remain open
   until the owner closes them separately.

Rollback is `./cloud-local.sh stop --env dev`; it stops only managed local
processes and removes the private runtime `.env`. No migration rollback or
dev-data restoration is needed because the launcher performs no such
operations. The handoff-approved sign-in update, if any, is not rolled back.

## Clarifications

| # | Step | Question | Answer | Source | Date |
|---|------|----------|--------|--------|------|
| 1 | Step 2 | May the launcher change NovApi or NovApp code to alter bind behavior? | No. Use both applications exactly as they are; all changes stay in this repository. | user | 2026-11-20 |

## Traceability Matrix

| PRD Acceptance Criterion | TRD Step | Test |
|--------------------------|----------|------|
| Local NovApi and NovApp run against existing dev data through the open tunnels | Steps 1-2 | Unit configuration test; owner-run local smoke test |
| Missing dev access prerequisites fail before cloud-connected services start; no fallback | Steps 1-2 | Missing-prerequisite unit test |
| Existing local-stack mode is unchanged | Step 2 | Process-isolation and stop test |
| Manual Chrome DevTools capture can save sanitized HAR and raw trace | Step 3 | Owner-run manual capture |
| Automated capture emits required metrics and request pattern | Step 3 | Owner-run capture metrics/request-count check |
| Automated capture uses the date range from the dev target | Step 3 | Owner compares `date_range_used` with `perf-targets.dev.env` |
| Launcher never runs migrations, ingestion/deletion, or tunnel open/close | Steps 1-2 | Stubbed-command lifecycle test |

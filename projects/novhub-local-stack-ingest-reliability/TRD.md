# TRD: Reliable NovHub Synthetic Ingestion

**Status:** Draft
**Author:** Project owner
**Date:** 2026-11-19
**Related PRD:** [PRD.md](PRD.md)

---

## Architecture Overview

The existing shell entry point remains the operator interface. Python prepares the synthetic template, coordinates the existing ingester process, and verifies state in both stores. The external ingester source remains unchanged.

```text
Operator
  |
  v
cloud-ingest.sh
  |
  v
cloud-ingest.py
  |-- load Hermit V2 template and repo-local range map
  |-- automatically audit OpenSearch (SigV4 through tunnel) + Postgres
  |
  v
existing `go run ./cmd/perfload` in opensearch-ingester (unmodified)
  |-- OpenSearch
  `-- Postgres
  |
  v
automatic post-operation audit and verified result
```

Ingestion and deletion cannot be made atomic across OpenSearch and Postgres. Each operation therefore uses a stable synthetic identity, audits both stores, and reports a non-zero failure if either store is incomplete or inconsistent. A retry of a completed add is a no-op; a retry of a deletion rechecks both stores and removes only remaining records for that synthetic identity.

The supplied Hermit V2 template has 114 typed fields and two `values` rows. Only `arc_time`, `plc_time`, and `timestamp` differ between those rows; the other values, including the likely measurement fields, are repeated. The uploaded `schema_mapping.json` supplies a probable range for each column. Keep a versioned copy in `novhub-local-stack/` so runtime does not depend on a Downloads path. Preserve fields marked static and identifiers, and keep `arc_time`, `plc_time`, and `timestamp` monotonic as specified in the mapping.

> **Resolved by owner:** Randomize mapped feedback/measurement fields, including fields such as `live_*`, `*_temp`, `*_measurement`, and `*_raw`. Keep command/setpoint/recipe, static, identity, metadata, and time-sequencing fields unchanged.

> **Resolved:** Auditing is automatic before and after add/remove operations; there is no separate `--audit` flag.

> **Resolved design:** Before writing, use a read-only SigV4 `GET /<configured-index>/_mapping` request to validate the existing OpenSearch document mapping and run-ID field used by the audit. If mapping access or run-ID resolution fails, stop before writes.

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ingestion integration | Keep `cloud-ingest.sh` and `cloud-ingest.py` as the only code changed for the ingest path; invoke the existing `perfload` command with a temporary transformed template | Meets the scripts-repository constraint without modifying the external ingester |
| Template transformation | Use Python standard-library JSON and temporary-file handling; preserve the original template | Avoids new runtime dependencies and mutation of the user-provided sample |
| Range source | Keep the supplied range map at `novhub-local-stack/schema_mapping.json` and match entries by column name | Removes runtime dependence on a Downloads path |
| Sensor generation | Use the 12 feedback fields listed in Clarifications #1 and uniform sampling from Clarifications #2; preserve IDs, metadata, command/setpoint values, and time-sequencing fields | Varies sensor values without corrupting identity or run structure |
| Batch identity | Reuse the configured robot, synthetic job marker, and run-ID range as the scoped identity; compare run-ID sets across stores | Keeps repeat detection and deletion bounded to this tool’s synthetic records |
| Idempotent add | If the requested batch is already complete, return a verified no-op; if absent, ingest it; if partial or mismatched, fail before invoking `perfload` and direct the operator to audit/cleanup | Prevents overlapping run IDs from creating duplicate OpenSearch documents |
| Idempotent delete | Delete only records associated with the synthetic identity from each store, then audit both stores; a repeated delete of an empty batch is a verified no-op | Supports safe retries without touching real robot data |
| Automatic audit | Audit both stores before and after each add/remove; validate the OpenSearch run-ID field with its read-only mapping endpoint. No separate audit flag | Makes reconciliation part of the requested operation |
| Tunnel behavior | Keep existing tunnel behavior unchanged; tunnel idempotence is not part of this implementation or test plan | The user confirmed this is already implemented |
| Storage/API changes | No database schema, migration, HTTP API, or new service | The feature is confined to local operational scripts and existing stores |
| Test tooling | Python standard-library tests plus existing Bash syntax and manual dry-run conventions | The project has no configured test framework or package manager |

## Data Model

### New / Changed Schemas

None. Use existing OpenSearch documents and `weld_presets_associations` rows. The audit compares logical synthetic run IDs, not raw OpenSearch document totals against Postgres row totals.

### Migration Steps

None. No schema changes or database migrations are planned.

## API Contract

No HTTP API is added or changed. The operator-facing contract remains the local CLI:

| Operation | CLI | Behavior |
|-----------|-----|----------|
| Add a batch | `./cloud-ingest.sh --env dev --runs N --template PATH` | Automatically audit both stores before and after; no-op if the same batch is complete; fail before writes on partial/conflicting state; otherwise invoke the existing ingester |
| Probe | `./cloud-ingest.sh --env dev --probe --template PATH` | Same automatic audit, idempotency, and verification rules for a one-run batch |
| Remove a batch | `./cloud-ingest.sh --env dev --remove --confirm-delete` | Preserve existing typed robot-ID confirmation; automatically audit both stores before and after, delete only this tool’s synthetic records, and verify absence |

Exit status `0` means the requested state is verified, including a verified no-op. A non-zero exit means arguments, preconditions, store access, or cross-store verification failed. Human-readable output must identify the failing store and counts/IDs without printing credentials or full sensor payloads. No override may bypass duplicate protection and knowingly make the same batch non-idempotent.

There is no standalone audit flag. The OpenSearch index mapping is fetched read-only using the existing SigV4 request path before audit queries, so the correct run-ID field is validated automatically. The CLI dry-run remains unchanged; include `--env dev` because environment selection is a required argument.

## Security

- The workflow uses existing AWS SSO/profile credentials and existing dev secret/config files for OpenSearch and Postgres. No credential values are added to source, command-line arguments, or logs.
- No new environment variables are required. Existing wrapper-provided environment variables remain the mechanism for passing AWS profile/region, tunnel details, and child-process connection settings.
- No financial data or real customer data is introduced. The template and stored documents may contain operator, robot, serial, job, and run identifiers; treat them as sensitive operational data and do not log full rows or payloads.
- AWS credentials come from the existing AWS profile/SSO flow; database and OpenSearch settings come from the existing local dev configuration/secret files. Keep credential values in the existing environment/process path and never read or expose `.env` files.
- Keep error output and generated logs scrubbed for AWS tokens, access keys, authorization values, and full ARNs. Temporary transformed templates must be created with owner-only permissions and removed on exit.
- No user-facing API response is introduced, so no API field allowlist is applicable.
- External services are the existing dev OpenSearch and Postgres endpoints reached through the local tunnel. OpenSearch requests use the existing SigV4 flow; Postgres credentials remain in the existing secret-to-process path.

## Implementation Plan

### Step 1: Generate ranged template rows in the scripts repo

- **Files:** `novhub-local-stack/schema_mapping.json`, `novhub-local-stack/cloud-ingest.py`, `novhub-local-stack/tests/test_cloud_ingest.py`
- **What:** Add the supplied mapping as repo-local configuration. Generate `POINTS_PER_RUN` rows, sampling the confirmed feedback fields uniformly within their mapped ranges. Preserve other fields, schema, and types; advance `arc_time` and `plc_time` by the mapped increment and keep `timestamp` sequential (the unchanged ingester overwrites it with sequential timestamps). Pass a private temporary JSON template to the unchanged ingester. Check state and honor dry-run before generating it.
- **Verify:** Fixture tests assert the original file is unchanged, all 12 feedback fields vary within mapped ranges, excluded fields remain unchanged, time fields are sequential, schema/types are preserved, the temporary file is private and cleaned up, and no-op/dry-run paths do not generate it.

### Step 2: Add automatic cross-store audit and idempotent add behavior

- **Files:** `novhub-local-stack/cloud-ingest.py`, `novhub-local-stack/cloud-ingest.sh`, `novhub-local-stack/tests/test_cloud_ingest.py`
- **What:** Automatically audit before and after each add; do not add a separate audit mode. Use the existing SigV4 request path to fetch the configured OpenSearch index mapping and validate the run-ID field before querying. Compare logical synthetic run IDs in OpenSearch and Postgres, using expected document multiplicity rather than comparing raw totals. Return a verified no-op for a complete batch, allow a clean absent batch, and fail without writes for partial/conflicting state. After ingestion, refresh/poll OpenSearch and verify both stores.
- **Verify:** Mocked store tests cover mapping/field resolution, empty and complete states, duplicate/missing/extra runs, document-count mismatch, and store errors. Confirm no ingester subprocess is launched for a complete or partial batch.

### Step 3: Make deletion idempotent and verify both stores

- **Files:** `novhub-local-stack/cloud-ingest.py`, `novhub-local-stack/cloud-ingest.sh`, `novhub-local-stack/tests/test_cloud_ingest.py`
- **What:** Automatically audit before and after deletion. Keep deletion bounded by the tool’s synthetic identity; record pre-delete counts, delete in both stores using their existing scoped identifiers, and return non-zero unless the targeted batch is absent from both stores. A repeated delete of an empty batch is a verified no-op. Do not imply distributed atomicity; make retries safe when one store completed and the other did not.
- **Verify:** Mocked tests cover both stores populated, either store already empty, one-store failure, repeated removal, and unrelated real run IDs remaining untouched.

### Step 4: Run the authorized dev acceptance check

- **Files:** No additional source files
- **What:** Only after explicit operator authorization, run a controlled probe (which automatically audits both stores), select the run in NovHub dev to confirm graphs render, and proceed to the requested batch size only after the probe passes. Confirm removal automatically verifies the synthetic run set is absent from both stores.
- **Verify:** Capture per-store run-ID/count results and manual graph verification. Do not run live ingestion or deletion during implementation without authorization.

## Test Plan

### Unit Tests

| Test | File | PRD Criterion |
|------|------|---------------|
| Template transformation varies eligible feedback/measurement fields within mapped ranges and preserves schema/types | `novhub-local-stack/tests/test_cloud_ingest.py` | Sensor variation and valid structure |
| Missing, static, malformed, or incompatible range-map entries fail safely or remain excluded | `novhub-local-stack/tests/test_cloud_ingest.py` | Sensor variation and valid structure |
| Completed batch is recognized before template generation | `novhub-local-stack/tests/test_cloud_ingest.py` | Idempotent add |
| Automatic audit validates the OpenSearch mapping and detects matching/mismatched/missing/extra IDs | `novhub-local-stack/tests/test_cloud_ingest.py` | Cross-store audit |
| Completed batch is a no-op; partial state fails before launching the ingester | `novhub-local-stack/tests/test_cloud_ingest.py` | Idempotent add and failure reporting |
| Delete retry is a no-op after successful cleanup and never targets unrelated IDs | `novhub-local-stack/tests/test_cloud_ingest.py` | Idempotent deletion |
| Store errors and count mismatches produce non-zero failures | `novhub-local-stack/tests/test_cloud_ingest.py` | Failure reporting |

Run with `novhub-local-stack/.venv/bin/python -m unittest discover -s novhub-local-stack/tests`; the script imports the project's installed `psycopg2` dependency.

### Integration Tests

| Scenario | Tool | PRD Criterion |
|----------|------|---------------|
| Existing dry-run with a scratch template does not invoke the ingester or write either store | `./cloud-ingest.sh --env dev --dry-run` plus fixture tests | Idempotence / no unintended writes |
| Authorized dev probe automatically audits both stores, creates matching run IDs, and displays graphs for the selected run | Operator-driven dev verification | Graph data and cross-store audit |
| Repeated authorized removal leaves no matching synthetic runs in either store | Operator-driven dev verification | Idempotent deletion |

`--env dev` is included because the existing CLI requires an environment argument; this corrects the documented invocation only and does not change dry-run behavior. The project has no existing automated integration environment. Dev verification is manual and requires explicit authorization because it writes or deletes shared data. Tunnel setup behavior is retained unchanged and is not retested by this feature.

## Rollout

- [ ] Keep changes local to `novhub-local-stack`; do not change the external ingester source.
- [ ] Run unit tests, `bash -n` for changed shell scripts, and Python syntax checks.
- [ ] During an explicitly authorized probe, review the automatic pre-write audit before proceeding with the write.
- [ ] Obtain explicit authorization before a dev probe, batch ingest, or delete.
- [ ] Run one controlled probe; verify run IDs and expected counts in both stores.
- [ ] Select the seeded run in NovHub dev and verify the graph data renders.
- [ ] Only after the probe passes, run the requested batch and audit again.
- [ ] Rollback: stop further ingestion; use the scoped idempotent removal operation with typed confirmation; audit both stores until the synthetic run set is absent. Reverting scripts alone does not remove previously written data.

## Clarifications

> Resolved per owner direction: use the supplied range map; randomize feedback/measurement fields only; audit automatically before/after add and removal; discover/validate the OpenSearch run-ID field through its mapping endpoint; leave tunnel behavior unchanged; retain dry-run behavior and include its required environment argument.

| # | Step | Question | Answer | Source | Date |
|---|------|----------|--------|--------|------|
| 1 | Step 1 | Which columns are feedback fields, and how should timestamp behave? | Randomize `autonomy_dist_x_raw`, `autonomy_dist_y_raw`, `camera_temp`, `live_amps`, `live_travel_speed`, `live_trim`, `live_voltage`, `live_weave_amplitude`, `live_weave_frequency`, `live_wfs`, `max_gap_measurement`, and `prescan_gap_measurement`; keep timestamp sequential, not randomized. | user | 2026-11-19 |
| 2 | Step 1 | How should values be sampled from probable ranges? | Uniformly; integers inclusive, floats continuous; generate 50 rows and ensure at least two distinct values per selected field. | user | 2026-11-19 |

## Traceability Matrix

| PRD Acceptance Criterion | TRD Step | Test |
|--------------------------|----------|------|
| Every sensor-measurement field varies while schema and field types remain valid | Step 1 | Range-map/template transformation unit tests |
| Selected dev run has non-empty weld data and rendered graphs | Step 4 | Authorized manual dev verification |
| Audit identifies matching and unmatched synthetic run IDs across stores | Steps 2–3 | Automatic audit set-comparison unit tests |
| Repeated add of a completed batch performs no additional writes | Step 2 | Completed-batch no-op test |
| Repeated removal is a no-op and leaves the batch absent in both stores | Step 3 | Delete retry and empty-state tests |
| Repeated in-scope data operations preserve the desired state | Steps 2–3 | Repeated add/remove tests |
| Mismatch or partial failure is reported as failure, not success | Steps 2–3 | Mismatch and injected-store-error tests |

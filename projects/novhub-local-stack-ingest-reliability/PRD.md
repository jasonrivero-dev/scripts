# PRD: Reliable NovHub Synthetic Ingestion

**Status:** Draft
**Author:** Project owner
**Date:** 2026-11-19
**Tickets:** HUB-106
**Track:** Standard
**Related TRD:** [TRD.md](TRD.md) | Draft — awaiting review

---

## Problem Statement

The dev synthetic-ingest workflow must generate sensor measurements that vary across a run and produce rendered graph data when a seeded run is selected. It must also keep synthetic-run data consistent across OpenSearch and Postgres. Current seeded rows do not provide the needed sensor variation, while the latest cleanup reported zero OpenSearch documents deleted and 2,131 Postgres associations deleted. Without reliable verification and safe reruns, performance testing can use incomplete data or leave the stores inconsistent.

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|--------------|
| NovHub developer | A single developer seeding NovHub dev to test dashboard changes and performance | Reliable synthetic runs with meaningful graphs and safe cleanup |

## Goals

1. Generate synthetic runs where each sensor-measurement field has at least two distinct values across a run, and the selected run provides non-empty graph data in NovHub dev.
2. Make the scripts in the dev synthetic-ingest workflow safe to rerun without creating duplicate synthetic records or leaving stale records in either store.
3. Audit synthetic runs across OpenSearch and Postgres so missing, unmatched, or leftover synthetic runs are identified.

## Non-Goals (Explicitly Out of Scope)

- Modifying source code in the external `opensearch-ingester` repository.
- Changing NovApi, NovApp, or NovHub graph-rendering behavior.
- Seeding or deleting data in production, QA/test environments, or for unrelated robots.
- Comparing OpenSearch raw document totals directly to Postgres association totals; the stores represent each run with different record multiplicities.

## User Stories

### Must Have (P0)

- As a NovHub developer, I want synthetic sensor measurements to vary while retaining the existing data structure so that selected runs can produce useful analytics graphs.
- As a NovHub developer, I want ingestion and deletion to verify the same synthetic run IDs in OpenSearch and Postgres so that I can detect missing or orphaned records before relying on a performance test.
- As a NovHub developer, I want repeating a completed operation for the same synthetic batch to make no additional changes so that retries do not duplicate data or remove unrelated records.
- As a NovHub developer, I want count mismatches and partial failures to be reported as failures so that an inconsistent state is never presented as success.

### Should Have (P1)

None identified.

### Nice to Have (P2)

- None identified.

## Acceptance Criteria

- GIVEN a synthetic ingest using the existing Hermit V2 template, WHEN a run's points are generated, THEN each sensor-measurement field has at least two distinct values across the run and the existing schema and field types remain valid.
- GIVEN a synthetic run is ingested for the configured dev robot, WHEN that run is selected in NovHub analytics, THEN the weld-data response is non-empty and the corresponding graphs render.
- GIVEN `N` synthetic runs are ingested, WHEN the cross-store audit runs, THEN it reports whether the same logical synthetic run IDs are represented in OpenSearch and Postgres and identifies any unmatched runs.
- GIVEN a completed synthetic batch is ingested again as the same operation, WHEN the command runs, THEN it performs no additional writes and reports the existing verified state.
- GIVEN a synthetic batch is removed, WHEN the same removal operation is repeated, THEN it makes no additional changes, removes no unrelated records, and confirms that the batch remains absent from both stores.
- GIVEN any in-scope workflow operation is repeated while its desired state already exists, WHEN the operation runs, THEN it leaves that state unchanged and creates no duplicate state or side effects.
- GIVEN ingestion or removal results in missing or unexpected records in either store, WHEN verification completes, THEN the command reports the per-store mismatch, exits as a failure, and does not report success.

## Constraints

- **Deadline:** NovHub 4.2.0 target release date: 2026-12-30
- **Tech stack:** Changes must remain in this scripts repository, within the dev synthetic-ingest workflow; do not modify `opensearch-ingester`.
- **Dependencies:** Dev OpenSearch and Postgres, accessed through the existing cloud-tunnel workflow; NovHub dev for graph verification.
- **Other:** Do not run live dev ingestion or deletion during implementation without explicit authorization.

## Open Questions

None. Technical field mapping and implementation details belong in the TRD.

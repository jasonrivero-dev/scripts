# TRD: [Feature Name]

**Status:** Draft | In Review | Approved
**Author:** [Name]
**Date:** [YYYY-MM-DD]
**Related PRD:** [PRD.md](PRD.md)

---

## Architecture Overview

> How does this feature fit into the existing system? Use ASCII if helpful.

```
Client → [Component A] → [Component B] → [Data Store]
```

> ⚠️ ASSUMPTION: [Any assumptions made — must be resolved before implementation begins]

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| | | |

## Data Model

### New / Changed Schemas

```sql
-- schema definition
```

### Migration Steps

1. [Step — what runs and in what order]
2. [Rollback: what reverses this]

## API Contract

### `[METHOD] /api/[endpoint]`

**Request:**
```json
{}
```

**Response ([status]):**
```json
{}
```

**Error Codes:**
| Code | Condition |
|------|-----------|
| 400  | |
| 401  | |
| 403  | |
| 404  | |

## Implementation Plan

> Ordered steps. Each step is a commit boundary.

### Step 1: [Name]

- **Files:** `src/...`
- **What:** [description of the change]
- **Verify:** [how to confirm this step is correct before moving on]

### Step 2: [Name]

- **Files:** `src/...`
- **What:** [description]
- **Verify:** [verification]

## Test Plan

### Unit Tests

| Test | File | PRD Criterion |
|------|------|---------------|
| | | |

### Integration Tests

| Scenario | Tool | PRD Criterion |
|----------|------|---------------|
| | | |

## Rollout

- [ ] Run migration
- [ ] Deploy
- [ ] Smoke test
- [ ] Rollback plan: [what to run if this needs to be reverted]

## Traceability Matrix

> Every PRD requirement must appear here. Every TRD step must trace back to a requirement.

| PRD Acceptance Criterion | TRD Step | Test |
|--------------------------|----------|------|
| GIVEN ... WHEN ... THEN  | Step N   | |

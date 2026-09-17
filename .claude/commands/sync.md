Sync CLAUDE.md with the current state of all features in projects/.

Run this after:
- A new feature TRD is approved
- An architectural decision changes
- A feature or API is deprecated
- A major refactor completes

## Steps

### 1. Read the current CLAUDE.md

Load the full file. You will rewrite specific sections — preserve everything else exactly.

### 2. Scan all features

List all subdirectories in `projects/`. For each:
- Read `projects/<feature>/PRD.md` — extract: feature name, status, what it does
- Read `projects/<feature>/TRD.md` — extract:
  - Stack decisions (new libraries, frameworks, patterns introduced)
  - Data model changes (new tables, schema changes, migrations)
  - API additions or changes (new endpoints, changed contracts, removed endpoints)
  - Architectural patterns introduced (new layers, new conventions)
  - Deprecations explicitly called out

### 3. Derive the change delta

Compare what you found against the current `## Project State` section of `CLAUDE.md`.
Identify what is new, what changed, and what should be marked deprecated.

Flag important changes — these are changes that every future agent should know about:
- **Architectural**: new layers, new patterns, new libraries that affect how code is structured
- **Breaking**: removed or changed APIs, renamed conventions, schema migrations
- **Deprecations**: features, endpoints, or patterns that must no longer be used

### 4. Rewrite the `## Project State` section of CLAUDE.md

Replace the entire `## Project State` block with an updated version:

```markdown
## Project State

> Maintained by /sync. Last updated: [YYYY-MM-DD].
> Run /sync after each TRD approval, architectural change, or deprecation.

### Architecture

[1–3 sentence description of the overall system architecture as it currently stands.
Updated when TRDs introduce new patterns or layers.]

Example:
REST API (Express + TypeScript). Layered: Router → Controller → Service → Repository → PostgreSQL.
Auth via JWT middleware on all routes. All DB queries use raw SQL via `pg` — no ORM.

### Active Features

| Feature | Status | Key Additions |
|---------|--------|---------------|
| example-todo-api | Approved | todos table, CRUD endpoints at /todos, ownership auth in service layer |

### Deprecated

| Item | Replaced By | Since |
|------|-------------|-------|
| (none yet) | | |

### Key Architectural Decisions

> Decisions made in TRDs that affect all future features. New features must follow these.

- [Decision from TRD — e.g., "Use raw SQL via `pg`, not an ORM. Introduced in example-todo-api."]
- [Decision — e.g., "Authorization ownership checks happen in the service layer, not the controller."]
```

### 5. Verify nothing else changed

Diff the old and new CLAUDE.md. The only section that should change is `## Project State`.
If you accidentally modified another section, restore it.

### 6. Output a change summary

```
Sync Complete — [YYYY-MM-DD]
─────────────────────────────────────────────────────
Features scanned:   [N]
New since last sync:
  + [feature name] — [one-line summary]
Changed:
  ~ [item] — [what changed]
Deprecated:
  - [item] — [replaced by]
Key decisions added to CLAUDE.md:
  • [decision]
─────────────────────────────────────────────────────
No other sections of CLAUDE.md were modified.
```

## When to Run

| Trigger | Command |
|---------|---------|
| New TRD approved | `/sync` |
| Architectural decision made mid-implementation | `/sync` |
| Feature deprecated or removed | `/sync` |
| Onboarding a new team member | `/prime` (which reads the synced CLAUDE.md) |

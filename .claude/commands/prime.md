Load context for the current work session. Run this at the start of every session.

## Steps

1. Read `CLAUDE.md` — internalize the rules and methodology.

2. List all directories in `projects/` — each is a feature.
   - If multiple exist, ask: "Which project are you working on today?"
   - If only one exists, proceed with it automatically.

3. Read the active feature's documents in order:
   - `projects/<feature>/PRD.md` — understand the product requirements
   - `projects/<feature>/TRD.md` — understand the technical plan

4. Run `git log --oneline -20` and read the last 20 commits to understand recent progress.

5. Determine the current phase:
   - No PRD → ready for `/prd-init`
   - PRD exists, no TRD → ready for `/prd-review` then `/trd-generate`
   - TRD exists but not reviewed → ready for `/trd-review`
   - TRD reviewed, work in progress → ready for `/implement`
   - Implementation done → ready for `/validate`

6. Output a concise session brief — no more than 10 lines:

```
Session Brief
─────────────────────────────────────────
Feature:        <name>
PRD status:     Draft | Reviewed | Approved
TRD status:     Not created | Draft | Reviewed | Approved
Last commit:    <hash> <message>
Current phase:  <Plan | Implement | Validate>
Next action:    /<command> — <one sentence why>
─────────────────────────────────────────
```

7. Check for drift between `projects/` and `CLAUDE.md ## Project State`:
   - Count subdirectories in `projects/`.
   - Count rows in the `### Active Features` table in `CLAUDE.md`.
   - If counts differ, add a warning to the session brief:
     `⚠️  CLAUDE.md is out of sync — run /sync to update Project State.`

Do not start any work until the user confirms the next action.

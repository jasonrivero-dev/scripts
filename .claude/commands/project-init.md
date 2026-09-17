Install this template into an existing project and resolve structural differences.

Run this once when first adopting the template on a project that already has code.

## Steps

### 1. Scan the project

Read the following to understand what already exists:
- Root config files: `package.json`, `pyproject.toml`, `go.mod`, `pom.xml`, `Cargo.toml`
- Directory structure: list top-level dirs and key subdirectories
- Existing test layout: where do tests live? What runner is configured?
- Existing lint/type config: `tsconfig.json`, `.eslintrc`, `mypy.ini`, `.flake8`, `ruff.toml`
- Any existing documentation: `README.md`, `docs/`, `ADR/`
- `README.md` at the project root — this is the primary source for the Application Overview (step 2)
- `CLAUDE.md.template` if present — the install script writes this when a `CLAUDE.md` already
  existed, so this project has real prior context worth preserving (see step 2)

### 2. Generate the Application Overview

This step is what makes CLAUDE.md useful on a project that already has code — without it,
CLAUDE.md only carries generic template rules and says nothing about what the app *is*.

1. Read `README.md`. Extract: what the app does, who it's for, its main components/modules,
   and any domain vocabulary a new contributor would need. If there is no `README.md`, say so
   and instead infer a brief overview from the directory structure and entry points (e.g.
   `main.ts`, `app.py`, top-level routes/controllers) — mark it as inferred, not authoritative.
2. If a pre-existing `CLAUDE.md` was preserved as `CLAUDE.md.template` by the install script,
   read the *original* `CLAUDE.md` (the one still at the project root, not the `.template` copy)
   for any project-specific context it already had — do not discard prior human-written context.
3. Cross-check the README's claims against the actual code (skim key entry points and top-level
   modules) — READMEs go stale. Note anything that looks outdated rather than repeating it as fact.
4. Write the `## Application Overview` section of `CLAUDE.md`:
   - **What this app does** — 2-4 sentences, plain language, what it does and why it exists
   - **Domain / users** — who uses it / what domain concepts matter (e.g. "internal tool for
     support agents", "public API for merchants processing refunds")
   - **Main components** — a short bullet list of the major parts (e.g. "API server", "worker
     queue for email", "admin dashboard") with a one-line purpose each
5. Show the drafted section to the user and ask them to confirm or correct it before writing it —
   never assume the README is complete or current.

### 3. Detect the tech stack

Identify:
- Language and runtime
- Framework (Express, Django, Gin, Rails, etc.)
- Test framework and test file convention
- Lint and type check commands

### 4. Compare to template structure

The template expects:
```
projects/<feature>/PRD.md
projects/<feature>/TRD.md
```

And commands assume these lint/test runners by default:
- Layer 1: `npx tsc --noEmit && npx eslint .` (TypeScript)
- Layer 2: `npx vitest run` or `npm test`
- Layer 3: `npx playwright test`

Report any differences between what exists and what the template assumes.

### 5. Ask the user to decide

Present the differences and ask:

> "I found these structural differences between the template and your project:
> [list each difference]
>
> For each one, would you like to:
> (A) Refactor — align the project to the template's convention
> (B) Override — keep your existing structure and update the template to match"

Wait for the user's decision on each point.

### 6a. If REFACTOR selected for a difference

Guide the change:
- Propose the specific files to move or rename
- Do NOT move files automatically — show the plan and ask for confirmation first
- After user confirms, make the change
- Update any imports or references

### 6b. If OVERRIDE selected for a difference

Document the override:

1. Update `CLAUDE.md` under `## Structural Overrides`:

```markdown
## Structural Overrides

> Decisions where this project intentionally diverges from the template defaults.

| Convention | Template Default | This Project | Reason | Date |
|------------|-----------------|--------------|--------|------|
| Test runner | `npx vitest run` | `python -m pytest` | Python project | 2026-06-02 |
| Test location | `src/**/*.test.ts` | `tests/` | Django convention | 2026-06-02 |
```

2. Update the affected command files in `.claude/commands/` to use the project's actual commands.
   For example, if the test runner is `pytest`, update `validate-unit.md` to lead with `pytest` instead of `vitest`.

3. Update the `## Tech Stack` section of `CLAUDE.md` with the actual stack details.

### 7. Finalize

After all decisions are made:
1. Confirm `## Application Overview` (step 2) and `## Structural Overrides` are both written to
   `CLAUDE.md`.
2. If a `CLAUDE.md.template` file exists in the project root, remind the user to delete it now
   that its relevant sections have been folded in — do not delete it yourself without asking.
3. Run `/sync` to populate the `## Project State` section of `CLAUDE.md`.
4. Output a summary:

```
Project Init Complete
─────────────────────────────────────────────────────
App overview:   [one-line summary of what the app does]
Tech stack:     [detected stack]
Refactored:     [list of changes made]
Overrides:      [list of documented overrides]
Next step:      Run /prd-init to start your first feature
─────────────────────────────────────────────────────
```

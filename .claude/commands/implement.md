Execute implementation from the confirmed TRD.

## Context Reset

This command resets context. Load only what is needed for implementation.
Do NOT carry over planning context — it bloats the window and causes drift.

## Track

Check which spec file `projects/<feature>/` holds. It sets the track:

| File | Track | Source of truth | Pre-flight | Assumption tags | Any UNBACKED |
|------|-------|-----------------|------------|-----------------|--------------|
| `TRD.md` | Standard | TRD | run | `TRD: …`, `Code: …` | stop and ask; record in the TRD |
| `QUICK.md` | Quick | QUICK.md | skip (spec approved in chat) | `Spec: <section>`, `Spec: Clarifications #<n>`, `Code: …` | stop and ask; record in QUICK.md `## Clarifications` |
| `SPIKE.md` | Spike | none | skip | `Code: …` or `UNBACKED` | list only; never stop |

On Quick, read QUICK.md wherever this file says TRD. It is one step and one commit, with QUICK.md
staged together with the code. On Spike, follow `.claude/commands/spike.md`; only the Assumptions
Check (list only) and the commit rules here apply.

## Steps

1. Read `projects/<feature>/TRD.md`, including its `## Clarifications` section. It is your single source of truth.
2. Read `CLAUDE.md` — apply all coding conventions.
3. Do NOT read the PRD unless a TRD section is genuinely ambiguous, and then only for context.
   PRD text never backs an assumption. If the TRD is silent, the assumption is UNBACKED
   (see Assumptions Check) — ask, and record the answer in the TRD.

## Pre-flight: branch and spec approval

Run this before the first TRD step. Standard track only (see Track).

1. Get the current branch: `git branch --show-current` (empty = detached HEAD).
2. If the branch is protected (`main`, `master`, or listed in `protected_branches` in
   `.ai-template/config`), detached, starts with `docs/`, or its diff against the base branch
   touches only `projects/<feature>/`:
   1. If `origin` exists, suggest `git fetch origin <base>`. Do NOT fetch without the user's yes.
      If the user declines, say that the check uses the last-fetched base and may be out of date.
   2. Check whether the docs PR is merged: `git cat-file -e origin/<base>:projects/<feature>/TRD.md`
      (use `<base>` instead of `origin/<base>` when there is no remote).
   3. Merged → offer an implementation branch from the updated base by following
      `.claude/commands/branch.md` with type `feat` or `fix` (whichever the TRD describes).
   4. Not merged → warn "Spec is not yet approved via PR" and ask whether to proceed anyway.
      Stop if the user says no.

## Assumptions Check

Run this at the start of every TRD step, before writing any code for it.

1. **Read.** Read every existing file the step will modify. Do not read further by default (time
   and cost). Read other code only to confirm a specific assumption, then cite it.
2. **List.** ALWAYS print the Assumptions block as its own message BEFORE you call any edit or
   write tool for the step, even when every item is backed. Repeat it in the step's report (the
   message that proposes the commit). Skipping it is a violation. List every assumption the step's
   code will rely on, each with its source:
   ```
   Assumptions — Step 3: Add PATCH /todos/:id
   1. todoService.update returns null when the id does not exist — Code: src/todos/todo.service.ts:48
   2. Ownership is checked before the update — TRD: Architecture Overview
   3. completed is the only updatable field — TRD: API Contract › PATCH /todos/:id
   4. An empty body returns 400 — UNBACKED
   ```
3. **Classify.**

   | Situation | Tag |
   |-----------|-----|
   | Stated in a TRD section | `TRD: <section>` |
   | Answered by a row in `## Clarifications` | `TRD: Clarifications #<n>` |
   | Confirmed by code read in this session | `Code: <file>:<line>` |
   | Based only on names, conventions, typical patterns, or memory of other repos | `UNBACKED` |
   | Behavior the TRD does not specify: a feature, edge case, error handling, or default value | `UNBACKED` |
   | Your interpretation of how a TRD statement or Clarification applies to a case it does not spell out (e.g. whether `"12abc"` counts as "not a valid integer") | `UNBACKED` |
   | Stated only in the PRD | `UNBACKED` |

4. **Decide.**
   - **All backed** → write the code for the step without waiting. The commit approval below still applies.
   - **Any UNBACKED** → STOP before writing code. In one message, ask one question per UNBACKED
     item. Each offers 2–5 options (or asks for a short answer) and marks one **Recommended** with
     a one-line reason. "yes" accepts every Recommended option. Wait until all are answered.
5. **Record.** For each answer, append a row to the TRD's `## Clarifications` table
   (`| <n> | Step <N> | <question> | <answer> | user | <YYYY-MM-DD> |`). If the section is missing,
   add it before `## Traceability Matrix` (or at the end). Re-tag those assumptions
   `TRD: Clarifications #<n>`, then write the code. A later step or session that meets the same
   assumption cites the row and does not ask again. Never record secret values (keys, tokens,
   passwords) in a row.
6. **Conflict.** If code you read conflicts with the TRD, STOP and report it. Do not work around it.

## Implementation Loop

Work through TRD implementation steps in order, ONE step per iteration. For each step:

1. Identify the files to create or modify from the TRD.
2. Run the **Assumptions Check** and print the Assumptions block, always. If anything is UNBACKED,
   stop and ask before going further.
3. Only after the Assumptions block is printed: implement the step — no more, no less than the TRD specifies.
4. Run the layer 1 check immediately (lint + types):
   - TypeScript: `npx tsc --noEmit && npx eslint .`
   - Python: `mypy . && ruff check .`
   - Go: `go vet ./...`
5. Fix any errors before moving to the next step.
   On Quick, check the size before staging: if a changed file is not in QUICK.md `## Files`, or
   `git diff --numstat` plus the line count of each new file exceeds `pr_size_budget`, STOP:
   "This change outgrew the Quick spec. Switch to Standard (`/prd-init`)?" Do not stage.
   This also applies when the spec itself needs a file not in `## Files`: suggest Standard, and do
   not extend the spec.
6. Stage only this step's files, plus the TRD if Clarifications rows were added: `git add <files>`.
   Then show `git diff --staged --stat`.
7. Report the step using exactly this template. Every section is required, including Assumptions:
   ```
   ## Step N: <name> — staged, waiting for approval

   ### Assumptions
   <the Assumptions block from step 2, every item with its tag>

   ### Changes
   <files and what changed>

   ### Checks
   <layer 1 result, or why it was skipped>

   ### Proposed commit
   <the exact git commit command, with the full message including any body lines>
   ```
8. **STOP and wait.** The agent proposes; the human approves. Do not commit until the user approves.
   On approval, run the commit (it asks for approval unless a feature grant covers it).
   Move to the next TRD step only after the commit is made or the user explicitly skips it.

## Rules

- Do NOT implement anything not in the TRD. Behavior the TRD does not specify is UNBACKED — ask.
  If you think of something useful, note it as a comment in the TRD for the next iteration — don't add it now.
- Do NOT refactor surrounding code unless the TRD requires it.
- Do NOT add error handling for scenarios that cannot happen.
- If you encounter unexpected existing code that conflicts with the TRD plan, STOP and
  report it — do not work around it silently.

## Diff Discipline (keep PRs small and reviewable)

- Do NOT reformat lines you did not functionally change (whitespace, quotes, import order, wrapping).
- Do NOT add comments that restate what the code does.
- Do NOT make drive-by refactors, renames, or cleanups.
- Every changed line must trace to the current TRD step. If it doesn't, revert it.

## Security Rules (enforced during every implementation)

- **No hardcoded secrets.** Credentials, API keys, tokens, passwords, and connection strings
  must always come from environment variables. If you are tempted to hardcode a value to make
  something work, STOP — define the env var and reference it instead.
- **No secrets in test fixtures.** Use placeholder values (e.g., `"test-api-key"`) in tests,
  never real credentials.
- **Check .gitignore before the first staging.** Verify `.env` is listed. If it is not, add it
  before staging any files.
- **Never read `.env` directly.** Only access values through the runtime environment
  (`process.env`, `os.environ`, etc.). Never `fs.readFileSync('.env')` or equivalent.
- **No sensitive values in logs or responses.** If a function logs its inputs or a response
  serializes a model, verify that passwords, tokens, and keys are excluded.
- If you encounter a hardcoded secret anywhere — in existing code, comments, or config —
  treat it as a blocker. Report it to the user before continuing.

## Completion

When all TRD steps are complete:
1. Run `/validate-lint` and confirm Layer 1 is green.
2. Run `/validate-unit` and confirm Layer 2 is green.
3. Output: "Implementation complete. Run `/validate` for the full validation pipeline, then `/pr`."

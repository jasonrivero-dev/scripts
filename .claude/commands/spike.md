Run an experiment on the Spike track: a spike branch, no PRD or TRD, and a results note at the end.

Usage: `/spike` (start, or continue / end) · `/spike end` (write the results now).

`/prd-init` follows these steps when the user picks Spike. Calling `/spike` directly counts as the
user's choice of Spike. Spike fits work whose outcome is uncertain, to test an idea before writing
a spec. Spike code never goes to the base branch; a successful spike is promoted and re-implemented
through Standard.

A **spike branch** is one with a `/`- or `-`-separated name segment equal to `spike`.

## Find the spike

Resolve the base branch as in `.claude/commands/branch.md` step 2. The current spike is the
`projects/*/SPIKE.md` that this branch adds: `git diff --name-only <base>...HEAD`.
- None → **Start**.
- Found, called as `/spike end` → **End**.
- Found, called as `/spike` → ask "Continue the spike or end it?" → **Work** or **End**.

## Start

1. Reset feature-scoped git grants, exactly as written:
   ```bash
   rm -f .ai-template/grants.local
   ```
   Run it as its own command, never chained with others: chained, git-guard asks for approval.
   If a grant existed, tell the user it was removed.
2. If no description was given, ask for a one-sentence description of the idea and any ticket IDs.
3. Propose a one-paragraph hypothesis (what we expect, and how we will know) and create the branch
   by following `.claude/commands/branch.md` with type `spike`. If the user declines the branch, stop.
4. Write `projects/<feature-name>/SPIKE.md` (kebab-case) from `templates/SPIKE.md`: Branch, Date,
   Tickets, Hypothesis. Leave the other sections as they are.
5. Continue with **Work**.

## Work

Refuse to work on a branch that is not a spike branch: "Spike work happens on a spike branch. Run
`/spike` from the base branch to start one."

For each change:
1. List its assumptions as in `.claude/commands/implement.md` (tags `Code: …` or `UNBACKED`).
   The list never blocks: do not stop to ask about `UNBACKED` items.
2. Make the change. Stage only its files (and SPIKE.md the first time).
3. Report using exactly this template. Every section is required, including Assumptions:
   ```
   ## Spike change: <name> — staged, waiting for approval

   ### Assumptions
   <every assumption with its tag; UNBACKED items are listed, not asked>

   ### Changes
   <files and what changed, plus `git diff --staged --stat`>

   ### Proposed commit
   <the exact git commit command, with the full message (Commit Convention)>
   ```
4. STOP and wait for approval. Git safety applies unchanged.

## End

1. Fill SPIKE.md: What was tried, Result (numbers where possible), Recommendation (`Promote` or
   `Drop`, with a one-line reason). Ask the user for anything you cannot state from the work.
2. Stage SPIKE.md, propose the commit, STOP and wait for approval.
3. Output:
   - Promote → "Run `/prd-init --from-spike <branch>` from the base branch. The code will be
     re-implemented through Standard, not merged."
   - Drop → "Spike recorded. Keeping or deleting the branch is up to you."

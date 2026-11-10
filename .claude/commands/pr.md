Open a pull request for the current branch, or print a copy-paste PR when `gh` is unavailable.

Works for both PR kinds in the flow: the docs-only PR (PRD + TRD, after `/trd-review`) and the
implementation PR (after `/validate`).

## Steps

0. **Spike check**, before anything else. Resolve the base as in step 1, without fetching. If a
   `/`- or `-`-separated segment of the branch name is `spike`, or `git diff --name-only <ref>...HEAD`
   lists a `projects/*/SPIKE.md`, STOP: "Spike branches are not merged into `<base>`. Promote it:
   `/prd-init --from-spike <branch>`."

1. **Branch check.** Get the current branch (`git branch --show-current`) and the base branch
   (`base_branch` in `.ai-template/config`; if empty, `origin/HEAD`; otherwise `main` / `master`).
   - If the current branch is protected (`main`, `master`, or in `protected_branches`), stop:
     "Create a branch with `/branch` first."
   - If `git remote get-url origin` succeeds, suggest `git fetch origin <base>` so the checks
     below compare against the latest base. Do NOT fetch without the user's yes. If declined, say
     the comparison uses the last-fetched base and may be out of date.
   - Below, `<ref>` is `origin/<base>` when there is a remote, otherwise `<base>`.

2. **Merged-branch cleanup (local only).** List `git branch --merged <ref>` and leave out protected
   branches and the current branch. If any remain, offer to delete them in one command,
   `git branch -d <names>`, which asks for approval. Never delete remote branches.

3. **Secret check.** Run `git diff --name-only <ref>...HEAD`. If it lists `.env` / `.env.*`
   (other than `.env.example`), or a file with hardcoded credentials (same patterns as
   `/validate-review`), STOP and report it. Do not create the PR.

4. **Classify.** If every changed path is under `projects/<feature>/`, this is the docs-only PR.
   Its title is `docs(<feature>): PRD and TRD for review`.
   The track is Quick when the feature folder has `QUICK.md`, otherwise Standard. A Quick PR is
   never docs-only.

5. **Size budget.** Sum additions + deletions from `git diff --numstat <ref>...HEAD`. Ignore binary
   rows (`-`). Compare with `pr_size_budget` in `.ai-template/config` (default 400).
   - Over budget: warn with the count, e.g. "612 changed lines; budget is 400". Propose a concrete
     split: group the changed files by TRD step or by commit into chunks within the budget, and
     list each chunk's files. Then ask whether to continue as one PR. Never block.

6. **Compose** the title and body. Base them on the commits and the file list, never on file contents:
   - **Title:** Commit Convention format, `<type>(<scope>): <description>`.
   - **Body** sections:
     - `## Summary`: what changed and why, synthesized from ALL `git log <ref>..HEAD` messages,
       so a reviewer doesn't have to read the commits one by one.
     - `## Changes`: grouped by area, with key files.
     - `## Track`: Standard or Quick.
     - `## Spec`: links to `projects/<feature>/PRD.md` and `projects/<feature>/TRD.md`.
       Quick: the QUICK.md sections What changes, Why and How to check it (the one file whose
       contents you read), plus a link to it.
     - `## Size`: changed lines vs. budget.
     - `## Validation`: layers run and their results, if known; otherwise "Not run yet".
     - `## Tickets`: from the PRD's (Quick: QUICK.md's) `**Tickets:**` line, or "None".

7. **Create or print.**
   - If `gh --version` succeeds, `gh auth status` succeeds, and the `origin` URL contains `github.com`:
     show both commands, then run them. Each asks for approval.
     ```bash
     git push -u origin <branch>
     gh pr create --base <base> --title "<title>" --body-file <temp file with the body>
     ```
   - Otherwise, print the title and the body in separate fenced blocks, ready to copy and paste,
     followed by the exact `git push` / `gh pr create` commands. Say which prerequisite was
     missing (`gh` not installed, not authenticated, or no GitHub remote).

Output: "PR created: <url>." or "PR text printed above. Push and open the PR when ready."
After a docs-only PR: "After it is merged, run `/implement`."

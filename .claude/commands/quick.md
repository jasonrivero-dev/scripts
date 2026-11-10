Make a small change on the Quick track: a short spec, one approval, one commit. No PRD or TRD.

`/prd-init` follows these steps when the user picks Quick (the spec is then already approved; start
at "After approval"). Calling `/quick` directly counts as the user's choice of Quick.

Quick fits a change to an existing repository, expected to fit within `pr_size_budget`, that adds no
new module, API, or data schema. Anything else is Standard (`/prd-init`).

## Draft (direct call only)

1. Reset feature-scoped git grants, exactly as written:
   ```bash
   rm -f .ai-template/grants.local
   ```
   Run it as its own command, never chained with others: chained, git-guard asks for approval.
   If a grant existed, tell the user it was removed.

2. If no description was given, ask for a one-sentence description and any ticket IDs.

3. Read only the files the description names. Do not search or read further.

4. Draft the spec from `templates/QUICK.md`: What changes, Why, How to check it, Files. List in
   `## Files` only the files the description names; if it names none, write
   "(to be filled in — which files change?)" and ask for them in the approval message.

5. If on a protected branch (`main`, `master`, or in `protected_branches`), compute the branch name
   per `.claude/commands/branch.md` step 4 with type `feat` or `fix`. Skip its fetch suggestion.

6. In ONE message show the drafted spec, the branch name and the exact `git switch -c` command
   (`branch.md` step 5). If the change clearly does not fit Quick, say so here. Close with:
   "Reply **yes** to approve the spec and create the branch, or tell me what to change."
   STOP and wait. This is the only approval before the commit.

## After approval

1. If on a protected branch, run the `git switch -c` command shown (it asks for approval).
2. Write `projects/<feature-name>/QUICK.md` (kebab-case) with `**Status:** Approved` and today's date.
3. Implement per `.claude/commands/implement.md`, Quick track, in this session: one step, one commit,
   QUICK.md staged with the code.

Output after the commit: "Quick change committed. Run `/validate`, then `/pr`."

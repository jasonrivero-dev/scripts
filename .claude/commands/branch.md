Create a feature branch from the up-to-date base branch, named by the repo's branch template.

Usage: `/branch <type> <feature name> [tickets]`. Type is one of `feat | fix | refactor | test | docs | chore | spike`.
`/prd-init` runs these steps with type `docs`; you can also run it on its own.

## Steps

1. Check that this is a git repository: `git rev-parse --is-inside-work-tree`.
   If it is not, output "Git repository not detected; skipped branch creation" and stop.

2. Resolve the base branch: `base_branch` in `.ai-template/config`; if empty, `origin/HEAD`;
   otherwise whichever of `main` / `master` exists.

3. If `git remote get-url origin` succeeds, suggest a fetch so the branch starts from the latest base:
   "`origin/<base>` may be stale. Run `git fetch origin <base>`?"
   - Do NOT fetch without the user's yes. The command asks for approval.
   - If the user declines, continue and say: "Branching from the last-fetched `origin/<base>`; it may be out of date."

4. Compute the name. Do not hand-craft it:
   ```bash
   bash .claude/scripts/branch-name.sh --type <type> --name "<feature name>" [--ticket <id>]...
   ```
   - Run it, and any read of `.ai-template/config`, as its own command, never chained with others:
     chained, git-guard asks for approval.
   - Pass `--ticket` once per ticket. The script uses the ticket only when there is exactly one.
   - Run it with the Bash tool. If only PowerShell is available, run it through git so Git Bash is used:
     `git -c 'alias.bn=!bash .claude/scripts/branch-name.sh' bn --type <type> --name "<feature name>"`

5. Show the name and the exact command, then ask the user to confirm:
   ```bash
   git switch -c <name> --no-track origin/<base>     # with a remote
   git switch -c <name> <base>                       # without a remote
   ```
   `--no-track` keeps the new branch from tracking the base. A tracked base can make a bare
   `git push` target it.
   The user may decline. Then stop without creating a branch.

6. On confirmation, run the command. It asks for approval before it runs.

## Rules

- Never create or switch branches without the user's confirmation in step 5.
- Never commit on `main`, `master`, or any branch in `protected_branches`. git-guard blocks it anyway.

Output: "Created branch `<name>` from `<base>`." or "Skipped branch creation."

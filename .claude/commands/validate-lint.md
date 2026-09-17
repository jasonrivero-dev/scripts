Layer 1: Type checking + linting.

Agent handles — iterates until zero errors.

## Steps

1. Detect the tech stack by reading project config files:
   - No `package.json` / `pyproject.toml` / `go.mod`, mostly `.sh` (+ occasional `.py`) files →
     **Bash/shell scripts (this repo's actual stack — see `## Structural Overrides` in
     `CLAUDE.md`)**
   - `package.json` / `tsconfig.json` → TypeScript/JavaScript
   - `pyproject.toml` / `setup.py` → Python
   - `go.mod` → Go

2. Run the appropriate commands:

   **Bash / shell scripts (this repo):**
   ```bash
   bash -n <changed-file>   # for each changed .sh file - syntax check only
   ```

   No linter is installed or configured (`shellcheck` is not present on this machine) — this
   is a documented override, not a gap to silently work around. `bash -n` only catches syntax
   errors, not style/correctness issues, so also read the diff for obvious problems (unquoted
   expansions, missing `set -e`, etc.) as part of this pass.

   **TypeScript / JavaScript:**
   ```bash
   npx tsc --noEmit
   npx eslint . --ext .ts,.tsx,.js,.jsx
   ```

   **Python:**
   ```bash
   mypy .
   ruff check .
   ```

   **Go:**
   ```bash
   go vet ./...
   staticcheck ./...
   ```

3. For each error or warning:
   - Categorize: auto-fixable (formatting, import order) vs. needs code change
   - Auto-fix what can be auto-fixed:
     - ESLint: `npx eslint . --fix`
     - Ruff: `ruff check . --fix`
   - For the rest, fix the root cause in the code — do not suppress warnings
   - Re-run after each batch of fixes

4. Repeat until zero errors and zero warnings.

5. Output: "Layer 1 ✅ — [N] issues found and fixed, 0 remaining."

## Hard Rules

- Never use `// @ts-ignore` or `# type: ignore` to silence errors.
- Never use `eslint-disable` unless there is a documented reason in the TRD.
- If a type error requires a larger refactor, STOP and report — do not cast to `any`.

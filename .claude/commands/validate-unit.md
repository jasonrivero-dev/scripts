Layer 2: Unit tests.

Agent handles — iterates until all tests pass.

## Steps

1. Detect the test framework:
   - No `package.json` / `pyproject.toml` / `go.mod`, mostly `.sh` files → **this repo: no
     automated unit test framework (documented override — see `## Structural Overrides` in
     `CLAUDE.md`)**
   - Check `package.json` scripts for `jest`, `vitest`, `mocha`
   - Check `pyproject.toml` for `pytest`
   - Check `go.mod` for standard `testing` package

2. Run unit tests:

   **Bash / shell scripts (this repo):**
   No unit test framework (e.g. Bats) is installed. Verify manually instead:

   ```bash
   bash -n <changed-file>                 # syntax check
   ./<changed-file> -h                    # or --help, confirm it still runs/parses args
   ```

   For scripts with non-trivial logic (path math, flag parsing, string manipulation), build a
   throwaway scratch fixture under the session's scratchpad directory and dry-run the actual
   behavior against it — this is how prior changes in this repo (e.g. the `licadmin-ec2-deploy`
   flag parser, `md2html/convert.sh`'s tree-mirroring) were verified. Delete scratch fixtures
   after use; never commit them.

   **TypeScript / JavaScript:**
   ```bash
   npx vitest run          # or
   npx jest --runInBand    # or
   npm test
   ```

   **Python:**
   ```bash
   pytest tests/unit/ -v
   ```

   **Go:**
   ```bash
   go test ./... -v -run Unit
   ```

3. For each failing test:
   - Read the test file to understand what's being tested.
   - Read the implementation file to understand the current behavior.
   - Determine the cause:
     - **Implementation bug** → fix the implementation, not the test.
     - **Test bug** (wrong assertion, wrong setup) → fix the test.
     - **Missing implementation** → implement the missing piece.
   - Re-run the failing test in isolation to confirm the fix.

4. After all individual fixes, re-run the full suite to check for regressions.

5. Repeat until all tests pass with 0 failures.

6. Output: "Layer 2 ✅ — [N] tests passing, 0 failing."

## Hard Rules

- Never delete a failing test to make the suite pass.
- Never skip a test (`it.skip`, `pytest.mark.skip`) without a documented reason.
- If fixing one test breaks another, trace the shared state — do not patch symptoms.

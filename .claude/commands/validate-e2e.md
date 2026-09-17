Layer 3: Integration / E2E tests.

Agent handles — iterates until all scenarios pass.

## Steps

1. Check for an E2E or integration test suite:
   - This repo (Bash/shell scripts, no web app, no `playwright.config.*`/`cypress.config.*`) has
     no E2E suite by design — see `## Structural Overrides` in `CLAUDE.md`. Skip straight to
     "No E2E Suite" below, with the shell-scripts variant described there.
   - `playwright.config.ts` or `playwright.config.js` → Playwright
   - `cypress.config.ts` or `cypress.config.js` → Cypress
   - `tests/integration/` or `tests/e2e/` → custom runner
   - If none exists — see "No E2E Suite" below.

2. Start the application in test mode if needed:
   ```bash
   NODE_ENV=test npm run dev     # or
   DATABASE_URL=$TEST_DB npm start
   ```

3. Run the tests:

   **Playwright:**
   ```bash
   npx playwright test
   ```

   **Cypress:**
   ```bash
   npx cypress run --headless
   ```

   **Custom (supertest / httpx / etc.):**
   ```bash
   npm run test:integration    # or
   pytest tests/integration/ -v
   ```

4. For each failing scenario:
   - Read the test scenario to understand the expected behavior.
   - Trace the failure through the call stack: API layer → service layer → DB layer.
   - Fix the root cause in the implementation.
   - Re-run the failing scenario in isolation to confirm the fix.
   - Re-run the full suite to check for regressions.

5. Repeat until all scenarios pass.

6. Output: "Layer 3 ✅ — [N] scenarios passing, 0 failing."

## No E2E Suite

**This repo (Bash/shell scripts):** there is no integration/E2E framework to install — a
single shell script has no service boundary to exercise the way a web app does. Instead:

1. Read the PRD/TRD acceptance criteria for the scripts touched.
2. Dry-run each changed script end-to-end against a throwaway scratch fixture (a temp dir
   under the session's scratchpad, a fake dependency standing in for a real one, etc. — as
   was done for `licadmin-ec2-deploy`'s flag parser and `md2html/convert.sh`'s recursive tree
   mirroring), covering both the default path and each new flag/branch added.
3. Note explicitly which parts could only be dry-run locally (e.g. anything requiring a real
   remote SSH target, a real GPU, or other hardware/network dependency this environment lacks)
   so the user knows what still needs a real-world check.
4. Output: "Layer 3 (shell scripts) ✅ — manually dry-run, N scenarios covered; [list anything
   that still needs a real-environment check]."

**Other stacks — if no integration or E2E tests exist:**
1. Note the gap: "No E2E test suite found."
2. Generate a minimal integration test covering the PRD acceptance criteria using `supertest`
   (Node.js) or `pytest` + `httpx` (Python).
3. Save to `tests/integration/`.
4. Run and iterate until green.

## Hard Rules

- Never mock the database or network in integration tests — they must hit real infrastructure.
- Use a separate test database (`DATABASE_URL=$TEST_DB`) — never the dev or prod DB.
- Reset test data between runs using setup/teardown hooks.

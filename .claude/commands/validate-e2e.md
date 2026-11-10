Layer 3: Integration / E2E tests.

Agent handles — iterates until all scenarios pass.

## Steps

1. Check for an E2E or integration test suite:
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

If no integration or E2E tests exist:
1. Note the gap: "No E2E test suite found."
2. Generate a minimal integration test covering the PRD acceptance criteria using `supertest`
   (Node.js) or `pytest` + `httpx` (Python).
3. Save to `tests/integration/`.
4. Run and iterate until green.

## Hard Rules

- Never mock the database or network in integration tests — they must hit real infrastructure.
- Use a separate test database (`DATABASE_URL=$TEST_DB`) — never the dev or prod DB.
- Reset test data between runs using setup/teardown hooks.

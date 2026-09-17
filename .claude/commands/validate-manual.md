Layer 5: Manual testing.

You test this. The agent generates the checklist from the PRD.

## Steps

1. Read `projects/<feature>/PRD.md` — extract all acceptance criteria and user stories.

2. Generate a manual test checklist organized by scenario type:

---

**Golden Path** — the main flow a user follows end to end
- [ ] [Scenario based on P0 user story]
- [ ] [Scenario based on P0 user story]

**Alternate Paths** — valid variations of the happy path
- [ ] [Scenario with different but valid inputs]

**Edge Cases** — boundary conditions
- [ ] Empty state (no data exists yet)
- [ ] Maximum input length
- [ ] Special characters in input fields
- [ ] Concurrent requests (open two tabs, submit simultaneously)

**Permission Boundaries** — auth and ownership
- [ ] Unauthenticated user is rejected (401)
- [ ] User cannot access another user's data (403)
- [ ] Read-only user cannot mutate (403 if applicable)

**Error States** — things that go wrong
- [ ] Invalid input is rejected with a clear error message
- [ ] Required fields missing → 400 with specific field errors
- [ ] Resource not found → 404

---

3. For each scenario in the checklist:
   - Test it manually against the running application.
   - Mark ✅ pass or ❌ fail with a note describing what happened.

4. Report failures back. For each ❌:
   - The agent will diagnose and fix the root cause.
   - Re-run `/validate-lint` and `/validate-unit` after any fix.
   - Re-test the failing scenario manually.

5. When all scenarios are ✅:
   Output: "Layer 5 ✅ — All manual scenarios passed. Feature is validated. Ready for PR."

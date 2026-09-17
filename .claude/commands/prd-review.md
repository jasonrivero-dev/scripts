Review the PRD for the current feature before generating a TRD.

## Steps

1. Read `projects/<feature>/PRD.md`.

2. Check each item. Mark ✅ or ❌:

   **Completeness**
   - [ ] Clear problem statement — not "improve UX", but a specific problem with a specific user
   - [ ] Defined user personas or roles
   - [ ] Measurable acceptance criteria — GIVEN/WHEN/THEN format, testable
   - [ ] Explicit out-of-scope section — at least 2 items listed

   **Clarity**
   - [ ] No vague terms without definition (fast, simple, easy, scalable, real-time)
   - [ ] No implementation details — PRD states WHAT, not HOW
   - [ ] No open questions marked TBD (all must be resolved before TRD)

   **Scope**
   - [ ] P0 (must have) items are genuinely necessary for v1
   - [ ] P1/P2 items are truly optional and not hiding required features

3. If any items are ❌:
   - List each issue with a specific suggestion to fix it.
   - Output: "PRD has [N] issues. Fix them before generating the TRD."
   - Do NOT proceed to TRD generation.

4. If all items are ✅:
   - Output: "PRD review passed. Run `/trd-generate` to create the Technical Requirements Document."

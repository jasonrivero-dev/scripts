Review the TRD and confirm the plan before implementation begins.

## Steps

1. Read `projects/<feature>/TRD.md` and `projects/<feature>/PRD.md` side by side.

2. Verify bidirectional traceability:

   **PRD → TRD (coverage)**
   - Every PRD acceptance criterion must map to at least one TRD implementation step.
   - Flag any acceptance criterion with no matching TRD step.

   **TRD → PRD (no gold-plating)**
   - Every TRD implementation step must trace back to a PRD requirement.
   - Flag any TRD step with no PRD source — it should be removed or deferred.

3. Check for unresolved assumptions:
   - Search for `⚠️ ASSUMPTION` blocks in the TRD.
   - Each must be resolved (answered) before implementation.
   - If any remain open, list them and block implementation.

4. Check the test plan:
   - Every PRD acceptance criterion must have at least one test in the test plan.
   - Flag missing test coverage.

5. Output a traceability matrix:

   | PRD Acceptance Criterion | TRD Section | Test Coverage |
   |--------------------------|-------------|---------------|
   | GIVEN ... WHEN ... THEN  | Step N      | test file     |

6. Output a readiness verdict:
   - If issues exist: "TRD has [N] issues. Resolve before implementing." (list each issue)
   - If ready: "TRD review passed. Run `/implement` to begin coding."

Do not start implementation until the user confirms the TRD is ready.

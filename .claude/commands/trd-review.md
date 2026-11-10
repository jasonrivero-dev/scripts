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

3. Run a read-only consistency pass over the PRD and TRD. Report each finding with its severity:

   | Check | Severity |
   |-------|----------|
   | PRD acceptance criterion with no TRD step (from step 2) | High |
   | TRD statement that conflicts with the PRD (scope, behavior, numbers, constraints) | High |
   | TRD step with no PRD source (from step 2) | Medium |
   | Same concept named differently across the documents (terminology drift) | Medium |
   | Term used but never defined in either document | Low |

   - **Read-only:** do NOT edit the PRD or TRD to fix a finding unless the user explicitly approves that fix.
   - Every High finding counts as an issue in the readiness verdict.

4. Check for unresolved assumptions:
   - Search for `⚠️ ASSUMPTION` blocks in the TRD.
   - Each must be resolved (answered) before implementation.
   - If any remain open, list them and block implementation.

5. Check the test plan:
   - Every PRD acceptance criterion must have at least one test in the test plan.
   - Flag missing test coverage.

6. Output a traceability matrix:

   | PRD Acceptance Criterion | TRD Section | Test Coverage |
   |--------------------------|-------------|---------------|
   | GIVEN ... WHEN ... THEN  | Step N      | test file     |

7. Output a readiness verdict:
   - If issues exist: "TRD has [N] issues. Resolve before implementing." (list each issue)
   - If ready: "TRD review passed. Run `/pr` to open the docs-only PR (PRD + TRD). After it is merged, run `/implement`."

Do not start implementation until the user confirms the TRD is ready.

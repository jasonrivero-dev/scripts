Generate a TRD from the reviewed and approved PRD.

## Prerequisite

PRD must be reviewed and approved. If not, run `/prd-review` first.
Do not generate a TRD from an unreviewed PRD — this is a phase gate.

## Steps

1. Read `projects/<feature>/PRD.md` — understand what needs to be built.

2. Read `CLAUDE.md` — apply all tech stack conventions and constraints.

3. Use a sub-agent to scan the codebase for existing patterns relevant to this feature:
   - Existing data models or schemas
   - API conventions (route structure, response format, error codes)
   - Auth patterns (how is identity passed and checked)
   - Test patterns (what framework, where tests live, how they run)
   - Report findings back as context — do not write code in the sub-agent.

4. Security planning — answer these before writing any TRD section:

   - Does this feature handle PII, passwords, tokens, API keys, or financial data?
   - Where do secrets come from? (environment variables only — never hardcoded)
   - Are there new environment variables needed? If so, list them and add them to `.env.example`.
   - Does this feature expose user data in API responses? If yes, define exactly which fields
     are safe to return and explicitly list fields that must never be returned (e.g., `password_hash`).
   - Does this feature call external services? If so, how are credentials for those services stored?

   Add a `## Security` section to the TRD capturing the answers. If none of the above apply,
   write: `## Security — No sensitive data flows identified.`

5. For each PRD acceptance criterion, design the technical implementation that satisfies it.
   Map every requirement. Do not implement anything without a PRD source.

5. Generate the TRD using the structure in `templates/TRD.md`. Include:
   - Architecture diagram (ASCII is fine)
   - Data model changes (schema diffs, migration SQL)
   - Full API contract (method, path, request, response, error codes)
   - Step-by-step implementation plan with file paths
   - Test plan — which unit tests, which integration tests, what each covers
   - Rollout and rollback steps

6. Flag every assumption with:
   > ⚠️ ASSUMPTION: [what you assumed] — [why] — [action needed to confirm]

   Assumptions must be resolved before implementation begins.

7. Save to `projects/<feature>/TRD.md`.

8. Output: "TRD saved. Run `/trd-review` to confirm the plan before implementing."

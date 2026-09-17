Execute implementation from the confirmed TRD.

## Context Reset

This command resets context. Load only what is needed for implementation.
Do NOT carry over planning context — it bloats the window and causes drift.

## Steps

1. Read `projects/<feature>/TRD.md` — this is your single source of truth.
2. Read `CLAUDE.md` — apply all coding conventions.
3. Do NOT read the PRD unless a TRD section is genuinely ambiguous.
   If ambiguous, STOP and ask — do not assume.

## Implementation Loop

Work through TRD implementation steps in order. For each step:

1. Identify the files to create or modify from the TRD.
2. Implement the step — no more, no less than the TRD specifies.
3. Run the layer 1 check immediately (lint + types):
   - TypeScript: `npx tsc --noEmit && npx eslint .`
   - Python: `mypy . && ruff check .`
   - Go: `go vet ./...`
4. Fix any errors before moving to the next step.
5. Commit: `git commit -m "feat(<scope>): <what and why in one line>"`
6. Move to the next TRD step.

## Rules

- Do NOT implement anything not in the TRD. If you think of something useful, note it
  as a comment in the TRD for the next iteration — don't add it now.
- Do NOT refactor surrounding code unless the TRD requires it.
- Do NOT add error handling for scenarios that cannot happen.
- If you encounter unexpected existing code that conflicts with the TRD plan, STOP and
  report it — do not work around it silently.

## Security Rules (enforced during every implementation)

- **No hardcoded secrets.** Credentials, API keys, tokens, passwords, and connection strings
  must always come from environment variables. If you are tempted to hardcode a value to make
  something work, STOP — define the env var and reference it instead.
- **No secrets in test fixtures.** Use placeholder values (e.g., `"test-api-key"`) in tests,
  never real credentials.
- **Check .gitignore before the first commit.** Verify `.env` is listed. If it is not, add it
  before staging any files.
- **Never read `.env` directly.** Only access values through the runtime environment
  (`process.env`, `os.environ`, etc.). Never `fs.readFileSync('.env')` or equivalent.
- **No sensitive values in logs or responses.** If a function logs its inputs or a response
  serializes a model, verify that passwords, tokens, and keys are excluded.
- If you encounter a hardcoded secret anywhere — in existing code, comments, or config —
  treat it as a blocker. Report it to the user before continuing.

## Completion

When all TRD steps are complete:
1. Run `/validate-lint` and confirm Layer 1 is green.
2. Run `/validate-unit` and confirm Layer 2 is green.
3. Output: "Implementation complete. Run `/validate` for the full validation pipeline."

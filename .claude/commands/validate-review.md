Layer 4: Code review with AI assist.

You drive this review. The agent surfaces issues — you decide what to fix.

## Steps

1. Read `projects/<feature>/TRD.md` to understand the intended design.

2. Get the diff:
   ```bash
   git diff main..HEAD          # everything since branching from main
   git diff HEAD~1 HEAD         # just the last commit
   ```

3. For each changed file, review along these dimensions:

   **Correctness**
   - [ ] Does the implementation match the TRD design?
   - [ ] Are there off-by-one errors, null/undefined cases, or race conditions?
   - [ ] Are all error states handled at system boundaries (API input, external calls)?

   **Security — Credentials & Secrets** (scan the full diff, not just new files)
   - [ ] No hardcoded credentials, API keys, tokens, passwords, or connection strings anywhere
         in source code, comments, test fixtures, or config files.
         Scan for patterns: `password =`, `api_key =`, `secret =`, `token =`, `Bearer `,
         `postgres://user:`, `mongodb+srv://`, `sk-`, `AKIA` (AWS key prefix).
   - [ ] `.env` is listed in `.gitignore` — check the `.gitignore` file directly.
   - [ ] No `.env` file is staged or committed — check `git status` and `git diff --cached`.
   - [ ] Environment variables are accessed via runtime env only (`process.env.X`, `os.environ["X"]`),
         never by reading the `.env` file at runtime (`fs.readFile`, `open(".env")`).
   - [ ] Sensitive values (`password`, `token`, `secret`, `key`) are not present in
         log statements, error messages, or exception details.

   **Security — API & Data Exposure**
   - [ ] API responses never include sensitive fields: passwords, hashes, internal tokens,
         full PII beyond what the client needs. Check every serializer and response shape.
   - [ ] No SQL injection — all DB inputs use parameterized queries, never string concatenation.
   - [ ] No XSS — all user-supplied values are escaped before rendering.
   - [ ] No insecure direct object reference — authorization is checked before data access,
         not after fetching the record.

   **Performance**
   - [ ] No N+1 queries (loops that call the DB on each iteration).
   - [ ] No missing DB indexes on foreign keys or frequently-queried columns.
   - [ ] No unbounded result sets (missing pagination or LIMIT).

   **Maintainability**
   - [ ] No magic numbers or hardcoded strings that should be constants or config.
   - [ ] Function names and variable names make the code self-documenting.
   - [ ] No unnecessary comments explaining WHAT — code should be clear enough.

4. Output a review report, grouped by severity:

   **High**
   - `src/todos/todo.service.ts:42` — Authorization check happens after DB read.
     Suggestion: Check ownership before fetching full object.

   **Medium / Low**
   - (list)

5. For each high-severity issue: fix it before proceeding.
   For medium/low: discuss with user — fix or defer.

6. Output: "Layer 4 complete. [N] issues found, [M] fixed, [K] deferred."
   Then: "Run `/validate-manual` to complete the final layer."

# HUB-106 unit test coverage evidence

Scope: only the code changed by HUB-106, measured before and after on branch `jaguar/HUB-4.2.0-release-prep`. Summary sheet: "HUB-106 Unit Test Coverage - Before and After" (Google Sheets, owner's Drive).

## Files

| File | What it is |
|---|---|
| `novapi-before-mergebase-5f9cb8e.json` | NovApi coverage at the merge-base commit with main (jest, the two suites `routes/api/v2/__tests__/users.test.js` and `db/__tests__/queries.unit.test.js`) |
| `novapi-after-branch.json` | The same suites on the branch |
| `novapp-before-mergebase-b163454.json` | NovApp coverage at the merge-base commit (vitest, `src/libs/__tests__` and `src/components/widget/__tests__`) |
| `novapp-after-branch.json` | The same on the branch (WeldInformation.tsx from a separate run of its own test file) |
| `changed-lines-coverage.py` | Computes changed-line coverage from one of the files above |

## Reproduce AFTER (run in each repo on the branch; output goes outside the repo)

NovApi:

```bash
cd ~/dev/NovApi
npx jest routes/api/v2/__tests__/users.test.js db/__tests__/queries.unit.test.js --coverage --coverageReporters=json --coverageDirectory=/tmp/cov-api --collectCoverageFrom='db/queries.js' --collectCoverageFrom='routes/api/v2/users.js'
python3 ~/dev/presentations/novhub-local-stack/hub106-perf-results/coverage-evidence/changed-lines-coverage.py ~/dev/NovApi /tmp/cov-api/coverage-final.json origin/main projects/ templates/ scripts/ .claude/
```

NovApp:

```bash
cd ~/dev/novhub
npx vitest run --coverage.enabled=true --coverage.reporter=json --coverage.reportsDirectory=/tmp/cov-app --coverage.include=src/libs/hooks/useWeldTestReportsBatch.ts --coverage.include=src/libs/hooks/useGroupedWeld.ts --coverage.include=src/components/widget/WeldSessions.tsx --coverage.include=src/components/widget/WeldInformation.tsx --coverage.include=src/libs/utils.ts src/libs/__tests__ src/components/widget/__tests__
python3 ~/dev/presentations/novhub-local-stack/hub106-perf-results/coverage-evidence/changed-lines-coverage.py ~/dev/novhub /tmp/cov-app/coverage-final.json origin/main
```

Expected: `TOTAL: 29/29 = 100%` for NovApi and `TOTAL: 167/167 = 100%` for NovApp.

BEFORE is the same commands run in a `git worktree` at the merge-base commit (`git merge-base origin/main HEAD`), with the repo's `node_modules` linked in.

## Notes

- The NovApi branch is 14 commits behind `origin/main`; BEFORE uses the merge-base so both sides share the same history.
- NovApi's opt-in real-PostgreSQL tests (`scripts/test-db.sh`) are not part of these numbers.

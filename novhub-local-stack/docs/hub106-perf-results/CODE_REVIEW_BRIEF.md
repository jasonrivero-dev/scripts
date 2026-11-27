# HUB-106 code review brief (cross review)

Reviewers: NOVAPI reviews the NovApp diff (`~/dev/novhub`); NOVAPP reviews the NovApi diff (`~/dev/NovApi`).
The changes are committed on branch `jaguar/HUB-4.2.0-release-prep`. NovApi: `git show 90a99dd 0c64cba` (the second adds opt-in real-PostgreSQL tests, `scripts/test-db.sh`). NovApp: `git show 8d829b4`. Read-only: no edits, no commits.

Contract between the two: `POST /api/v2/users/robots/:robot_id/weld_test_reports/batch` returns `{"data": {"<run_id>": {"test_status": string|null, "report_count": number}}}`; unmatched runs `{null, 0}`; the count is non-deleted reports for that run_number (owner decision 2026-11-18: deleted reports are not counted).

## NovApi diff (reviewed by NOVAPP)

Files: `db/queries.js` (`getByRobotIdAndTuples`), `routes/api/v2/users.js` (batch handler, swagger line), `db/__tests__/queries.unit.test.js`, `routes/api/v2/__tests__/users.test.js`.

Check: the SQL (`count(*) OVER (PARTITION BY t.run_number)` with `DISTINCT ON`) returns the right count and the latest status; the response shape matches what NovApp reads; the tests prove behaviour and not only SQL text (the database is mocked); existing consumers of this endpoint still work; index use on the batch query.

## NovApp diff (reviewed by NOVAPI)

Files: `src/libs/hooks/useWeldTestReportsBatch.ts`, `src/components/widget/WeldSessions.tsx`, `src/components/widget/WeldInformation.tsx` and their three test files.

Check: the hook's use of the response (keys, `report_count` default), chunking above 500 runs, behaviour when a batch request fails (QC column), stale or racing results when `runs` changes, unsubscribe on unmount, the memoized run list, the QC status column and count behave as before, no per-run `getWeldTestReports` call remains on the two pages, tests prove it.

## Report format

Per finding: file and line, what is wrong, the failure scenario, severity, and whether it is confirmed from the code or unconfirmed. Say what was read and what was not. No fixes without the owner's approval.

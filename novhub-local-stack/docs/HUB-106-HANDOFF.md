# HUB-106 handoff (state as of 2026-11-20)

Task: show that the HUB-106 change makes the NovHub Analytics page load fast for a large robot (target under 2.0 s). Change: the page fired one `GET weld_test_reports` per weld run (thousands of calls); it now sends `POST weld_test_reports/batch` (500 runs per call). Branch `jaguar/HUB-4.2.0-release-prep` in `~/dev/NovApi` and `~/dev/novhub`, committed and pushed, NOT merged. Do not merge; merging is out of scope.

## The four measurement sets (the source of the confusion)

| Set | Code | Data | Capture method | State |
|---|---|---|---|---|
| L-BEFORE / L-AFTER | `main` / branch, run locally | Local stack, synthetic robot PERF-ING-910001, 203 runs, local containers | Playwright (`perf-capture.sh`, target local) | Done 2026-11-17. Result: per-run calls 203 to 0, requests 462 to 62. Report: `hub106-perf-results/important-reports/before-vs-after-comprehensive-20261117T220824Z/report.html` |
| T-BEFORE | Old code on the deployed test site | Test environment, robot NovAI-1555, 2,258 runs | Manual Chrome DevTools | Done. 3,195 per-run calls, only 733 returned 200. `hub106-perf-results/important-reports/before-test-novai1555-20261118T200951Z/` and `BEFORE_TEST_NOVAI1555.md` |
| D-BEFORE | Old code on the deployed dev site | Dev, robot NovAI-1555, 2,260 runs (2,131 synthetic ingested 2026-11-19, plus 129 real) | Automated capture failing; owner is doing it MANUALLY in Chrome DevTools instead (HAR + raw trace JSON, per `hub106-perf-results/NETWORK_TAB_GUIDE.md`) | Automated trials are invalid (see "Automated capture failure"). Manual BEFORE: owner's task, files go in a new `dev-novai1555-<UTC>/before-manual/` (`analytics.har`, raw trace JSON), trace scanned with `trace-secret-scan.sh` |
| D-AFTER | Branch code run LOCALLY (NovApi + NovApp on the owner's machine) | The same dev Postgres and OpenSearch, reached through SSH tunnels | Playwright, new capture target | NOT DONE. Needs a launcher that does not exist (see below) |

Before this task, only the local-stack numbers (L) existed for the branch. No AFTER has ever been measured on cloud data.

## Automated capture failure (open; evidence below, cause not yet proven)

`perf-capture.sh --target dev --page analytics` never gets data from the dev API. Evidence from `dev-novai1555-20261120T163503Z/before-1` (newest run, after SCRIPT's dialog fix; the "What's New" dialog is now dismissed correctly):
- The page stays on the welding-arc loading animation (`analytics-row-click-failure.png`); the user name shows, so the sign-in worked.
- The HAR holds 85 entries: the site's JS/CSS (all 200) and exactly two API calls, `GET https://api-novai-dev.novarctech.com/api/v2/users/robots` and `GET .../api/v2/branding`. Both failed after about 100 ms with `net::ERR_FAILED` and no HTTP status. No `weld_run`, `weld_test_reports` or `weld_stats` call is ever made, because the app never gets its robot list.
- The browser was `HeadlessChrome/159` (Playwright). The owner's normal Chrome reaches the same API fine. dev-novhub (Netlify) calls api-novai-dev (Elastic Beanstalk behind Cloudflare) cross-origin, so each call needs a CORS preflight.

Likely causes, most probable first (none proven): (1) Cloudflare or the API's CORS/allowlist rejects the headless browser's requests (a blocked or challenged response has no CORS headers, which Chrome reports as `ERR_FAILED`); (2) the capture signs in through a Node-side request and the in-browser calls then carry a missing or wrong token or origin; (3) a network problem specific to the Playwright browser (proxy, TLS).

Next steps, in order, all in `~/dev/scripts/novhub-local-stack/perf-capture.js` (read it first: find how it signs in and how the browser context is created):
1. Log browser console messages and failed requests with their `failure().errorText` and any `console.error` text (the CORS reason is printed there) into the output folder; rerun one trial and read them.
2. Test a normal Chrome user agent string (set once on the context, not per request) and, if that fails, `channel: 'chrome'` or headed mode. These only make the test browser look like the owner's own Chrome; they are not for any other site.
3. If Cloudflare is the cause, do not work around it further: the owner asks the lead to allow the owner's IP or the test user agent for `api-novai-dev` (Cloudflare rule), and the capture then works unchanged.
4. Keep the exit-non-zero check for empty `request_counts` and `applied: false`; it is correct.

Until this works, BEFORE and AFTER are manual Chrome DevTools captures (same method both sides, same range, cache disabled, no throttling; HAR + raw trace JSON via `hub106-perf-results/NETWORK_TAB_GUIDE.md`). Manual and Playwright timings must not be compared in seconds.

## What exists in `~/dev/scripts/novhub-local-stack/`

- `cloud-tunnel.sh open|status|close --env dev`: SSH forwards through the bastion (Postgres on 127.0.0.1:25432, OpenSearch on 127.0.0.1:443; the 443 forward uses sudo).
- `cloud-hosts.sh add|remove --env dev`: /etc/hosts line mapping the dev OpenSearch host to 127.0.0.1.
- `cloud-check.sh --env dev`, `cloud-ingest.sh --env dev [--runs N | --probe | --remove --confirm-delete] --template ~/dev/opensearch-ingester/internal/parser/testdata/hermit_v2_3_sample.json`.
- `perf-capture.sh --target dev --page analytics --out DIR` (config `perf-targets.dev.env`, login secret `.state/secrets/perf-test-user-dev.secret`, mode 0600), `perf-report.sh [--compare]`, `perf-rank-robots.sh --target dev --robot-id 1555`, `trace-secret-scan.sh`.
- Requires `aws sso login --profile novai-dev` (account 905418409424, us-west-2).

## What does not exist yet

A launcher that runs NovApi and NovApp locally against the dev data: NovApi `.env` with DB host 127.0.0.1 and port 25432 (credentials from the git-ignored secrets file, never printed), OpenSearch host `https://<dev es host>` with no port, `AWS_PROFILE=novai-dev` and region on the NovApi process (its OpenSearch client signs with SigV4; the current launchers strip `AWS_*`), and NovApp pointing at that NovApi. Never call NovApi's admin migration route. Then a capture target (for example `dev-local`: `perf-targets.dev-local.env` with `NOVAPP_URL=http://localhost:<port>`, `NOVAPI_URL=http://localhost:<port>`, robot NovAI-1555, the same date range, a login secret file for a dev user). Design: `hub106-perf-results/CLOUD_DATA_PLAN.md`.

## Launcher and capture target: detailed spec (next step 3)

Read first: `~/dev/scripts/novhub-local-stack/steps/novapi.sh` (NovApi on port 3000, writes its `.env` with `ensure_env_kv`, local Postgres on 5433, strips `AWS_*` at line ~132 via its `env` call), `steps/novapp.sh` (NovApp on port 5173), `steps/opensearch.sh`, and `CLOUD_DATA_PLAN.md`. Add a separate cloud mode; do not change the local-stack behaviour.

NovApi settings for cloud mode (variable names from `~/dev/NovApi/.env.sample` and `utils/secrets.js`; `NODE_ENV=development` makes NovApi read them from its `.env`, otherwise it reads AWS Secrets Manager):
- `DB_HOST=127.0.0.1`, `DB_PORT=25432`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD` taken from the git-ignored `.state/secrets/novai-dev/DB.secrets` (do not print them; write the `.env` 0600).
- `OPENSEARCH_HOST=https://<dev es host>` (no port, must match the /etc/hosts line and the 443 forward) and `OPENSEARCH_INDEX` (the dev index: the delete tool uses `weld-data-stream`; confirm in `cloud-ingest.py`).
- `AWS_PROFILE=novai-dev` and `AWS_DEFAULT_REGION=us-west-2` set only on the NovApi process; no access keys in any file. The SSO session must be valid (`aws sso login --profile novai-dev`).
- NovApp: `VITE_SERVER_URL=http://localhost:3000` (from `~/dev/novhub/.env.sample`), `VITE_IS_NOVAI=true`.
- Refuse to start if the tunnel is not open (`cloud-tunnel.sh status --env dev`) or the hosts line is missing. Never call `routes/api/v1/admin.js` (it runs migrations). Local NovApi reads dev data; sign-in may update a user row on dev, which is accepted.

Capture target: `perf-targets.dev-local.env` (git-ignored; same keys as `perf-targets.dev.env`: `NOVAPP_URL=http://localhost:5173`, `NOVAPI_URL=http://localhost:3000`, `PERF_ROBOT_NAME=NovAI-1555`, the agreed range), and `.state/secrets/perf-test-user-dev-local.secret` (0600; the owner's own dev login, since local NovApi checks the dev user table). `perf-capture.sh --target dev-local` skips brand-check and the local log pairing, as for dev.

Acceptance (the owner runs each): `cloud-check.sh --env dev` ok; local NovApp opens in a browser and shows robot NovAI-1555 with its runs for the agreed range; one `perf-capture.sh --target dev-local --page analytics` gives `applied: true`, numbers in both usable fields, and for the branch zero per-run `weld_test_reports` and about 5 `weld_test_reports_batch`; the same capture on `main` (checkout `main` in both repos first) shows thousands of per-run calls.

Uncommitted work to know about: SCRIPT staged changes in `~/dev/scripts` (tunnel and ingest fixes, capture dialog fix). Run `git status` there; the owner commits. SCRIPT, NOVAPI and NOVAPP are Claude sessions you cannot message; read the code directly.

## Rules

- The owner commits and pushes; never run `git commit` or `git push`.
- Never print or commit secrets, tokens or passwords. Never read `.state/secrets/*`.
- The owner runs every command that touches dev (tunnels, ingest, deletes, captures). Local code and file edits are yours.
- Dev data is fair game for the owner; do not write to the test environment.
- Keep the date range identical in every capture of one comparison. `perf-targets.dev.env` currently has 2026-10-01 to 2026-11-30; the test BEFORE used 2024-10-01 to 2026-11-18. Ask the owner which one.
- Timings from the deployed dev site (Cloudflare, HTTP/2) and from a local NovApi (HTTP/1.1 plus a tunnel) are not comparable in seconds; request counts are. A fair timing comparison needs `main` and the branch both run locally through the same tunnels (a local D-BEFORE with `main`), or both on the deployed dev site.
- Be brief with the owner. Say what is verified and what is not.

## Next steps

1. Owner decides the date range and whether to add a local `main` run on dev data as the fair BEFORE for D-AFTER.
2. (Owner) Manual D-BEFORE on the deployed dev site. (Optional) Get the automated capture working (section above); once `jq -c '{date_range_used, list_usable_ms, detail_usable_ms, request_counts}' <out>/analytics-metrics.json` shows `applied: true`, numbers in both usable fields and `weld_test_reports` in the thousands, rerun five trials (new folder, one fixed timestamp).
3. Build the local launcher and `dev-local` capture target; run D-AFTER five times; run the same capture with `main` if chosen.
4. Build the report with `perf-report.sh --compare`, with `--before-capture-analytics` and `--after-capture-analytics` once per trial (see `perf-report.py --help`).
5. The runbook `HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md` assumes AFTER comes from a merge and deploy; it must be rewritten to the plan above.

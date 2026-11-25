# Run local NovApi and NovApp against dev cloud data

This launcher runs the NovApi and NovApp checkouts on this machine while using
the already-seeded dev Postgres and OpenSearch through existing tunnels. It does
not start the local stack or change either application checkout.

The launcher never opens or closes tunnels, ingests or deletes data, runs
migrations, or starts a test-environment connection. NovApi sign-in may update
the dev user row. Use the Analytics flow only; avoid upload, delete, robot
provisioning, or other write controls.

Follow the steps in order, one at a time. If an expected result is missing, stop
and report that step number and the exact output before continuing.

## 1. Prepare dev access

### Step 1 — Sign in to AWS

Run:

```bash
aws sso login --profile novai-dev
```

**Expected:** The browser sign-in completes and the command reports a successful
login. The command exits without an error.

### Step 2 — Verify the AWS identity

Run:

```bash
aws sts get-caller-identity --profile novai-dev --query Arn --output text
```

**Expected:** One ARN is printed. It begins with:

```text
arn:aws:sts::905418409424:assumed-role/AWSReservedSSO_AdministratorAccess_
```

If it does not, stop here.

### Step 3 — Configure the NovApi dev bucket

Edit `cloud-env.env` and set the dev bucket and JWT signing secret:

```text
DEV_S3_BUCKET_NAME=novarc-data-us-west-2-cat-dev
JWT_SECRET=<dev JWT signing secret>
```

**Expected:** The bucket name matches exactly, and `JWT_SECRET` has the
approved dev value. Keep the secret in the ignored local config; do not print
or commit it. The launcher sets `JWT_USER_TOKEN_EXPIRATION=1d` in NovApi's
private runtime config.

### Step 4 — Add the dev OpenSearch host mapping

Run:

```bash
./cloud-hosts.sh add --env dev
```

**Expected:** The dev mapping is added, or the command reports that it is
already added. No error is reported.

### Step 5 — Check the dev tunnel status

Run:

```bash
./cloud-tunnel.sh status --env dev
```

**Expected:** Both `DB` and `OpenSearch` report `open`.

If either reports `closed`, continue to Step 6. Otherwise skip to Step 7.

### Step 6 — Open the dev tunnels, only if either was closed

Run:

```bash
./cloud-tunnel.sh open --env dev
```

**Expected:** The output shows the DB forward target ending in `:5432` and the
OpenSearch forward target ending in `:443`, followed by confirmation that the
tunnels were created. Sudo may prompt once for authentication.

### Step 7 — Verify dev cloud connectivity

Run:

```bash
./cloud-check.sh --env dev
```

**Expected:** The check succeeds, `opensearch_sigv4.ok` is `true`, and there
are no 15-second timeouts. Stop if the check fails.

## 2. Start the local applications

### Step 8 — Start cloud-local mode

From `novhub-local-stack/`, run:

```bash
./cloud-local.sh start --env dev
```

**Expected:** Output includes `NovApi ready` and a `cloud-local ready` message
showing NovApp at `http://localhost:5173` and NovApi at
`http://localhost:3000`.

The launcher checks the AWS identity, dev host mapping, forwards, and cloud
connectivity before starting either application. It writes NovApi's dev-only
runtime configuration under the ignored `.state/cloud-local/` directory; it
does not edit NovApi's `.env`.

### Step 9 — Check the local application status

Run:

```bash
./cloud-local.sh status --env dev
```

**Expected:** NovApi is running on port `3000` and NovApp is running on port
`5173`.

### Step 10 — Open the local dashboard

Open this address in your browser:

```text
http://localhost:5173
```

**Expected:** The local NovApp dashboard loads.

### Step 11 — Open Analytics

In the dashboard, open Analytics.

**Expected:** The Analytics page opens.

### Step 12 — Select the dev robot

In Analytics, select `NovAI-1555`.

**Expected:** Analytics displays data for `NovAI-1555`. Do not use upload,
delete, robot provisioning, or other write controls.

## 3. Capture manually in Chrome DevTools

### Step 13 — Enable Preserve log

In Chrome DevTools Network, enable **Preserve log**.

**Expected:** **Preserve log** is enabled.

### Step 14 — Enable Disable cache

In Chrome DevTools Network, enable **Disable cache**.

**Expected:** **Disable cache** is enabled.

### Step 15 — Leave throttling off

In Chrome DevTools Network, leave throttling off.

**Expected:** Throttling is set to **No throttling**.

### Step 16 — Reload the Analytics page

Reload the page.

**Expected:** The page reload completes and its requests appear in the Network
panel.

### Step 17 — Export a sanitized HAR

Export the Network requests as a sanitized HAR.

**Expected:** A sanitized HAR file is saved.

### Step 18 — Record the Performance trace

In Chrome DevTools Performance, record the page load and save the raw trace JSON.

**Expected:** A raw trace JSON file is saved.

### Step 19 — Scan the trace for secrets

Run:

```bash
./trace-secret-scan.sh <trace.json>
```

Replace `<trace.json>` with the saved trace path.

**Expected:** The scan completes without reporting secrets. Do not share a
trace that fails the scan.

Use the same robot, date range, cache setting, and capture method for both sides
of a manual comparison.

## 4. Capture automatically with Playwright

### Step 20 — Copy the dev target configuration

Run:

```bash
cp perf-targets.dev.env perf-targets.dev-local.env
```

**Expected:** The copy completes without an error.

### Step 21 — Set the local NovApp URL

In `perf-targets.dev-local.env`, set:

```text
NOVAPP_URL=http://localhost:5173
```

**Expected:** `NOVAPP_URL` is `http://localhost:5173`.

### Step 22 — Set the local NovApi URL

In `perf-targets.dev-local.env`, set:

```text
NOVAPI_URL=http://localhost:3000
```

Keep `PERF_ROBOT_NAME`, `PERF_RANGE_START`, and `PERF_RANGE_END` the same as in
`perf-targets.dev.env`. Do not put credentials in either target config.

**Expected:** `NOVAPI_URL` is `http://localhost:3000`; the robot and date range
still match `perf-targets.dev.env`.

### Step 23 — Create the dev-local login secret

Create `.state/secrets/perf-test-user-dev-local.secret` using the existing
`perf-capture` login-secret format for your dev user.

**Expected:** The secret file exists. Do not print or share its contents.

### Step 24 — Protect the login secret

Run:

```bash
chmod 600 .state/secrets/perf-test-user-dev-local.secret
```

**Expected:** The command exits without an error and the file is accessible
only to its owner.

### Step 25 — Run one Analytics capture

Run:

```bash
./perf-capture.sh --target dev-local --page analytics \
  --out ".state/perf-results/dev-local-after-$(date -u +%Y%m%dT%H%M%SZ)"
```

**Expected:** The capture completes and writes its results under a new
`.state/perf-results/dev-local-after-*` directory.

### Step 26 — Check the captured metrics

Run:

```bash
jq '{date_range_used, list_usable_ms, detail_usable_ms, request_counts}' \
  .state/perf-results/<capture-directory>/analytics-metrics.json
```

Replace `<capture-directory>` with the directory created in Step 25.

**Expected:** `date_range_used.applied` is `true`, the dates match
`perf-targets.dev.env`, both usable metrics are present, there are no per-run
`weld_test_reports` requests, and the number of `weld_test_reports_batch`
requests is consistent with the robot's current total run count (about one
batch request per ~500 runs).

Accept the capture only if all of those checks pass.

## 5. Stop the local applications

### Step 27 — Stop cloud-local mode

Run:

```bash
./cloud-local.sh stop --env dev
```

**Expected:** The cloud-local NovApi and NovApp processes stop. The tunnels
remain open; close them separately when you are finished, if desired.

### Restarting instead of stopping for good

Use `restart` in place of a separate stop and start when you need to reset
local NovApi/NovApp state (for example, between a BEFORE and an AFTER capture)
without re-running Steps 1-7. The dev tunnels and host mapping must still be
in place; `restart` runs the same dev-access and port checks as Step 8, and the
same stop checks as Step 27, with no partial state left if either half fails.

Run:

```bash
./cloud-local.sh restart --env dev
```

**Expected:** The same stop confirmation as Step 27, followed by the same
`NovApi ready` and `cloud-local ready` output as Step 8. Both NovApi and NovApp
go down briefly; there is no NovApi-only restart.

## Comparing results

Local NovApi-to-cloud timings and deployed-dev timings use different network
paths. Do not describe their absolute timing difference as a code-only
comparison. Request counts can still show the per-run-to-batch change. A fair
timing comparison requires both code versions to run locally through the same
dev tunnels, or both versions to run on the deployed dev site.

A DevTools trace is raw JSON; the automated Playwright trace is a ZIP and is
not an input to `perf-report.sh --trace`.

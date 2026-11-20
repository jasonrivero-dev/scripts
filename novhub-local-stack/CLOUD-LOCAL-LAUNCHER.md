# Run local NovApi and NovApp against dev cloud data

This launcher runs the NovApi and NovApp checkouts on this machine while using
the already-seeded dev Postgres and OpenSearch through existing tunnels. It does
not start the local stack or change either application checkout.

The launcher never opens or closes tunnels, ingests or deletes data, runs
migrations, or starts a test-environment connection. NovApi sign-in may update
the dev user row. Use the Analytics flow only; avoid upload, delete, robot
provisioning, or other write controls.

## 1. Prepare dev access

Run these commands yourself. The launcher will not log in, change `/etc/hosts`,
or open tunnels.

```bash
aws sso login --profile novai-dev
aws sts get-caller-identity --profile novai-dev --query Arn --output text
```

Confirm the ARN begins with:

```text
arn:aws:sts::905418409424:assumed-role/AWSReservedSSO_AdministratorAccess_
```

Check the OpenSearch host mapping and both forwards:

```bash
./cloud-hosts.sh add --env dev
./cloud-tunnel.sh status --env dev
```

If either forward is closed, open it yourself:

```bash
./cloud-tunnel.sh open --env dev
```

Verify cloud connectivity before launching:

```bash
./cloud-check.sh --env dev
```

## 2. Start the local applications

From `novhub-local-stack/`:

```bash
./cloud-local.sh start --env dev
./cloud-local.sh status --env dev
```

The launcher checks the AWS identity, dev host mapping, forwards, and cloud
connectivity before it starts either application. It writes NovApi's dev-only
runtime configuration under the ignored `.state/cloud-local/` directory; it
does not edit NovApi's `.env`.

Open the local dashboard:

```text
http://localhost:5173
```

Confirm Analytics shows `NovAI-1555` and the expected runs. The local apps read
the same dev data through the existing tunnels.

## 3. Capture manually in Chrome DevTools

1. Open Analytics at `http://localhost:5173`.
2. Select `NovAI-1555` and the agreed date range.
3. In Network, enable **Preserve log** and **Disable cache**, leave throttling
   off, reload the page, then export a sanitized HAR.
4. In Performance, record the page load and save the raw trace JSON.
5. Before sharing a trace, scan it:

   ```bash
   ./trace-secret-scan.sh <trace.json>
   ```

Use the same robot, date range, cache setting, and capture method for both sides
of a manual comparison. A DevTools trace is raw JSON; the automated Playwright
trace below is a ZIP and is not an input to `perf-report.sh --trace`.

## 4. Capture automatically with Playwright

Create the ignored `dev-local` target config from the existing dev target:

```bash
cp perf-targets.dev.env perf-targets.dev-local.env
```

In `perf-targets.dev-local.env`, change only:

```text
NOVAPP_URL=http://localhost:5173
NOVAPI_URL=http://localhost:3000
```

Keep `PERF_ROBOT_NAME`, `PERF_RANGE_START`, and `PERF_RANGE_END` the same as
`perf-targets.dev.env`. Do not put credentials in either target config.

Create `.state/secrets/perf-test-user-dev-local.secret` using the existing
`perf-capture` login-secret format for your dev user, then protect it:

```bash
chmod 600 .state/secrets/perf-test-user-dev-local.secret
```

Run a capture into a new output directory:

```bash
OUT=".state/perf-results/dev-local-after-$(date -u +%Y%m%dT%H%M%SZ)"
./perf-capture.sh --target dev-local --page analytics --out "$OUT"
```

Check the recorded range, usable metrics, and request counts:

```bash
jq '{date_range_used, list_usable_ms, detail_usable_ms, request_counts}' \
  "$OUT/analytics-metrics.json"
```

Accept the capture only when `date_range_used.applied` is `true`, its dates
match the dev target, both usable metrics are present, there are no per-run
`weld_test_reports` requests, and there are about five
`weld_test_reports_batch` requests for 2,260 runs.

## 5. Stop the local applications

```bash
./cloud-local.sh stop --env dev
```

This stops only the processes managed by `cloud-local.sh` and removes its
private NovApi runtime config. The tunnels remain open; close them separately
when you are finished, if desired.

## Comparing results

Local NovApi-to-cloud timings and deployed-dev timings use different network
paths. Do not describe their absolute timing difference as a code-only
comparison. Request counts can still show the per-run-to-batch change. A fair
timing comparison requires both code versions to run locally through the same
dev tunnels, or both versions to run on the deployed dev site.

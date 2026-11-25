# HUB-106 Dev Ingest and Performance Runbook

Follow the numbered steps in order. **Step 1 is the required check before proceeding
to any ingest or delete command.** Run each live command yourself and verify its
expected result before moving on. If a check fails or a count differs, stop there.

Steps 1 to 6 prepare the dev data. The BEFORE/AFTER capture and comparison are in
[HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md](./HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md).

All live dev writes and deletions are operator-run. This runbook does not authorize
the assistant or another script to run them.

Run the commands from one terminal session, starting in this directory:

```bash
cd ~/dev/scripts/novhub-local-stack
```

## Why this is safe

- **Probe first.** Step 2 always ingests exactly one run before a full batch, so a
  mistake costs one run, not the whole batch.
- **Audited, not assumed.** Every ingest and removal reads OpenSearch's mapping and
  the actual synthetic run IDs in OpenSearch and Postgres before writing, and again
  after. A complete requested batch is a verified no-op; partial or conflicting state
  stops before writing anything. No flag bypasses this.
- **Scoped, never robot-wide.** Removal matches on this tool's own synthetic job ID
  in OpenSearch and a run-ID floor in Postgres - never on robot ID alone, since the
  robot also carries real data.
- **No incremental top-up.** Raising how much data you want always means removing
  the existing batch and ingesting the new, larger amount from scratch - see
  "Adjusting how much you add" below.
- **Port pinned, not guessed.** `cloud-tunnel.sh`'s OpenSearch forward is pinned to
  443 on the env's own loopback address specifically so the signed Host header
  matches what AWS recomputes server-side - a tunnel on a high port causes a 403
  "signature we calculated does not match" instead.
- **Nothing secret ever printed.** Host/index/DB values reach the ingester only
  through its own subprocess environment, never the command line. Its combined
  output is scrubbed (an ARN, an x-amz-security-token, or an Authorization header
  can appear in a raw error body) and logged to a 0600 file under
  `.state/cloud-ingest-logs/` - read that file for the first real error, not the
  terminal scrollback.
- **Missing Postgres precondition stops, doesn't guess.** If no
  `weld_monitoring_presets` row matches the robot yet, the Postgres association step
  can't run. The tool stops and prints the exact `INSERT` SQL as text - it never
  runs it; you decide whether to run it yourself.

## 1. Verify dev access and starting state — do this before proceeding

Complete every check in this section before the real probe in Step 2.

### 1.1 Sign in to AWS

```bash
aws sso login --profile novai-dev
```

Finish the browser sign-in if prompted.

### 1.2 Confirm the AWS identity

```bash
aws sts get-caller-identity --profile novai-dev --query Arn --output text
```

The ARN must start with:

```text
arn:aws:sts::905418409424:assumed-role/AWSReservedSSO_AdministratorAccess_
```

If it does not, stop. Do not open the tunnel or run an ingest command with the
wrong identity.

### 1.3 Ensure the dev OpenSearch host mapping exists

The ingest script requires the dev `/etc/hosts` mapping. This command is safe to
repeat; it reports `already added` when the mapping is present. It may ask for your
sudo password if it needs to add the line.

```bash
./cloud-hosts.sh add --env dev
```

Continue only if it reports `already added` or `created`.

### 1.4 Check the tunnel; open it only if a forward is closed

```bash
./cloud-tunnel.sh status --env dev
```

If both DB and OpenSearch report `open`, leave them open and continue. `open` is
idempotent, so there is no need to close and reopen a working tunnel.

If either forward reports `closed`, run:

```bash
./cloud-tunnel.sh open --env dev
```

When it starts the forwards, expect output showing a DB forward target ending in
`:5432`, an OpenSearch forward target ending in `:443`, and `created: tunnel open`.
Starting the OpenSearch forward may ask for your sudo password once. If both forwards
were already open, the command reports `already open` instead.

Check the result again:

```bash
./cloud-tunnel.sh status --env dev
```

Both forwards must report `open`. If opening fails because a port is already held or
a stale tunnel process remains, stop and share the reported process line; do not kill
an unverified process.

### 1.5 Run the dev connectivity and authorization check

```bash
./cloud-check.sh --env dev
```

Proceed only when the output includes `opensearch_sigv4.ok: true` and there are no
15-second request timeouts. Stop if either condition is not met.

### 1.6 Confirm the starting robot total

```bash
./perf-rank-robots.sh --target dev --robot-id 1555
```

This rank command needs the dev performance target configuration and its
mode-`0600` test-user secret. Record the number it prints as **R** - the robot's real,
non-synthetic total right now. It is whatever the robot's actual data is, not a fixed
number, so every expected result below is written relative to R. If the command fails,
stop and reconcile before ingesting.

### 1.7 Audit synthetic data without writing anything

This dry run is part of Step 1: it checks the existing synthetic state before the
real probe. It does not invoke the ingester or write data.

```bash
./cloud-ingest.sh --env dev --probe --dry-run
```

Continue only if it exits successfully, shows a plan for one probe run, and ends
with:

```text
(--dry-run: nothing written, perfload not invoked)
```

The automatic audit must not report partial or conflicting synthetic data. If it
reports an existing complete batch, leftover data, an audit failure, or anything
unexpected, stop and reconcile before Step 2. This audit is repeated automatically
by the real probe immediately before its write.

### Dependency behavior to know before running the wrappers

The cloud-check, rank, and ingest wrappers create `.venv` if needed and run
`pip install -q -r requirements.txt`. That may install missing packages without
prompting. If you want package installation to remain strictly manual, stop before
running these wrappers and have the wrapper behavior changed first.

## 2. Run the real one-run probe

Only proceed if every check in Step 1 passed.

```bash
./cloud-ingest.sh --env dev --probe \
  --template ~/dev/opensearch-ingester/internal/parser/testdata/hermit_v2_3_sample.json
```

Starting from R, verify:

- `[RESULT] Verification passed.`
- OpenSearch delta: **51 documents** for one run.
- OpenSearch synthetic audit: **1 run / 51 documents**.
- Postgres synthetic audit: **1 run / 1 association row**.
- Rank total: **R + 1**.

If the command fails or any result differs, stop. Do not start the 50-run batch.
Continue to Step 3 to remove the probe data before proceeding; the removal audits
both stores and reports whether anything remains.

## 3. Remove the probe data

```bash
./cloud-ingest.sh --env dev --remove --confirm-delete
```

When prompted, type `1555`. For a successful probe cleanup, expect **51 OpenSearch
documents** and **1 Postgres association row** to be removed, followed by a
post-delete audit confirming both stores are clear.

Check the rank:

```bash
./perf-rank-robots.sh --target dev --robot-id 1555
```

It should be back to **R**. Do not continue unless the removal reports that both stores
are clear and the rank is back to R.

Removal is scoped to the synthetic job ID in OpenSearch and this robot's synthetic
run-ID range in Postgres. It attempts both stores and verifies absence afterward.
The stores are not transactionally atomic; if the audit does not verify absence,
stop and review the reported store, run IDs, and counts before retrying.

## 4. Ingest 50 runs

```bash
./cloud-ingest.sh --env dev --runs 50 \
  --template ~/dev/opensearch-ingester/internal/parser/testdata/hermit_v2_3_sample.json
```

Starting from R, expect **50 runs**, **2,550 OpenSearch documents** (50 x 51),
**50 Postgres association rows**, rank **R + 50**, and
`[RESULT] Verification passed.` Stop if any count differs.

## 5. Remove the 50-run batch

```bash
./cloud-ingest.sh --env dev --remove --confirm-delete
```

When prompted, type `1555`. Expect **2,550 OpenSearch documents** and **50 Postgres
rows** to be deleted, followed by an audit confirming both stores are clear. These
are separate store counts; they are not 2,600 OpenSearch documents.

Check the rank:

```bash
./perf-rank-robots.sh --target dev --robot-id 1555
```

It should be back to **R**. Do not continue unless the removal audit passes and the rank
is back to R.

## 6. Ingest the rest - pick an amount

Pick how many more runs you want and pass it explicitly - `--runs <N>` always means
exactly `<N>`, never capped or adjusted:

```bash
./cloud-ingest.sh --env dev --runs <N> \
  --template ~/dev/opensearch-ingester/internal/parser/testdata/hermit_v2_3_sample.json
```

Starting from R, verify:

- OpenSearch document delta: **`<N>` x 51**.
- Postgres association rows: **`<N>`**.
- Rank total: **R + `<N>`**.
- `[RESULT] Verification passed.`

Omitting both `--runs` and `--probe` ingests however many runs are needed to reach
`DEFAULT_TARGET_TOTAL` in `cloud-ingest.py` instead - a convenience default for when you
don't have a specific `<N>` in mind, not a requirement. Check the current value in the
file if you want to rely on it; this runbook doesn't track it since it changes.

Do not start the capture runbook unless all four checks pass. Run IDs restart
at the same base for every invocation, so remove a completed probe or smaller batch
before ingesting a different size.

## Adjusting how much you add

### Changing the size of an existing batch - bigger or smaller

**There is no incremental top-up or trim, ever.** `--runs N` always means "the whole
batch should be exactly N runs," never "N more" and never "N fewer." If you already have
10,000 synthetic runs and want 20,000 total:

- **Wrong:** `--runs 10000` again on top of the existing 10,000 (this is NOT "add 10,000
  more" - it fails the audit, because it expects a batch of exactly 10,000 runs from the
  same base, and 10,000 already-existing + a request for only 10,000 don't match).
- **Right:**

  ```bash
  ./cloud-ingest.sh --env dev --remove --confirm-delete
  ```

  Type the robot id when prompted. **Expected:** both stores verified clear, rank back to
  **R** (`./perf-rank-robots.sh --target dev --robot-id 1555`). Then:

  ```bash
  ./cloud-ingest.sh --env dev --runs 20000 --template <path>
  ```

  the FULL new total (not 10,000), from scratch.

This applies in **both** directions - going smaller fails the exact same way. If 10,000
already exist and you ask for `--runs 8000`, the 2,000 extra existing runs beyond your
request show up as "unexpected" instead of being quietly dropped - remove first, same as
above, then `--runs 8000`.

Rerunning `--runs` (any size) or the default on top of an existing batch fails the
pre-ingest audit ("partial or conflicting synthetic data") instead of writing or deleting
anything, because it expects the whole requested batch to exist from the same base, not
the old batch plus or minus a difference. (To remove only *part* of a batch without
touching the rest - e.g. trim 10,000 down to 8,000 by deleting just the newest 2,000 -
use `--remove --count N` instead - see "Remove only part of a batch" below.)

### Remove only part of a batch

```bash
./cloud-ingest.sh --env dev --remove --count <N> --confirm-delete
```

Type the robot id when prompted. **Expected:** `[RESULT] Removal verified: the <N>
requested run(s) are gone; the rest of the batch is intact.` Confirm the new rank total is
the old rank total minus `<N>`. A `--count <N>` larger than the synthetic runs currently
present is refused before anything is deleted - rerun with a smaller `<N>` instead of
retrying blindly. Omit `--count` to remove the entire synthetic batch, as in Step 3/5.

### Target a different robot

Add `--robot-id <ID>` to any ingest or remove command above instead of the configured
default (`1555`). It is checked against NovApi's own robot list before anything else runs
and refuses if the id doesn't exist there. All of Steps 2-6's counts, audits, and removal
scoping work identically per robot id - they were never specific to `1555`.

## 7. Capture and compare

Done in [HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md](./HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md), which owns the BEFORE and AFTER captures, the merge gate and the combined report. Start there once the four checks in Step 6 pass.

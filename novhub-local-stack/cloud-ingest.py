#!/usr/bin/env python3
"""HUB-106: dev-only ingest wrapper around opensearch-ingester's perfload tool, through
cloud-tunnel.sh. Computes how many runs to add (reading the robot's REAL current total first,
never hardcoded), prints the full plan before running anything, and never puts a secret on
perfload's command line - credentials reach it only via that one subprocess's own
environment. --remove is dry by default and needs a typed confirmation.

ES_HOST/the signing URL never carry a port - cloud-tunnel.sh pins the OpenSearch forward to
port 443 on this env's own loopback address specifically so this matches what the Go SDK (and
a local NovApi) sign by default; a tunnel on a high port made every request's signed Host
header disagree with what AWS recomputes server-side (the real cause of a 403 "signature we
calculated does not match" on a real dev run).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

import psycopg2

from cloud_common import normalize_host, read_kv, require, sigv4_request, get_caller_identity, scrub_sensitive

ENV = os.environ.get("CLOUD_INGEST_ENV")
SECRETS_DIR = os.environ.get("CLOUD_INGEST_SECRETS_DIR")
DB_LOCAL_PORT = os.environ.get("CLOUD_INGEST_DB_LOCAL_PORT")
ES_LOOPBACK = os.environ.get("CLOUD_INGEST_ES_LOOPBACK")
AWS_REGION = os.environ.get("CLOUD_INGEST_AWS_REGION")
AWS_PROFILE = os.environ.get("CLOUD_INGEST_AWS_PROFILE")
ROBOT_ID = os.environ.get("CLOUD_INGEST_ROBOT_ID")
INGESTER_REPO = os.environ.get("CLOUD_INGEST_INGESTER_REPO")
PERF_RANK_SCRIPT = os.environ.get("CLOUD_INGEST_RANK_SCRIPT")
LOG_DIR = os.environ.get("CLOUD_INGEST_LOG_DIR")

TARGET_TOTAL = 2260          # "about 2,260" per the owner - test's NovAI-1555 has 2,259
POINTS_PER_RUN = 50          # modest, per the owner
RUN_ID_BASE = 90000000       # far above any real run_id - also the --remove floor (run_id >=
                              # this). perfload's run-id formula is run-id-base + robot_index*100000
                              # + run_index, run_index 1-based (cmd/perfload/main.go's main loop) -
                              # with --robot-count always 1 here, every invocation's run_ids are
                              # this base + 1 .. + N, UNCONDITIONALLY starting back at +1 each time.
                              # CONFIRMED ON A REAL RUN this is NOT idempotent: Postgres upserts on
                              # run_id (ON CONFLICT DO UPDATE, so it stayed put), but OpenSearch's
                              # per-document _id is SHA256(wsid|timestamp|suffix) - wsid is a pure
                              # function of robot_id/run_id, but timestamp is seeded from
                              # time.Now() at the moment perfload builds the payload (main.go's
                              # buildPayload), so the SAME run_id gets a DIFFERENT _id every
                              # invocation, "create" never 409s against it, and OpenSearch ends up
                              # with duplicate documents instead of an overwrite (internal/parser/
                              # hermit.go, internal/utils/hash.go, internal/opensearch/bulk.go).
                              # A later invocation can never safely "continue" where an earlier one
                              # left off - see do_ingest's already-ingested refusal.
RUN_SPACING_S = POINTS_PER_RUN + 300   # perfload's own formula (cmd/perfload/main.go buildPayload)
SYNTHETIC_JOB_ID_FMT = "PERF-ING-JOB-{robot_id}"   # perfload's own naming (cmd/perfload/main.go)

REQUIRED = [ENV, SECRETS_DIR, DB_LOCAL_PORT, ES_LOOPBACK, AWS_REGION, AWS_PROFILE,
            ROBOT_ID, INGESTER_REPO, PERF_RANK_SCRIPT, LOG_DIR]
if not all(REQUIRED):
    sys.exit("missing env vars - run this via cloud-ingest.sh, not directly")

ROBOT_ID = int(ROBOT_ID)


def require_file(path):
    if not os.path.exists(path):
        sys.exit(f"missing: {path}")


def load_secrets():
    es_path = os.path.join(SECRETS_DIR, "OPENSEARCH.secrets")
    db_path = os.path.join(SECRETS_DIR, "DB.secrets")
    require_file(es_path)
    require_file(db_path)
    es_kv = read_kv(es_path)
    require(es_kv, ["host", "index"], es_path)
    db_kv = read_kv(db_path)
    require(db_kv, ["name", "username", "password"], db_path)
    es_host = normalize_host(es_kv["host"])
    if es_host is None:
        sys.exit(f"{es_path}: 'host' value doesn't look like a plain hostname after stripping scheme/path/port")
    return es_host, es_kv["index"], db_kv


def pg_connect(db_kv):
    return psycopg2.connect(
        host="127.0.0.1", port=DB_LOCAL_PORT, dbname=db_kv["name"],
        user=db_kv["username"], password=db_kv["password"], connect_timeout=10, sslmode="require",
    )


def parse_robot_total_output(stdout_text):
    """Defensive parse of perf-rank-robots.sh --robot-id's stdout: it's supposed to be
    exactly one token (a bare integer, or "10000+") now that its own setup/log output always
    goes to stderr - but don't just trust that blindly. Take the LAST non-empty line and
    validate it; raise ValueError on anything else so the caller refuses instead of guessing."""
    lines = [l for l in stdout_text.splitlines() if l.strip()]
    if not lines:
        raise ValueError("stdout was empty")
    last = lines[-1].strip()
    if last == "10000+":
        return "10000+"
    if not re.fullmatch(r"\d+", last):
        raise ValueError(f"last non-empty stdout line is not a number or '10000+': {last!r}")
    return int(last)


def current_total():
    """The "daemon-free path": re-run perf-rank-robots.sh, which already logs into the real
    target NovApi over HTTPS (no tunnel needed for this part - NovApi/NovApp are public
    endpoints; only Postgres/OpenSearch need the tunnel) and asks weld_run for one robot."""
    result = subprocess.run(
        [PERF_RANK_SCRIPT, "--target", ENV, "--robot-id", str(ROBOT_ID)],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        sys.exit(f"could not read robot {ROBOT_ID}'s current total: {result.stderr.strip()}")
    try:
        parsed = parse_robot_total_output(result.stdout)
    except ValueError as e:
        sys.exit(f"unexpected output from perf-rank-robots.sh --robot-id: {e}")
    if parsed == "10000+":
        sys.exit(f"robot {ROBOT_ID} is already at OpenSearch's 10000 total cap per weld_run - "
                  f"can't compute how many more to add from this signal; stopping")
    return parsed


def os_count(es_host, index, query):
    resp, err = sigv4_request("POST", es_host, ES_LOOPBACK, f"/{index}/_count", AWS_REGION,
                                AWS_PROFILE, data=json.dumps({"query": query}).encode())
    if err:
        sys.exit(f"OpenSearch count failed: {err}")
    if not resp.ok:
        sys.exit(f"OpenSearch count failed: {resp.status_code} {scrub_sensitive(resp.text[:300])}")
    return resp.json().get("count", 0)


def synthetic_count(es_host, index):
    """Count of THIS TOOL's own synthetic documents (weld_session.job_id, a string field -
    confirmed from cmd/perfload/main.go's own buildPayload), not a run_id range: OpenSearch's
    dynamic mapping could store run_id as a keyword OR a number depending on the first
    document it ever saw, so a numeric range query on it isn't safe to assume blind. job_id is
    unambiguous - it's always this exact string, never anything real."""
    job_id = SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)
    return os_count(es_host, index, {"term": {"weld_session.job_id.keyword": job_id}})


def raw_robot_doc_count(es_host, index):
    """ALL documents for this robot (real + synthetic) - used only as a before/after sanity
    check around a real ingest, since each run writes POINTS_PER_RUN+1 raw documents (points
    + one summary), not 1 - the raw count moving by N*(POINTS_PER_RUN+1) is what actually
    proves data landed, independent of NovApi's own weld_run total (a different aggregate)."""
    return os_count(es_host, index, {"term": {"robot.robot_id": ROBOT_ID}})


def refresh_index(es_host, index):
    """Forces OpenSearch to make just-written documents visible to _count before we read it -
    without this, _count can read a stale shard view right after a bulk completes and
    undercount real data (confirmed on a real run: ingester reported 51/51 indexed, but the
    very next _count only showed a delta of 25). A refresh failure is a warning, not a fatal
    error - the caller still polls _count afterward and reports an honest number either way."""
    resp, err = sigv4_request("POST", es_host, ES_LOOPBACK, f"/{index}/_refresh", AWS_REGION, AWS_PROFILE)
    if err:
        print(f"[WARN] index refresh failed: {err} - after-count may read stale", file=sys.stderr)
        return
    if not resp.ok:
        print(f"[WARN] index refresh failed: {resp.status_code} {scrub_sensitive(resp.text[:300])} "
              f"- after-count may read stale", file=sys.stderr)


def wait_for_expected_doc_count(es_host, index, raw_before, expected_delta, timeout_s=10):
    """Forces a refresh and re-polls _count for up to timeout_s until the delta reaches what
    this run should have written, or gives up and returns whatever the last read was - so a
    real shortfall is reported honestly instead of being masked as "pass" by reading too soon,
    and a real pass isn't misreported as a failure for the same reason."""
    deadline = time.monotonic() + timeout_s
    raw_after = raw_before
    while True:
        refresh_index(es_host, index)
        raw_after = raw_robot_doc_count(es_host, index)
        if raw_after - raw_before >= expected_delta or time.monotonic() >= deadline:
            return raw_after
        time.sleep(1)


def pg_association_count(db_kv):
    """Postgres weld_presets_associations rows for this robot's synthetic run_id range only -
    the same scoping --remove uses, so this number is exactly what --remove would clear."""
    conn = pg_connect(db_kv)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM weld_presets_associations WHERE robot_id = %s AND run_id >= %s",
                        (ROBOT_ID, RUN_ID_BASE))
            return cur.fetchone()[0]
    finally:
        conn.close()


def print_plan(n_runs, total_now, label="Runs to add"):
    oldest_offset_s = n_runs * RUN_SPACING_S
    oldest_days = oldest_offset_s / 86400
    print(f"""ENV:                  {ENV}
ROBOT ID:             {ROBOT_ID}
Current total:        {total_now}
Target total:         ~{TARGET_TOTAL}
{label}:        {n_runs}
Points per run:       {POINTS_PER_RUN}
Run-id base:          {RUN_ID_BASE} (fixed - also the removal boundary; every run of this
                      tool restarts at base+1 - running again while prior synthetic data
                      exists DUPLICATES OpenSearch documents, confirmed on a real run - see
                      the already-ingested check below)
Spacing between runs: {RUN_SPACING_S}s (perfload's own formula: points_per_run + 300)
Oldest run in this batch: ~{oldest_days:.1f} days before whenever this actually runs
  (the capture pins its own date range separately, so this window is informational, not
  constrained to 7 days.)

Writes:
  OpenSearch ({ENV}'s real index) - {n_runs} weld_run documents + matching per-run
    weld_test_reports/weld_stats-shaped documents for robot {ROBOT_ID}, job_id
    "{SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)}", run_id >= {RUN_ID_BASE}.
  Postgres ({ENV}'s real DB) - matching weld_presets_associations rows (INSERT ... ON
    CONFLICT DO UPDATE) for the same run_ids, IF a weld_monitoring_presets row already
    matches robot {ROBOT_ID} (checked separately - see the preset precondition).
""")


def run_ingester_tee_scrubbed(cmd, cwd, env):
    """Runs the real ingester, scrubbing every line of its combined stdout+stderr before it's
    shown or stored anywhere - confirmed for real that a signature-mismatch 403 can echo back
    x-amz-security-token (a real, usable session token), and bulk.go has at least two log
    lines that could carry a raw error body: the whole-bulk-request OnError callback
    ("[CRITICAL-FAIL] Entire Bulk Request Rejected! Error: %v") and the per-document
    OnFailure callback's "[DEBUG-FAIL] --- OPENSEARCH REJECTION ---" block (prints
    res.Error.Reason and the raw err). Writes the scrubbed log to a 0600 file under
    .state/cloud-ingest-logs/ and returns (exit_code, log_path)."""
    os.makedirs(LOG_DIR, exist_ok=True, mode=0o700)
    os.chmod(LOG_DIR, 0o700)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = os.path.join(LOG_DIR, f"cloud-ingest-{ENV}-{ts}.log")
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, bufsize=1)
    with os.fdopen(fd, "w") as logf:
        for line in proc.stdout:
            clean = scrub_sensitive(line)
            sys.stdout.write(clean)
            logf.write(clean)
    proc.wait()
    return proc.returncode, log_path


def build_child_env(es_host, index, db_kv):
    pg_dsn = (f"host=127.0.0.1 port={DB_LOCAL_PORT} dbname={db_kv['name']} "
              f"user={db_kv['username']} password={db_kv['password']} sslmode=require")
    return {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "AWS_PROFILE": AWS_PROFILE,
        "AWS_REGION": AWS_REGION,
        "AWS_DEFAULT_REGION": AWS_REGION,
        "ES_HOST": f"https://{es_host}",
        "ES_INDEX": index,
        "PG_DSN": pg_dsn,
    }


def do_remove(args, es_host, index, db_kv):
    job_id = SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)
    es_query = {"query": {"term": {"weld_session.job_id.keyword": job_id}}}
    pg_statement = f"DELETE FROM weld_presets_associations WHERE robot_id = {ROBOT_ID} AND run_id >= {RUN_ID_BASE};"
    print(f"Would delete, scoped to job_id \"{job_id}\" / run_id >= {RUN_ID_BASE} only (never "
          f"touching robot {ROBOT_ID}'s real, non-synthetic data - this also covers any probe "
          f"run, since probes use this same job_id/run_id scheme):\n"
          f"  OpenSearch: POST /{index}/_delete_by_query  {json.dumps(es_query)}\n"
          f"  Postgres:   {pg_statement}\n")
    if not args.confirm_delete:
        print("(dry run by default - pass --confirm-delete to actually delete)")
        return

    answer = input(f"Type the robot id ({ROBOT_ID}) to confirm the real delete: ")
    if answer.strip() != str(ROBOT_ID):
        sys.exit("confirmation did not match - aborting, nothing deleted")

    body = json.dumps(es_query).encode()
    resp, err = sigv4_request("POST", es_host, ES_LOOPBACK, f"/{index}/_delete_by_query",
                                AWS_REGION, AWS_PROFILE, data=body)
    if err:
        sys.exit(f"OpenSearch delete failed: {err}")
    if not resp.ok:
        sys.exit(f"OpenSearch delete failed: {resp.status_code} {scrub_sensitive(resp.text[:300])}")
    es_deleted = resp.json().get("deleted", "?")
    print(f"[INFO] OpenSearch: deleted {es_deleted} document(s)")

    conn = pg_connect(db_kv)
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM weld_presets_associations WHERE robot_id = %s AND run_id >= %s",
                        (ROBOT_ID, RUN_ID_BASE))
            pg_deleted = cur.rowcount
        conn.commit()
    finally:
        conn.close()
    print(f"[INFO] Postgres: deleted {pg_deleted} row(s)")


def do_ingest(args, es_host, index, db_kv):
    total_now = current_total()
    remaining = max(TARGET_TOTAL - total_now, 0)
    if remaining == 0:
        print(f"[INFO] robot {ROBOT_ID} is already at or above the ~{TARGET_TOTAL} target "
              f"(current: {total_now}) - nothing to add.")
        return

    if args.probe:
        n_runs = 1
    elif args.runs is not None:
        n_runs = args.runs
        if n_runs > remaining:
            print(f"[INFO] --runs {n_runs} exceeds what's needed to reach the ~{TARGET_TOTAL} "
                  f"target ({remaining} more) - capped to {remaining}.")
            n_runs = remaining
    else:
        n_runs = remaining

    # CONFIRMED ON A REAL RUN: re-running while synthetic data already exists does NOT
    # idempotently extend it - perfload's run index always restarts at 1 against the same
    # run-id base, and its OpenSearch document _id folds in a wall-clock timestamp seeded
    # fresh each invocation (internal/parser/hermit.go + internal/utils/hash.go), so the same
    # run_id gets a different _id every time, "create" never 409s, and OpenSearch ends up with
    # duplicate documents (Postgres is fine - it upserts on run_id). There is no flag that lets
    # a later invocation "continue" past what an earlier one wrote - the only safe way to add
    # more is to remove the existing synthetic data first, then ingest the full new amount in
    # one shot. This refusal is therefore unconditional (no --probe/--runs bypass) unless
    # --force is passed, and --force is an informed choice to create duplicates, not a safe one.
    already = synthetic_count(es_host, index)
    if already > 0 and not args.force:
        sys.exit(f"already ingested: {already} synthetic document(s) with job_id "
                 f"{SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)} already exist for robot "
                 f"{ROBOT_ID} - a new ingest here would DUPLICATE OpenSearch documents, not "
                 f"extend them (confirmed on a real run). Remove the existing synthetic data "
                 f"first, then re-run this ingest for the full amount you need:\n"
                 f"  ./cloud-ingest.sh --env {ENV} --remove --confirm-delete\n"
                 f"Pass --force instead only if you specifically intend to add duplicates anyway.")

    label = "Runs (probe)" if args.probe else "Runs to add"
    print_plan(n_runs, total_now, label=label)

    if args.dry_run:
        print("(--dry-run: nothing written, perfload not invoked)")
        return

    if not args.template:
        sys.exit("--template <path to a real Hermit V2 sample> is required for a real run")

    raw_before = raw_robot_doc_count(es_host, index)

    child_env = build_child_env(es_host, index, db_kv)
    cmd = ["go", "run", "./cmd/perfload",
           "-template", args.template,
           "-robot-id-start", str(ROBOT_ID), "-robot-count", "1",
           "-runs-per-robot", str(n_runs), "-points-per-run", str(POINTS_PER_RUN),
           "-run-id-base", str(RUN_ID_BASE)]
    print(f"[INFO] running: go run ./cmd/perfload -robot-id-start {ROBOT_ID} -robot-count 1 "
          f"-runs-per-robot {n_runs} -points-per-run {POINTS_PER_RUN} -run-id-base {RUN_ID_BASE} "
          f"(cwd={INGESTER_REPO}) - credentials/DSN are set only on this subprocess's own "
          f"environment, never printed, never in argv. Combined output is scrubbed and logged "
          f"below.", file=sys.stderr)
    returncode, log_path = run_ingester_tee_scrubbed(cmd, INGESTER_REPO, child_env)
    print(f"\n[INFO] full (scrubbed) ingester log: {log_path}")
    if returncode != 0:
        sys.exit(f"ingester exited {returncode} - see {log_path}")

    # Verification - works the same way regardless of n_runs.
    expected_delta = n_runs * (POINTS_PER_RUN + 1)
    raw_after = wait_for_expected_doc_count(es_host, index, raw_before, expected_delta)
    final_delta = raw_after - raw_before
    pg_count = pg_association_count(db_kv)
    rank_total = current_total()

    # The ingester writes this association BEFORE its OpenSearch bulk, so run_id >= RUN_ID_BASE
    # can hold rows from an earlier attempt too (confirmed on a real run: a partially-failed
    # full-size attempt left rows this probe's count then included) - n_runs is only this run's
    # own minimum, never the whole expected count.
    pg_note = "" if pg_count == n_runs else (
        f" - more than this run's {n_runs}; rows from an earlier attempt (e.g. a partially-"
        f"failed larger run) can still be present here and aren't necessarily a problem"
    )

    print(f"""
=== VERIFICATION ===
OpenSearch raw doc count for robot {ROBOT_ID}: {raw_before} -> {raw_after} (delta {final_delta}, expected {expected_delta})
Postgres weld_presets_associations (robot {ROBOT_ID}, run_id >= {RUN_ID_BASE}): {pg_count} (expected at least {n_runs}){pg_note}
perf-rank-robots.sh --target {ENV} --robot-id {ROBOT_ID}: {rank_total} (expected {total_now + n_runs})
""")

    delta_ok = final_delta == expected_delta
    ok = delta_ok and pg_count >= n_runs and rank_total == total_now + n_runs
    if ok:
        new_remaining = max(TARGET_TOTAL - rank_total, 0)
        print(f"[RESULT] Verification passed.")
        if new_remaining > 0:
            # NOT a "continue from here" command - this run's synthetic data still exists, so
            # a follow-up --runs N invocation would duplicate it (see the already-ingested
            # refusal above). The only safe way to add the rest is to remove this run's data
            # and ingest the FULL original remaining amount (this run's n_runs + what's still
            # left) in one shot - never just the delta.
            print(f"This run's synthetic data still exists - a follow-up ingest here would "
                  f"DUPLICATE it, not extend it (see the already-ingested check). To reach the "
                  f"~{TARGET_TOTAL} target, remove it first, then ingest the full {remaining} "
                  f"remaining runs in one shot:\n"
                  f"  ./cloud-ingest.sh --env {ENV} --remove --confirm-delete\n"
                  f"  ./cloud-ingest.sh --env {ENV} --runs {remaining} --template {args.template}")
        else:
            print(f"Robot {ROBOT_ID} is now at the ~{TARGET_TOTAL} target - nothing more to add.")
    else:
        if not delta_ok and final_delta < expected_delta:
            print(f"[RESULT] OpenSearch count is short by {expected_delta - final_delta} after a "
                  f"forced refresh and up to 10s of polling - a real shortfall, not a refresh-"
                  f"timing artifact.")
        print(f"[RESULT] Verification did NOT clearly pass - review the numbers above and the "
              f"log at {log_path} before running more.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                     help="ingest mode: print the plan, write nothing. Accepted (as a no-op) "
                          "with --remove too, which is dry by default already.")
    ap.add_argument("--force", action="store_true", help="skip the already-ingested refusal - "
                     "an informed choice to create DUPLICATE OpenSearch documents (confirmed "
                     "on a real run that re-ingesting does not idempotently extend), not a "
                     "safe default; --remove first is the safe way to add more")
    ap.add_argument("--runs", type=int, help="ingest exactly this many runs (capped at however "
                     "many are left to reach the target); default is however many are left")
    ap.add_argument("--probe", action="store_true", help="shorthand for --runs 1, plus the "
                     "verification output - do this before a full run")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--confirm-delete", action="store_true",
                     help="--remove only: actually delete (after typing the robot id back) - "
                          "without this, --remove only ever prints what it would delete")
    ap.add_argument("--template", help="path to a real Hermit V2 sample file (required for a real ingest run)")
    args = ap.parse_args()

    if args.runs is not None and args.runs < 1:
        sys.exit("--runs must be a positive integer")
    if args.probe and args.runs is not None:
        sys.exit("--probe and --runs are mutually exclusive (--probe is --runs 1)")

    live_identity, identity_err = get_caller_identity(AWS_REGION, AWS_PROFILE)
    if live_identity is None:
        sys.exit(f"AWS session check failed: {identity_err}")
    print(f"[INFO] SigV4 identity: {live_identity}", file=sys.stderr)

    es_host, index, db_kv = load_secrets()

    if args.remove:
        do_remove(args, es_host, index, db_kv)
    else:
        do_ingest(args, es_host, index, db_kv)


if __name__ == "__main__":
    main()

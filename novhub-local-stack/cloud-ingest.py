#!/usr/bin/env python3
"""HUB-106: dev-only ingest wrapper around opensearch-ingester's perfload tool, through
cloud-tunnel.sh. Computes how many runs to add (reading the robot's REAL current total first,
never hardcoded), refuses if already ingested, prints the full plan before running anything,
and never puts a secret on perfload's command line - credentials reach it only via that one
subprocess's own environment. --remove is dry by default and needs a typed confirmation.
"""
import argparse
import json
import os
import re
import subprocess
import sys

import psycopg2

from cloud_common import normalize_host, read_kv, require, sigv4_request, get_caller_identity

ENV = os.environ.get("CLOUD_INGEST_ENV")
SECRETS_DIR = os.environ.get("CLOUD_INGEST_SECRETS_DIR")
DB_LOCAL_PORT = os.environ.get("CLOUD_INGEST_DB_LOCAL_PORT")
ES_LOCAL_PORT = os.environ.get("CLOUD_INGEST_ES_LOCAL_PORT")
AWS_REGION = os.environ.get("CLOUD_INGEST_AWS_REGION")
AWS_PROFILE = os.environ.get("CLOUD_INGEST_AWS_PROFILE")
ROBOT_ID = os.environ.get("CLOUD_INGEST_ROBOT_ID")
INGESTER_REPO = os.environ.get("CLOUD_INGEST_INGESTER_REPO")
PERF_RANK_SCRIPT = os.environ.get("CLOUD_INGEST_RANK_SCRIPT")

TARGET_TOTAL = 2260          # "about 2,260" per the owner - test's NovAI-1555 has 2,259
POINTS_PER_RUN = 50          # modest, per the owner
RUN_ID_BASE = 90000000       # far above any real run_id - also the removal boundary
RUN_SPACING_S = POINTS_PER_RUN + 300   # perfload's own formula (cmd/perfload/main.go buildPayload)
SYNTHETIC_JOB_ID_FMT = "PERF-ING-JOB-{robot_id}"   # perfload's own naming (cmd/perfload/main.go)

REQUIRED = [ENV, SECRETS_DIR, DB_LOCAL_PORT, ES_LOCAL_PORT, AWS_REGION, AWS_PROFILE,
            ROBOT_ID, INGESTER_REPO, PERF_RANK_SCRIPT]
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


def synthetic_count(es_host, index):
    """Existence check for this tool's own synthetic marker (weld_session.job_id, a string
    field - confirmed from cmd/perfload/main.go's own buildPayload), not a run_id range:
    OpenSearch's dynamic mapping could store run_id as a keyword OR a number depending on the
    first document it ever saw, so a numeric range query on it isn't safe to assume blind.
    job_id is unambiguous - it's always this exact string, never anything real."""
    job_id = SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)
    body = json.dumps({"query": {"term": {"weld_session.job_id.keyword": job_id}}}).encode()
    resp, err = sigv4_request("POST", es_host, ES_LOCAL_PORT, f"/{index}/_count", AWS_REGION,
                                AWS_PROFILE, data=body)
    if err:
        sys.exit(f"could not check for a prior ingest: {err}")
    if not resp.ok:
        sys.exit(f"could not check for a prior ingest: _count returned {resp.status_code} {resp.text[:300]}")
    return resp.json().get("count", 0)


def print_plan(n_to_add, total_now):
    oldest_offset_s = n_to_add * RUN_SPACING_S
    oldest_days = oldest_offset_s / 86400
    print(f"""ENV:                  {ENV}
ROBOT ID:             {ROBOT_ID}
Current total:        {total_now}
Target total:         ~{TARGET_TOTAL}
Runs to add:          {n_to_add}
Points per run:       {POINTS_PER_RUN}
Run-id base:          {RUN_ID_BASE} (also the removal boundary later)
Spacing between runs: {RUN_SPACING_S}s (perfload's own formula: points_per_run + 300)
Oldest new run:       ~{oldest_days:.1f} days before whenever this actually runs
  (the capture pins its own date range separately, so this window is informational, not
  constrained to 7 days.)

Writes:
  OpenSearch ({ENV}'s real index) - {n_to_add} weld_run documents + matching per-run
    weld_test_reports/weld_stats-shaped documents for robot {ROBOT_ID}, job_id
    "{SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)}", run_id >= {RUN_ID_BASE}.
  Postgres ({ENV}'s real DB) - matching weld_presets_associations rows (INSERT ... ON
    CONFLICT DO UPDATE) for the same run_ids, IF a weld_monitoring_presets row already
    matches robot {ROBOT_ID} (checked separately - see the preset precondition).
""")


def do_remove(args, es_host, index, db_kv):
    job_id = SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)
    es_query = {"query": {"term": {"weld_session.job_id.keyword": job_id}}}
    pg_statement = f"DELETE FROM weld_presets_associations WHERE robot_id = {ROBOT_ID} AND run_id >= {RUN_ID_BASE};"
    print(f"Would delete, scoped to job_id \"{job_id}\" / run_id >= {RUN_ID_BASE} only (never "
          f"touching robot {ROBOT_ID}'s real, non-synthetic data):\n"
          f"  OpenSearch: POST /{index}/_delete_by_query  {json.dumps(es_query)}\n"
          f"  Postgres:   {pg_statement}\n")
    if not args.confirm_delete:
        print("(dry run by default - pass --confirm-delete to actually delete)")
        return

    answer = input(f"Type the robot id ({ROBOT_ID}) to confirm the real delete: ")
    if answer.strip() != str(ROBOT_ID):
        sys.exit("confirmation did not match - aborting, nothing deleted")

    body = json.dumps(es_query).encode()
    resp, err = sigv4_request("POST", es_host, ES_LOCAL_PORT, f"/{index}/_delete_by_query",
                                AWS_REGION, AWS_PROFILE, data=body)
    if err:
        sys.exit(f"OpenSearch delete failed: {err}")
    if not resp.ok:
        sys.exit(f"OpenSearch delete failed: {resp.status_code} {resp.text[:300]}")
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
    already = synthetic_count(es_host, index)
    if already > 0 and not args.force:
        sys.exit(f"already ingested: {already} synthetic document(s) with job_id "
                 f"{SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)} already exist - pass --force to add more anyway")

    total_now = current_total()
    n_to_add = max(TARGET_TOTAL - total_now, 0)
    if n_to_add == 0:
        print(f"[INFO] robot {ROBOT_ID} is already at or above the ~{TARGET_TOTAL} target "
              f"(current: {total_now}) - nothing to add.")
        return

    print_plan(n_to_add, total_now)

    if args.dry_run:
        print("(--dry-run: nothing written, perfload not invoked)")
        return

    if not args.template:
        sys.exit("--template <path to a real Hermit V2 sample> is required for a real run")

    pg_dsn = (f"host=127.0.0.1 port={DB_LOCAL_PORT} dbname={db_kv['name']} "
              f"user={db_kv['username']} password={db_kv['password']} sslmode=require")
    child_env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "AWS_PROFILE": AWS_PROFILE,
        "AWS_REGION": AWS_REGION,
        "AWS_DEFAULT_REGION": AWS_REGION,
        "ES_HOST": f"https://{es_host}:{ES_LOCAL_PORT}",
        "ES_INDEX": index,
        "PG_DSN": pg_dsn,
    }
    cmd = ["go", "run", "./cmd/perfload",
           "-template", args.template,
           "-robot-id-start", str(ROBOT_ID), "-robot-count", "1",
           "-runs-per-robot", str(n_to_add), "-points-per-run", str(POINTS_PER_RUN),
           "-run-id-base", str(RUN_ID_BASE)]
    print(f"[INFO] running: go run ./cmd/perfload -robot-id-start {ROBOT_ID} -robot-count 1 "
          f"-runs-per-robot {n_to_add} -points-per-run {POINTS_PER_RUN} -run-id-base {RUN_ID_BASE} "
          f"(cwd={INGESTER_REPO}) - credentials/DSN are set only on this subprocess's own "
          f"environment, never printed, never in argv", file=sys.stderr)
    result = subprocess.run(cmd, cwd=INGESTER_REPO, env=child_env)
    sys.exit(result.returncode)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                     help="ingest mode: print the plan, write nothing. Accepted (as a no-op) "
                          "with --remove too, which is dry by default already.")
    ap.add_argument("--force", action="store_true", help="skip the already-ingested refusal")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--confirm-delete", action="store_true",
                     help="--remove only: actually delete (after typing the robot id back) - "
                          "without this, --remove only ever prints what it would delete")
    ap.add_argument("--template", help="path to a real Hermit V2 sample file (required for a real ingest run)")
    args = ap.parse_args()

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

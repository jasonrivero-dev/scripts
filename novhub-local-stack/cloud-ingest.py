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
import math
import os
import random
import re
import subprocess
import sys
import tempfile
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
                              # Re-ingesting the same run IDs would create duplicate OpenSearch
                              # documents because each invocation uses new timestamps and document
                              # IDs. The pre-ingest audit therefore permits only a complete no-op
                              # or an empty state; it rejects partial/conflicting batches.
RUN_SPACING_S = POINTS_PER_RUN + 300   # perfload's own formula (cmd/perfload/main.go buildPayload)
SYNTHETIC_JOB_ID_FMT = "PERF-ING-JOB-{robot_id}"   # perfload's own naming (cmd/perfload/main.go)
RANGE_MAP_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema_mapping.json")
RUN_ID_AGGREGATION_SIZE = TARGET_TOTAL + 1
RUN_ID_MAPPING_TYPES = {"byte", "short", "integer", "long", "unsigned_long", "keyword"}
FEEDBACK_FIELDS = (
    "autonomy_dist_x_raw",
    "autonomy_dist_y_raw",
    "camera_temp",
    "live_amps",
    "live_travel_speed",
    "live_trim",
    "live_voltage",
    "live_weave_amplitude",
    "live_weave_frequency",
    "live_wfs",
    "max_gap_measurement",
    "prescan_gap_measurement",
)

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


def resolve_mapped_field(properties, field_path, allowed_types):
    parts = field_path.split(".")
    current = properties
    for part in parts[:-1]:
        parent = current.get(part)
        if not isinstance(parent, dict) or parent.get("type") == "nested":
            raise ValueError(f"OpenSearch mapping is missing object field {field_path}")
        current = parent.get("properties")
        if not isinstance(current, dict):
            raise ValueError(f"OpenSearch mapping is missing object field {field_path}")

    field = current.get(parts[-1])
    if not isinstance(field, dict):
        raise ValueError(f"OpenSearch mapping is missing field {field_path}")
    field_type = field.get("type")
    if field_type == "text":
        subfields = field.get("fields")
        keyword = subfields.get("keyword") if isinstance(subfields, dict) else None
        if isinstance(keyword, dict) and keyword.get("type") == "keyword":
            return f"{field_path}.keyword", "keyword"
    elif field_type in allowed_types:
        return field_path, field_type
    raise ValueError(f"OpenSearch mapping has unsupported type for field {field_path}")


def resolve_audit_fields(mapping_response):
    if not isinstance(mapping_response, dict) or not mapping_response:
        raise ValueError("OpenSearch mapping response did not contain any index mappings")

    resolved = None
    for index_name, index_mapping in mapping_response.items():
        mappings = index_mapping.get("mappings") if isinstance(index_mapping, dict) else None
        properties = mappings.get("properties") if isinstance(mappings, dict) else None
        if not isinstance(properties, dict):
            raise ValueError(f"OpenSearch mapping for {index_name} has no properties")
        current = (
            resolve_mapped_field(properties, "run_id", RUN_ID_MAPPING_TYPES),
            resolve_mapped_field(properties, "weld_session.job_id", {"keyword"}),
        )
        if resolved is not None and current != resolved:
            raise ValueError("OpenSearch index mappings disagree on audit field types")
        resolved = current
    return resolved[0][0], resolved[1][0]


def signed_opensearch_json(method, es_host, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    resp, err = sigv4_request(
        method, es_host, ES_LOOPBACK, path, AWS_REGION, AWS_PROFILE, data=data, timeout=15
    )
    if err:
        raise ValueError(f"OpenSearch {path} request failed: {scrub_sensitive(err)}")
    if resp is None or not resp.ok:
        status = resp.status_code if resp is not None else "no response"
        detail = scrub_sensitive(resp.text[:300]) if resp is not None else ""
        raise ValueError(f"OpenSearch {path} request failed: {status} {detail}".strip())
    try:
        payload = resp.json()
    except ValueError as e:
        raise ValueError(f"OpenSearch {path} response was not valid JSON") from e
    if not isinstance(payload, dict):
        raise ValueError(f"OpenSearch {path} response was not a JSON object")
    return payload


def parse_run_id(value):
    if isinstance(value, bool):
        raise ValueError("OpenSearch returned a non-integer synthetic run_id")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"\d+", value):
        return int(value)
    raise ValueError("OpenSearch returned a non-integer synthetic run_id")


def opensearch_run_counts(es_host, index, run_id_field, job_id_field):
    job_id = SYNTHETIC_JOB_ID_FMT.format(robot_id=ROBOT_ID)
    response = signed_opensearch_json(
        "POST",
        es_host,
        f"/{index}/_search",
        {
            "size": 0,
            "query": {"term": {job_id_field: job_id}},
            "aggs": {
                "runs": {
                    "terms": {
                        "field": run_id_field,
                        "size": RUN_ID_AGGREGATION_SIZE,
                        "order": {"_key": "asc"},
                    }
                },
                "missing_run_id": {"missing": {"field": run_id_field}},
            },
        },
    )
    if response.get("timed_out") is not False:
        raise ValueError("OpenSearch synthetic-run audit timed out")
    if response.get("terminated_early") is True:
        raise ValueError("OpenSearch synthetic-run audit terminated early")
    shards = response.get("_shards")
    failed_shards = shards.get("failed") if isinstance(shards, dict) else None
    if type(failed_shards) is not int or failed_shards != 0:
        raise ValueError("OpenSearch synthetic-run audit had failed shards")
    aggregations = response.get("aggregations")
    runs = aggregations.get("runs") if isinstance(aggregations, dict) else None
    missing = aggregations.get("missing_run_id") if isinstance(aggregations, dict) else None
    if not isinstance(runs, dict) or not isinstance(missing, dict):
        raise ValueError("OpenSearch synthetic-run audit response is missing aggregations")
    other_doc_count = runs.get("sum_other_doc_count")
    if type(other_doc_count) is not int or other_doc_count != 0:
        raise ValueError("OpenSearch synthetic-run audit truncated the run_id buckets")
    buckets = runs.get("buckets")
    missing_count = missing.get("doc_count")
    if not isinstance(buckets, list) or type(missing_count) is not int or missing_count < 0:
        raise ValueError("OpenSearch synthetic-run audit returned invalid aggregation data")

    run_counts = {}
    for bucket in buckets:
        if (
            not isinstance(bucket, dict)
            or type(bucket.get("doc_count")) is not int
            or bucket["doc_count"] < 1
        ):
            raise ValueError("OpenSearch synthetic-run audit returned an invalid run bucket")
        run_id = parse_run_id(bucket.get("key"))
        if run_id in run_counts:
            raise ValueError(f"OpenSearch synthetic-run audit duplicated bucket {run_id}")
        run_counts[run_id] = bucket["doc_count"]
    return run_counts, missing_count


def postgres_run_counts(db_kv):
    conn = None
    try:
        conn = pg_connect(db_kv)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT run_id, COUNT(*) FROM weld_presets_associations "
                "WHERE robot_id = %s AND run_id >= %s GROUP BY run_id",
                (ROBOT_ID, RUN_ID_BASE),
            )
            rows = cur.fetchall()
    except psycopg2.Error as e:
        raise ValueError(f"Postgres synthetic-run audit failed: {scrub_sensitive(str(e))}") from e
    finally:
        if conn is not None:
            conn.close()

    run_counts = {}
    for run_id, count in rows:
        normalized_id = parse_run_id(run_id)
        if type(count) is not int or count < 1:
            raise ValueError(f"Postgres returned an invalid association count for run {normalized_id}")
        run_counts[normalized_id] = count
    return run_counts


def audit_synthetic_state(es_host, index, db_kv):
    mapping = signed_opensearch_json("GET", es_host, f"/{index}/_mapping")
    run_id_field, job_id_field = resolve_audit_fields(mapping)
    os_counts, unkeyed_docs = opensearch_run_counts(
        es_host, index, run_id_field, job_id_field
    )
    return {
        "opensearch_counts": os_counts,
        "opensearch_unkeyed_docs": unkeyed_docs,
        "postgres_counts": postgres_run_counts(db_kv),
    }


def audit_is_empty(state):
    return (
        not state["opensearch_counts"]
        and state["opensearch_unkeyed_docs"] == 0
        and not state["postgres_counts"]
    )


def format_run_ids(run_ids):
    values = sorted(run_ids)
    preview = ", ".join(str(value) for value in values[:5])
    if len(values) > 5:
        preview += f", ... (+{len(values) - 5})"
    return preview


def audit_issues(state, expected_run_ids=None):
    os_counts = state["opensearch_counts"]
    pg_counts = state["postgres_counts"]
    os_ids = set(os_counts)
    pg_ids = set(pg_counts)
    issues = []

    if state["opensearch_unkeyed_docs"]:
        issues.append(
            f"OpenSearch has {state['opensearch_unkeyed_docs']} synthetic document(s) without run_id"
        )
    if expected_run_ids is None:
        missing_os = pg_ids - os_ids
        missing_pg = os_ids - pg_ids
        if missing_os:
            issues.append(f"OpenSearch is missing run IDs: {format_run_ids(missing_os)}")
        if missing_pg:
            issues.append(f"Postgres is missing run IDs: {format_run_ids(missing_pg)}")
        if os_ids and (
            min(os_ids) != RUN_ID_BASE + 1
            or max(os_ids) > RUN_ID_BASE + TARGET_TOTAL
            or len(os_ids) != max(os_ids) - RUN_ID_BASE
        ):
            issues.append("synthetic run IDs are not a contiguous range from the configured base")
    else:
        missing_os = expected_run_ids - os_ids
        extra_os = os_ids - expected_run_ids
        missing_pg = expected_run_ids - pg_ids
        extra_pg = pg_ids - expected_run_ids
        if missing_os:
            issues.append(f"OpenSearch is missing run IDs: {format_run_ids(missing_os)}")
        if extra_os:
            issues.append(f"OpenSearch has unexpected run IDs: {format_run_ids(extra_os)}")
        if missing_pg:
            issues.append(f"Postgres is missing run IDs: {format_run_ids(missing_pg)}")
        if extra_pg:
            issues.append(f"Postgres has unexpected run IDs: {format_run_ids(extra_pg)}")

    expected_docs = POINTS_PER_RUN + 1
    for run_id, count in os_counts.items():
        if count != expected_docs:
            issues.append(
                f"OpenSearch run {run_id} has {count} documents; expected {expected_docs}"
            )
    for run_id, count in pg_counts.items():
        if count != 1:
            issues.append(f"Postgres run {run_id} has {count} association rows; expected 1")
    return issues


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
                      tool restarts at base+1 - exact completed batches are a no-op;
                      partial/conflicting batches fail the automatic audit before writing)
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


def read_json_file(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise ValueError(f"invalid {label} JSON at {path}: {e}") from e
    except OSError as e:
        raise ValueError(f"could not read {label} at {path}: {e}") from e


def load_range_map(path=RANGE_MAP_PATH):
    entries = read_json_file(path, "range map")
    if not isinstance(entries, list):
        raise ValueError(f"range map at {path} must be a JSON array")

    by_column = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("Column"), str):
            raise ValueError(f"range map at {path} contains an invalid entry")
        column = entry["Column"]
        if column in by_column:
            raise ValueError(f"range map at {path} contains duplicate column {column!r}")
        by_column[column] = entry
    return by_column


def mapping_entry(range_map, field, schema_type):
    entry = range_map.get(field)
    if entry is None:
        raise ValueError(f"range map has no entry for {field}")
    if entry.get("Type") != schema_type:
        raise ValueError(
            f"range-map type for {field} is {entry.get('Type')!r}, "
            f"but the template schema says {schema_type!r}"
        )
    return entry


def numeric_bounds(range_text, field):
    if not isinstance(range_text, str):
        raise ValueError(f"range for {field} must be text")
    match = re.match(
        r"\s*(-?\d+(?:\.\d+)?)\s+to\s+(-?\d+(?:\.\d+)?)\b",
        range_text.replace(",", ""),
    )
    if not match:
        raise ValueError(f"range for {field} is not a numeric minimum-to-maximum range")
    low, high = map(float, match.groups())
    if not math.isfinite(low) or not math.isfinite(high) or low >= high:
        raise ValueError(f"range for {field} has invalid bounds")
    return low, high


def sample_values(field, schema_type, range_text, count, rng):
    low, high = numeric_bounds(range_text, field)
    if re.fullmatch(r"[iu]\d+", schema_type):
        low_int, high_int = math.ceil(low), math.floor(high)
        if low_int >= high_int:
            raise ValueError(f"integer range for {field} cannot provide distinct values")
        values = [rng.randint(low_int, high_int) for _ in range(count)]
        if len(set(values)) < 2:
            values[1] = high_int if values[0] != high_int else low_int
        return values
    if schema_type in ("f32", "f64"):
        values = [rng.uniform(low, high) for _ in range(count)]
        if len(set(values)) < 2:
            values[1] = high if values[0] != high else low
        return values
    raise ValueError(f"unsupported measurement type {schema_type!r} for {field}")


def row_increment(range_text, field):
    if not isinstance(range_text, str):
        raise ValueError(f"range for {field} must be text")
    match = re.search(r"\(\s*\+\s*(\d+(?:\.\d+)?)\s*(?:ms)?\s*/row\s*\)", range_text, re.I)
    if not match:
        raise ValueError(f"range map does not define a per-row increment for {field}")
    return float(match.group(1))


def utc_timestamp(value, field):
    if not isinstance(value, str):
        raise ValueError(f"template value for {field} must be an ISO-8601 string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.datetime.fromisoformat(normalized)
    except ValueError as e:
        raise ValueError(f"template value for {field} is not a valid ISO-8601 timestamp") from e
    if parsed.tzinfo is None:
        raise ValueError(f"template value for {field} must include a timezone")
    return parsed.astimezone(datetime.timezone.utc)


def build_varied_template(template, range_map, row_count=POINTS_PER_RUN, rng=None):
    if row_count < 2:
        raise ValueError("at least two template rows are required")
    if not isinstance(template, dict) or not isinstance(template.get("schema"), dict):
        raise ValueError("Hermit template must contain a schema object")
    schema = template["schema"]
    source_rows = template.get("values")
    if not isinstance(source_rows, list) or not source_rows:
        raise ValueError("Hermit template must contain at least one values row")
    field_indexes = {field: index for index, field in enumerate(schema)}
    for row_number, row in enumerate(source_rows):
        if not isinstance(row, list) or len(row) != len(field_indexes):
            raise ValueError(f"Hermit template values row {row_number} does not match its schema")

    rng = rng or random.SystemRandom()
    generated_values = {}
    for field in FEEDBACK_FIELDS:
        if field not in field_indexes:
            raise ValueError(f"Hermit template schema is missing feedback field {field}")
        entry = mapping_entry(range_map, field, schema[field])
        generated_values[field] = sample_values(
            field, schema[field], entry.get("Probable Range"), row_count, rng
        )

    sequenced_values = {}
    for field in ("arc_time", "plc_time", "timestamp"):
        if field not in field_indexes:
            raise ValueError(f"Hermit template schema is missing time field {field}")
        entry = mapping_entry(range_map, field, schema[field])
        increment = row_increment(entry.get("Probable Range", ""), field)
        if field == "timestamp":
            start = utc_timestamp(source_rows[0][field_indexes[field]], field)
            sequenced_values[field] = [
                (start + datetime.timedelta(milliseconds=increment * index))
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z")
                for index in range(row_count)
            ]
        else:
            base_value = source_rows[0][field_indexes[field]]
            if isinstance(base_value, bool) or not isinstance(base_value, int):
                raise ValueError(f"template value for {field} must be an integer")
            if not increment.is_integer():
                raise ValueError(f"row increment for {field} must be an integer")
            sequenced_values[field] = [
                base_value + int(increment) * index for index in range(row_count)
            ]
            if schema[field].startswith("u"):
                max_value = (1 << int(schema[field][1:])) - 1
                if base_value < 0 or sequenced_values[field][-1] > max_value:
                    raise ValueError(f"sequential values for {field} exceed {schema[field]} bounds")

    rows = []
    for index in range(row_count):
        row = list(source_rows[index % len(source_rows)])
        for field, values in generated_values.items():
            row[field_indexes[field]] = values[index]
        for field, values in sequenced_values.items():
            row[field_indexes[field]] = values[index]
        rows.append(row)

    varied = dict(template)
    varied["values"] = rows
    return varied


def write_private_template(template, directory):
    path = os.path.join(directory, "hermit-template.json")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(template, f, indent=2)
            f.write("\n")
    except OSError as e:
        raise ValueError(f"could not write private temporary template: {e}") from e
    return path


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
        try:
            state = audit_synthetic_state(es_host, index, db_kv)
        except ValueError as e:
            sys.exit(f"pre-ingest audit failed: {scrub_sensitive(str(e))}")
        issues = audit_issues(state)
        if issues:
            sys.exit("pre-ingest audit failed: " + "; ".join(issues))
        print(f"[INFO] robot {ROBOT_ID} is already at or above the ~{TARGET_TOTAL} target "
              f"(current: {total_now}); synthetic data audit passed - nothing to add.")
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

    expected_run_ids = set(range(RUN_ID_BASE + 1, RUN_ID_BASE + n_runs + 1))
    try:
        pre_state = audit_synthetic_state(es_host, index, db_kv)
    except ValueError as e:
        sys.exit(f"pre-ingest audit failed: {scrub_sensitive(str(e))}")
    if not audit_is_empty(pre_state):
        issues = audit_issues(pre_state, expected_run_ids)
        if issues:
            sys.exit("pre-ingest audit found partial or conflicting synthetic data; "
                     "no write was attempted: " + "; ".join(issues))
        if args.dry_run:
            label = "Runs (probe)" if args.probe else "Runs to add"
            print_plan(n_runs, total_now, label=label)
            print("(--dry-run: nothing written, perfload not invoked)")
        else:
            print(f"[INFO] requested synthetic batch of {n_runs} run(s) is already complete "
                  f"in OpenSearch and Postgres - verified no-op.")
        return

    label = "Runs (probe)" if args.probe else "Runs to add"
    print_plan(n_runs, total_now, label=label)

    if args.dry_run:
        print("(--dry-run: nothing written, perfload not invoked)")
        return

    if not args.template:
        sys.exit("--template <path to a real Hermit V2 sample> is required for a real run")

    try:
        template = read_json_file(args.template, "Hermit template")
        range_map = load_range_map()
        varied_template = build_varied_template(template, range_map)
    except ValueError as e:
        sys.exit(f"could not prepare varied Hermit template: {scrub_sensitive(str(e))}")

    raw_before = raw_robot_doc_count(es_host, index)

    with tempfile.TemporaryDirectory(prefix="cloud-ingest-") as temp_dir:
        try:
            temp_template_path = write_private_template(varied_template, temp_dir)
        except ValueError as e:
            sys.exit(str(e))
        child_env = build_child_env(es_host, index, db_kv)
        cmd = ["go", "run", "./cmd/perfload",
               "-template", temp_template_path,
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
    try:
        post_state = audit_synthetic_state(es_host, index, db_kv)
    except ValueError as e:
        sys.exit(f"post-ingest audit failed: {scrub_sensitive(str(e))}")
    post_issues = audit_issues(post_state, expected_run_ids)
    os_run_count = len(post_state["opensearch_counts"])
    os_doc_count = sum(post_state["opensearch_counts"].values())
    pg_run_count = len(post_state["postgres_counts"])
    pg_count = sum(post_state["postgres_counts"].values())
    rank_total = current_total()

    print(f"""
=== VERIFICATION ===
OpenSearch raw doc count for robot {ROBOT_ID}: {raw_before} -> {raw_after} (delta {final_delta}, expected {expected_delta})
OpenSearch synthetic runs/documents: {os_run_count}/{n_runs} runs, {os_doc_count}/{expected_delta} documents
Postgres synthetic runs/associations: {pg_run_count}/{n_runs} runs, {pg_count}/{n_runs} rows
perf-rank-robots.sh --target {ENV} --robot-id {ROBOT_ID}: {rank_total} (expected {total_now + n_runs})
""")

    verification_errors = list(post_issues)
    if final_delta != expected_delta:
        verification_errors.append(
            f"OpenSearch robot document delta was {final_delta}; expected {expected_delta}"
        )
    if rank_total != total_now + n_runs:
        verification_errors.append(
            f"rank total was {rank_total}; expected {total_now + n_runs}"
        )
    if verification_errors:
        sys.exit("[RESULT] Verification failed: " + "; ".join(verification_errors))

    new_remaining = max(TARGET_TOTAL - rank_total, 0)
    print("[RESULT] Verification passed.")
    if new_remaining > 0:
        print(f"To reach the ~{TARGET_TOTAL} target, remove this complete batch, then ingest "
              f"the full {remaining} remaining runs in one shot:\n"
              f"  ./cloud-ingest.sh --env {ENV} --remove --confirm-delete\n"
              f"  ./cloud-ingest.sh --env {ENV} --runs {remaining} --template {args.template}")
    else:
        print(f"Robot {ROBOT_ID} is now at the ~{TARGET_TOTAL} target - nothing more to add.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                     help="ingest mode: print the plan, write nothing. Accepted (as a no-op) "
                          "with --remove too, which is dry by default already.")
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

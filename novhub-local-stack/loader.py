#!/usr/bin/env python3
import json
import os
import sys

import psycopg2
import psycopg2.extras
import requests

NOVDATA_HOST = os.environ.get("NOVDATA_HOST", "127.0.0.1")
NOVDATA_PORT = os.environ.get("NOVDATA_PORT", "5432")
NOVDATA_DB = os.environ.get("NOVDATA_DB", "swrdb")
NOVDATA_USER = os.environ.get("NOVDATA_USER", "novdata")
SWR_DB_KEY = os.environ.get("SWR_DB_KEY")
OPENSEARCH_URL = os.environ.get("OPENSEARCH_URL", "http://127.0.0.1:9200")
OPENSEARCH_INDEX = os.environ.get("OPENSEARCH_INDEX", "novhub-local")

if not SWR_DB_KEY:
    sys.exit("SWR_DB_KEY is not set")

# weld_run_end and weld_data both carry a composite FK to weld_run(id, robot_id), not a
# plain id reference - confirmed against 20190513-232200-update_constraints_for_aggr_denorm.
RUN_QUERY = """
    SELECT wr.*, wre.arc_off_utc, wre.total_weld_degree
    FROM weld_run wr
    JOIN weld_run_end wre ON wre.id = wr.id AND wre.robot_id = wr.robot_id
"""

DATA_QUERY = """
    SELECT wd.id, wd.time_utc, wd.arc_time, wd.voltage_v, wd.current_a,
           wd.wire_feed_speed_ipm, wd.speed_ipm, wd.weave_amplitude_mm, wd.weave_frequency,
           wr.run_number, wr.robot_id, wr.work_order_ref, wr.spool_ref, wr.welder_id_ref
    FROM weld_data wd
    JOIN weld_run wr ON wd.run_id = wr.id AND wd.robot_id = wr.robot_id
"""


def iso(value):
    if value is None:
        return None
    return value.isoformat() + "Z"


def or_na(value):
    return value if value is not None else "NA"


def weld_session(work_order_ref, spool_ref, welder_id_ref):
    return {
        "job_id": or_na(work_order_ref),
        "part_id": or_na(spool_ref),
        "weld_id": or_na(welder_id_ref),
        "serial_id": "NA",
    }


def run_document(row):
    summary = dict(row)
    for key in ("arc_on_utc", "arc_off_utc"):
        if key in summary:
            summary[key] = iso(summary[key])
    doc_id = f"{row['robot_id']}_{row['run_number']}_run"
    doc = {
        "run_id": row["run_number"],
        "robot": {"robot_id": row["robot_id"]},
        "@timestamp": iso(row["arc_on_utc"]),
        "weld_session": weld_session(row["work_order_ref"], row["spool_ref"], row["welder_id_ref"]),
        "weld_summary": summary,
    }
    return doc_id, doc


def data_document(row):
    doc_id = f"{row['robot_id']}_{row['run_number']}_{row['id']}"
    doc = {
        "run_id": row["run_number"],
        "robot": {"robot_id": row["robot_id"]},
        "@timestamp": iso(row["time_utc"]),
        "arc_time": row["arc_time"],
        "live_voltage": row["voltage_v"],
        "live_amps": row["current_a"],
        "live_wfs": row["wire_feed_speed_ipm"],
        "live_travel_speed": row["speed_ipm"],
        "live_weave_amplitude": row["weave_amplitude_mm"],
        "live_weave_frequency": row["weave_frequency"],
        "weld_session": weld_session(row["work_order_ref"], row["spool_ref"], row["welder_id_ref"]),
    }
    return doc_id, doc


def fetch(conn, query):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query)
        return cur.fetchall()


def bulk_body(docs):
    lines = []
    for doc_id, doc in docs:
        lines.append(json.dumps({"index": {"_index": OPENSEARCH_INDEX, "_id": doc_id}}))
        lines.append(json.dumps(doc, default=str))
    return "\n".join(lines) + "\n" if lines else ""


def main():
    try:
        conn = psycopg2.connect(
            host=NOVDATA_HOST,
            port=NOVDATA_PORT,
            dbname=NOVDATA_DB,
            user=NOVDATA_USER,
            password=SWR_DB_KEY,
        )
    except psycopg2.OperationalError as exc:
        sys.exit(f"not running: NovData's Postgres ({NOVDATA_HOST}:{NOVDATA_PORT}) - {exc}")

    try:
        run_rows = fetch(conn, RUN_QUERY)
        data_rows = fetch(conn, DATA_QUERY)
    finally:
        conn.close()

    docs = [run_document(row) for row in run_rows] + [data_document(row) for row in data_rows]

    if not docs:
        print("ok: nothing to load (0 completed runs, 0 data points)")
        return

    try:
        resp = requests.post(
            f"{OPENSEARCH_URL}/_bulk",
            data=bulk_body(docs).encode("utf-8"),
            headers={"Content-Type": "application/x-ndjson"},
            timeout=30,
        )
    except requests.exceptions.RequestException as exc:
        sys.exit(f"not running: OpenSearch ({OPENSEARCH_URL}) - {exc}")
    resp.raise_for_status()
    result = resp.json()
    if result.get("errors"):
        failed = [item for item in result["items"] if item.get("index", {}).get("status", 200) >= 300]
        sys.exit(f"FAILED: {len(failed)} of {len(docs)} documents failed: {failed[:3]}")

    print(f"ok: loaded {len(run_rows)} run document(s) and {len(data_rows)} data point(s)")


if __name__ == "__main__":
    main()

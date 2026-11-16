#!/usr/bin/env python3
"""HUB-106: seed/remove a frozen synthetic dataset for NovApi/NovApp perf testing.

Everything this writes is tagged by construction: robot ids 900001-900010 (ROBOT_ID_START
.. +ROBOT_COUNT), one user by a fixed synthetic email, one group by a fixed synthetic name.
`remove` deletes exactly those tagged rows/docs - nothing else is ever touched.
"""
import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys

import psycopg2
import psycopg2.extras
import requests

ROBOT_ID_START = 900001
ROBOT_COUNT = 10
RUNS_PER_ROBOT = 2000
# Smoke-test density, not measurement density - PLCSIM alone emits ~22 msg/s per stream, so a
# real run is likely hundreds to thousands of points. The measurement density gets chosen later
# from real data; override with PERF_POINTS_PER_RUN for that run, don't treat 10 as final.
POINTS_PER_RUN = int(os.environ.get("PERF_POINTS_PER_RUN", "10"))

GROUP_NAME = "HUB-106 Perf Test"
TEST_USER_NAME = "HUB-106 Perf Test"
TEST_USER_EMAIL = "hub106-perf-test@local.synthetic"
TEST_USER_COMPANY = "HUB-106 Perf Test"
ADMIN_ROLE_ID = 4  # confirmed live: the one real working local user has role_id 4 ('admin')

NOVAPI_HOST = os.environ.get("NOVAPI_DB_HOST", "127.0.0.1")
NOVAPI_PORT = os.environ.get("NOVAPI_DB_PORT", "5433")
NOVAPI_DB = os.environ.get("NOVAPI_DB_NAME", "swrdb_aggr")
NOVAPI_USER = os.environ.get("NOVAPI_DB_USER", "postgres")
NOVAPI_PASSWORD = os.environ.get("NOVAPI_DB_PASSWORD")
NOVAPI_REPO = os.environ.get("NOVAPI_REPO")

OPENSEARCH_URL = os.environ.get("OPENSEARCH_URL", "http://127.0.0.1:9200")
OPENSEARCH_INDEX = os.environ.get("OPENSEARCH_INDEX", "novhub-local")

BULK_CHUNK = 2000


def robot_ids():
    return list(range(ROBOT_ID_START, ROBOT_ID_START + ROBOT_COUNT))


def weld_hash(robot_id, job_id, part_id, serial_id, weld_id, run_id):
    fields = {
        "job_id": job_id, "part_id": part_id, "robot_id": robot_id,
        "run_id": run_id, "serial_id": serial_id, "weld_id": weld_id,
    }
    present = {k: str(v) for k, v in fields.items() if v not in (None, "", "<nil>")}
    if not present:
        source = "unknown_session"
    else:
        source = "|".join(present[k] for k in sorted(present))
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def bcrypt_hash(plaintext):
    if not NOVAPI_REPO:
        sys.exit("NOVAPI_REPO is not set - needed to reuse its own bcryptjs install")
    out = subprocess.run(
        ["node", "-e", "console.log(require('bcryptjs').hashSync(process.argv[1], 10))", plaintext],
        cwd=NOVAPI_REPO, capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def connect():
    if not NOVAPI_PASSWORD:
        sys.exit("NOVAPI_DB_PASSWORD is not set")
    return psycopg2.connect(
        host=NOVAPI_HOST, port=NOVAPI_PORT, dbname=NOVAPI_DB,
        user=NOVAPI_USER, password=NOVAPI_PASSWORD,
    )


def run_fields(robot_id, run_id):
    job_id = f"PERF-JOB-{robot_id}"
    part_id = f"PERF-PART-{run_id}"
    serial_id = f"PERF-SER-{run_id}"
    weld_id = str(run_id % 5 + 1)
    return job_id, part_id, serial_id, weld_id


def bulk_post(actions_and_docs):
    lines = []
    for action, doc in actions_and_docs:
        lines.append(json.dumps(action))
        lines.append(json.dumps(doc, default=str))
    body = "\n".join(lines) + "\n"
    resp = requests.post(
        f"{OPENSEARCH_URL}/_bulk", data=body.encode("utf-8"),
        headers={"Content-Type": "application/x-ndjson"}, timeout=60,
    )
    resp.raise_for_status()
    result = resp.json()
    if result.get("errors"):
        failed = [i for i in result["items"] if i.get("index", {}).get("status", 200) >= 300]
        sys.exit(f"FAILED: {len(failed)} OpenSearch bulk item(s) failed: {failed[:3]}")


def already_seeded(cur):
    cur.execute("SELECT id FROM groups WHERE name = %s", (GROUP_NAME,))
    return cur.fetchone() is not None


def seed():
    conn = connect()
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            if already_seeded(cur):
                print(f"already seeded: group '{GROUP_NAME}' exists - run `remove` first to reseed")
                return

            cur.execute(
                "INSERT INTO groups (name, group_type) VALUES (%s, 'customer') RETURNING id",
                (GROUP_NAME,),
            )
            group_id = cur.fetchone()[0]

            test_password = os.environ.get("PERF_TEST_PASSWORD") or secrets.token_urlsafe(12)
            password_hash = bcrypt_hash(test_password)
            cur.execute(
                "INSERT INTO users (name, email, password, company, activated) "
                "VALUES (%s, %s, %s, %s, true) RETURNING id",
                (TEST_USER_NAME, TEST_USER_EMAIL, password_hash, TEST_USER_COMPANY),
            )
            user_id = cur.fetchone()[0]

            cur.execute(
                "INSERT INTO role_resource (role_id, resource_id, resource_type) VALUES (%s, %s, 'users')",
                (ADMIN_ROLE_ID, user_id),
            )
            cur.execute(
                "INSERT INTO group_resource (group_id, resource_id, resource_type) VALUES (%s, %s, 'users')",
                (group_id, user_id),
            )

            preset_id_by_robot = {}
            for robot_id in robot_ids():
                cur.execute(
                    "INSERT INTO robot (id, name, customer, location, updated_at) "
                    "VALUES (%s, %s, %s, %s, now())",
                    (robot_id, f"PERF-TEST-{robot_id}", "HUB-106 Perf Test", "synthetic"),
                )
                cur.execute(
                    "INSERT INTO api_key (robot_id, secret_key, iam_access_key_id, iam_secret_access_key, activated) "
                    "VALUES (%s, 'synthetic-not-a-real-secret', 'synthetic-not-a-real-key', "
                    "'synthetic-not-a-real-key', true)",
                    (robot_id,),
                )
                cur.execute(
                    "INSERT INTO group_resource (group_id, resource_id, resource_type) VALUES (%s, %s, 'robot')",
                    (group_id, robot_id),
                )
                settings = {
                    "ignore": {"min": 0, "max": 2},
                    "voltage": {"min": 10, "max": 30, "warning_min": 12, "warning_max": 28,
                                "critical_min": 10, "critical_max": 30},
                    "amperage": {"min": 50, "max": 300, "warning_min": 60, "warning_max": 280,
                                 "critical_min": 50, "critical_max": 300},
                    "travel_speed": {"min": 1, "max": 20, "warning_min": 2, "warning_max": 18,
                                     "critical_min": 1, "critical_max": 20},
                    "wfs": {"min": 50, "max": 500, "warning_min": 60, "warning_max": 480,
                            "critical_min": 50, "critical_max": 500},
                }
                cur.execute(
                    "INSERT INTO weld_monitoring_presets (robot_id, user_id, procedure, settings) "
                    "VALUES (%s, %s, %s, %s) RETURNING id",
                    (robot_id, user_id, "HUB-106 Perf Test preset", json.dumps(settings)),
                )
                preset_id_by_robot[robot_id] = cur.fetchone()[0]
            conn.commit()
            print(f"created: group '{GROUP_NAME}' (id {group_id}), user '{TEST_USER_EMAIL}' "
                  f"(id {user_id}), {ROBOT_COUNT} robots ({ROBOT_ID_START}-{ROBOT_ID_START + ROBOT_COUNT - 1})")
            secrets_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state", "secrets")
            os.makedirs(secrets_dir, mode=0o700, exist_ok=True)
            secret_path = os.path.join(secrets_dir, "perf-test-user.secret")
            with open(secret_path, "w") as f:
                f.write(f"{TEST_USER_EMAIL}:{test_password}\n")
            os.chmod(secret_path, 0o600)
            print(f"created: {secret_path} (0600) - test login credentials, local only, never printed again")

            report_rows = []
            assoc_rows = []
            os_actions = []
            total_runs = 0
            total_points = 0
            for robot_id in robot_ids():
                for run_id in range(1, RUNS_PER_ROBOT + 1):
                    job_id, part_id, serial_id, weld_id = run_fields(robot_id, run_id)
                    test_status = ["pass", "fail", None][run_id % 3]
                    report_rows.append((
                        user_id, robot_id, job_id, part_id, weld_id, run_id, test_status, run_id,
                    ))
                    h = weld_hash(robot_id, job_id, part_id, serial_id, weld_id, run_id)
                    assoc_rows.append((h, robot_id, run_id, preset_id_by_robot[robot_id]))

                    doc_id = f"{robot_id}_{run_id}_run"
                    run_doc = {
                        "run_id": run_id,
                        "robot": {"robot_id": robot_id},
                        "@timestamp": f"2026-01-01T00:00:00Z",
                        "weld_session": {
                            "job_id": job_id, "part_id": part_id,
                            "serial_id": serial_id, "weld_id": weld_id,
                        },
                        "weld_summary": {
                            "arc_on_utc": "2026-01-01T00:00:00Z",
                            "arc_off_utc": "2026-01-01T00:05:00Z",
                            "travelled_distance": 123.4,
                        },
                    }
                    os_actions.append(({"index": {"_index": OPENSEARCH_INDEX, "_id": doc_id}}, run_doc))

                    files_doc = {
                        "run_id": run_id, "robot": {"robot_id": robot_id},
                        "files": [
                            {"category": "noveye/captures", "path": f"/synthetic/{robot_id}/{run_id}/capture.mp4"},
                            {"category": "novdata/logs", "path": f"/synthetic/{robot_id}/{run_id}/log.tsv"},
                        ],
                    }
                    files_id = f"{robot_id}_{run_id}_files"
                    os_actions.append(({"index": {"_index": OPENSEARCH_INDEX, "_id": files_id}}, files_doc))

                    for p in range(POINTS_PER_RUN):
                        point_doc = {
                            "run_id": run_id, "robot": {"robot_id": robot_id},
                            "arc_time": p * 1.0, "live_voltage": 24.5, "live_amps": 180.0,
                            "live_wfs": 300.0, "live_travel_speed": 8.5,
                            "live_weave_frequency": 2.0, "live_weave_amplitude": 3.0,
                            "autonomy_root_opening_mm": 1.2,
                        }
                        point_id = f"{robot_id}_{run_id}_{p}"
                        os_actions.append(({"index": {"_index": OPENSEARCH_INDEX, "_id": point_id}}, point_doc))
                        total_points += 1
                    total_runs += 1

                    if len(os_actions) >= BULK_CHUNK:
                        bulk_post(os_actions)
                        os_actions = []
                    if len(report_rows) >= BULK_CHUNK:
                        psycopg2.extras.execute_values(
                            cur,
                            "INSERT INTO weld_test_reports "
                            "(user_id, robot_id, work_order_ref, spool_ref, welder_id_ref, run_number, test_status, weld_run_id) "
                            "VALUES %s",
                            report_rows,
                        )
                        psycopg2.extras.execute_values(
                            cur,
                            "INSERT INTO weld_presets_associations "
                            "(weld_hash, robot_id, run_id, weld_monitoring_preset_id) VALUES %s",
                            assoc_rows,
                        )
                        conn.commit()
                        report_rows = []
                        assoc_rows = []

            if os_actions:
                bulk_post(os_actions)
            if report_rows:
                with conn.cursor() as cur2:
                    psycopg2.extras.execute_values(
                        cur2,
                        "INSERT INTO weld_test_reports "
                        "(user_id, robot_id, work_order_ref, spool_ref, welder_id_ref, run_number, test_status, weld_run_id) "
                        "VALUES %s",
                        report_rows,
                    )
                    psycopg2.extras.execute_values(
                        cur2,
                        "INSERT INTO weld_presets_associations "
                        "(weld_hash, robot_id, run_id, weld_monitoring_preset_id) VALUES %s",
                        assoc_rows,
                    )
                conn.commit()

            print(f"created: {total_runs} weld_test_reports rows, {total_runs} weld_presets_associations rows, "
                  f"{total_runs} OpenSearch run-summary docs, {total_runs} OpenSearch files docs, "
                  f"{total_points} OpenSearch per-point docs (points_per_run={POINTS_PER_RUN})")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def remove():
    conn = connect()
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM groups WHERE name = %s", (GROUP_NAME,))
            row = cur.fetchone()
            if row is None:
                print(f"already removed: no group named '{GROUP_NAME}' found - nothing to do")
                return
            group_id = row[0]

            cur.execute("SELECT id FROM users WHERE email = %s", (TEST_USER_EMAIL,))
            user_row = cur.fetchone()
            user_id = user_row[0] if user_row else None

            ids = tuple(robot_ids())
            cur.execute("DELETE FROM weld_presets_associations WHERE robot_id IN %s", (ids,))
            assoc_deleted = cur.rowcount
            cur.execute("DELETE FROM weld_test_reports WHERE robot_id IN %s", (ids,))
            reports_deleted = cur.rowcount
            cur.execute("DELETE FROM weld_monitoring_presets WHERE robot_id IN %s", (ids,))
            cur.execute("DELETE FROM api_key WHERE robot_id IN %s", (ids,))
            cur.execute("DELETE FROM group_resource WHERE group_id = %s", (group_id,))
            if user_id is not None:
                cur.execute("DELETE FROM role_resource WHERE resource_id = %s AND resource_type = 'users'", (user_id,))
            cur.execute("DELETE FROM robot WHERE id IN %s", (ids,))
            robots_deleted = cur.rowcount
            if user_id is not None:
                cur.execute("DELETE FROM users WHERE id = %s", (user_id,))
            cur.execute("DELETE FROM groups WHERE id = %s", (group_id,))
            conn.commit()
            print(f"removed: {robots_deleted} robots, 1 user, group '{GROUP_NAME}', "
                  f"{reports_deleted} weld_test_reports rows, {assoc_deleted} weld_presets_associations rows")

        min_id = min(robot_ids())
        max_id = max(robot_ids())
        del_query = {"query": {"range": {"robot.robot_id": {"gte": min_id, "lte": max_id}}}}
        resp = requests.post(
            f"{OPENSEARCH_URL}/{OPENSEARCH_INDEX}/_delete_by_query",
            data=json.dumps(del_query), headers={"Content-Type": "application/json"}, timeout=120,
        )
        resp.raise_for_status()
        deleted = resp.json().get("deleted", 0)
        print(f"removed: {deleted} OpenSearch documents (robot.robot_id {min_id}-{max_id})")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["seed", "remove"])
    args = parser.parse_args()
    if args.action == "seed":
        seed()
    else:
        remove()

import copy
import importlib.util
import json
import os
import random
import stat
import sys
import tempfile
import unittest
from argparse import Namespace
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

import psycopg2


SCRIPT_DIR = Path(__file__).resolve().parents[1]
os.environ.update({
    "CLOUD_INGEST_ENV": "dev",
    "CLOUD_INGEST_SECRETS_DIR": "/tmp/cloud-ingest-test-secrets",
    "CLOUD_INGEST_DB_LOCAL_PORT": "25432",
    "CLOUD_INGEST_ES_LOOPBACK": "127.0.0.1",
    "CLOUD_INGEST_AWS_REGION": "us-west-2",
    "CLOUD_INGEST_AWS_PROFILE": "test-profile",
    "CLOUD_INGEST_ROBOT_ID": "1555",
    "CLOUD_INGEST_INGESTER_REPO": "/tmp/cloud-ingest-test-ingester",
    "CLOUD_INGEST_RANK_SCRIPT": "/tmp/cloud-ingest-test-rank",
    "CLOUD_INGEST_LOG_DIR": "/tmp/cloud-ingest-test-logs",
})
sys.path.insert(0, str(SCRIPT_DIR))
spec = importlib.util.spec_from_file_location("cloud_ingest", SCRIPT_DIR / "cloud-ingest.py")
cloud_ingest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud_ingest)


FEEDBACK_TYPES = {
    "autonomy_dist_x_raw": "i16",
    "autonomy_dist_y_raw": "i16",
    "camera_temp": "f32",
    "live_amps": "f32",
    "live_travel_speed": "f32",
    "live_trim": "f32",
    "live_voltage": "f32",
    "live_weave_amplitude": "f32",
    "live_weave_frequency": "f32",
    "live_wfs": "i16",
    "max_gap_measurement": "f32",
    "prescan_gap_measurement": "f32",
}
SCHEMA = {
    "arc_time": "u32",
    "plc_time": "u64",
    "timestamp": "String",
    **FEEDBACK_TYPES,
    "job_id": "String",
}


def empty_audit_state():
    return {
        "opensearch_counts": {},
        "opensearch_unkeyed_docs": 0,
        "postgres_counts": {},
    }


def complete_audit_state(run_count):
    run_ids = range(
        cloud_ingest.RUN_ID_BASE + 1,
        cloud_ingest.RUN_ID_BASE + run_count + 1,
    )
    return {
        "opensearch_counts": {
            run_id: cloud_ingest.POINTS_PER_RUN + 1 for run_id in run_ids
        },
        "opensearch_unkeyed_docs": 0,
        "postgres_counts": {
            run_id: 1 for run_id in range(
                cloud_ingest.RUN_ID_BASE + 1,
                cloud_ingest.RUN_ID_BASE + run_count + 1,
            )
        },
    }


class FakeResponse:
    def __init__(self, payload, ok=True, status_code=200, text=""):
        self.payload = payload
        self.ok = ok
        self.status_code = status_code
        self.text = text

    def json(self):
        return self.payload


class FakeCursor:
    def __init__(self, rows):
        self.rows = rows
        self.query = None
        self.params = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def execute(self, query, params):
        self.query = query
        self.params = params

    def fetchall(self):
        return self.rows


class FakeConnection:
    def __init__(self, rows):
        self.fake_cursor = FakeCursor(rows)
        self.closed = False

    def cursor(self):
        return self.fake_cursor

    def close(self):
        self.closed = True


def make_template():
    rows = []
    for row_index in range(2):
        values = []
        for field, value_type in SCHEMA.items():
            if field == "arc_time":
                value = 97000 + row_index * 10
            elif field == "plc_time":
                value = 21000000 + row_index * 10
            elif field == "timestamp":
                value = f"2026-01-01T12:00:00.{row_index * 10:03d}Z"
            elif field == "job_id":
                value = "NA"
            elif value_type == "i16":
                value = 0
            else:
                value = 0.0
            values.append(value)
        rows.append(values)
    return {
        "version": "2.3",
        "schema": SCHEMA.copy(),
        "values": rows,
        "weld_summary": {"operator_name": "test-operator"},
    }


class CloudIngestTemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.range_map = cloud_ingest.load_range_map()

    def test_build_varied_template_uses_ranges_and_preserves_structure(self):
        original = make_template()
        original_copy = copy.deepcopy(original)
        result = cloud_ingest.build_varied_template(
            original, self.range_map, row_count=50, rng=random.Random(7)
        )

        self.assertEqual(original, original_copy)
        self.assertEqual(result["schema"], original["schema"])
        self.assertEqual(result["weld_summary"], original["weld_summary"])
        self.assertEqual(len(result["values"]), 50)

        field_indexes = {field: index for index, field in enumerate(SCHEMA)}
        for field, value_type in FEEDBACK_TYPES.items():
            entry = self.range_map[field]
            low, high = cloud_ingest.numeric_bounds(entry["Probable Range"], field)
            values = [row[field_indexes[field]] for row in result["values"]]
            self.assertGreaterEqual(min(values), low)
            self.assertLessEqual(max(values), high)
            self.assertGreater(len(set(values)), 1)
            if value_type == "i16":
                self.assertTrue(all(type(value) is int for value in values))
            else:
                self.assertTrue(all(type(value) is float for value in values))

        arc_times = [row[field_indexes["arc_time"]] for row in result["values"]]
        plc_times = [row[field_indexes["plc_time"]] for row in result["values"]]
        self.assertEqual(arc_times, [97000 + 10 * index for index in range(50)])
        self.assertEqual(plc_times, [21000000 + 10 * index for index in range(50)])

        timestamps = [
            datetime.fromisoformat(row[field_indexes["timestamp"]].replace("Z", "+00:00"))
            for row in result["values"]
        ]
        self.assertEqual(
            [int((value - timestamps[0]).total_seconds() * 1000) for value in timestamps],
            [10 * index for index in range(50)],
        )
        self.assertEqual({row[field_indexes["job_id"]] for row in result["values"]}, {"NA"})

    def test_missing_or_malformed_feedback_ranges_fail(self):
        missing_range = self.range_map.copy()
        del missing_range["live_amps"]
        with self.assertRaisesRegex(ValueError, "live_amps"):
            cloud_ingest.build_varied_template(make_template(), missing_range, rng=random.Random(1))

        malformed_range = self.range_map.copy()
        malformed_range["live_amps"] = dict(malformed_range["live_amps"])
        malformed_range["live_amps"]["Probable Range"] = "unknown"
        with self.assertRaisesRegex(ValueError, "live_amps"):
            cloud_ingest.build_varied_template(make_template(), malformed_range, rng=random.Random(1))

    def test_incompatible_schema_type_fails(self):
        template = make_template()
        template["schema"]["live_wfs"] = "f32"
        with self.assertRaisesRegex(ValueError, "live_wfs"):
            cloud_ingest.build_varied_template(template, self.range_map, rng=random.Random(1))

    def test_time_sequence_cannot_overflow_unsigned_schema_type(self):
        template = make_template()
        arc_time_index = list(SCHEMA).index("arc_time")
        template["values"][0][arc_time_index] = (1 << 32) - 5
        with self.assertRaisesRegex(ValueError, "arc_time"):
            cloud_ingest.build_varied_template(template, self.range_map, rng=random.Random(1))

    def test_private_template_is_owner_only(self):
        template = cloud_ingest.build_varied_template(
            make_template(), self.range_map, rng=random.Random(7)
        )
        with tempfile.TemporaryDirectory() as directory:
            path = cloud_ingest.write_private_template(template, directory)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            with open(path, encoding="utf-8") as file:
                self.assertEqual(len(json.load(file)["values"]), 50)

    def test_dry_run_does_not_transform_template(self):
        args = Namespace(probe=False, runs=1, dry_run=True, template=None)
        with (
            patch.object(cloud_ingest, "current_total", return_value=100),
            patch.object(cloud_ingest, "audit_synthetic_state", return_value=empty_audit_state()),
            patch.object(cloud_ingest, "print_plan"),
            patch.object(cloud_ingest, "build_varied_template") as transform,
            patch.object(cloud_ingest, "run_ingester_tee_scrubbed") as run_ingester,
        ):
            cloud_ingest.do_ingest(args, None, "index", None)
        transform.assert_not_called()
        run_ingester.assert_not_called()

    def test_partial_synthetic_data_stops_before_ingester(self):
        args = Namespace(probe=False, runs=1, dry_run=False, template="unused.json")
        partial_state = {
            "opensearch_counts": {cloud_ingest.RUN_ID_BASE + 1: 50},
            "opensearch_unkeyed_docs": 0,
            "postgres_counts": {},
        }
        with (
            patch.object(cloud_ingest, "current_total", return_value=100),
            patch.object(cloud_ingest, "audit_synthetic_state", return_value=partial_state),
            patch.object(cloud_ingest, "build_varied_template") as transform,
            patch.object(cloud_ingest, "run_ingester_tee_scrubbed") as run_ingester,
        ):
            with self.assertRaisesRegex(SystemExit, "partial or conflicting"):
                cloud_ingest.do_ingest(args, None, "index", None)
        transform.assert_not_called()
        run_ingester.assert_not_called()

    def test_complete_batch_is_verified_noop_before_template_generation(self):
        args = Namespace(probe=False, runs=1, dry_run=False, template="unused.json")
        with (
            patch.object(cloud_ingest, "current_total", return_value=100),
            patch.object(cloud_ingest, "audit_synthetic_state",
                         return_value=complete_audit_state(1)),
            patch.object(cloud_ingest, "print_plan") as print_plan,
            patch.object(cloud_ingest, "build_varied_template") as transform,
            patch.object(cloud_ingest, "run_ingester_tee_scrubbed") as run_ingester,
        ):
            cloud_ingest.do_ingest(args, None, "index", None)
        print_plan.assert_not_called()
        transform.assert_not_called()
        run_ingester.assert_not_called()

    def test_empty_batch_is_ingested_and_post_audit_is_required(self):
        args = Namespace(probe=False, runs=1, dry_run=False, template="sample.json")
        states = [empty_audit_state(), complete_audit_state(1)]
        with (
            patch.object(cloud_ingest, "current_total", side_effect=[100, 101]),
            patch.object(cloud_ingest, "audit_synthetic_state", side_effect=states),
            patch.object(cloud_ingest, "read_json_file", return_value=make_template()),
            patch.object(cloud_ingest, "load_range_map", return_value=self.range_map),
            patch.object(cloud_ingest, "build_varied_template", return_value=make_template()),
            patch.object(cloud_ingest, "raw_robot_doc_count", return_value=1000),
            patch.object(cloud_ingest, "wait_for_expected_doc_count", return_value=1051),
            patch.object(cloud_ingest, "run_ingester_tee_scrubbed",
                         return_value=(0, "test-log")) as run_ingester,
        ):
            cloud_ingest.do_ingest(args, "example", "index", {
                "name": "test-db", "username": "test-user", "password": "test-password",
            })
        run_ingester.assert_called_once()

    def test_post_ingest_audit_mismatch_returns_failure(self):
        args = Namespace(probe=False, runs=1, dry_run=False, template="sample.json")
        partial_state = {
            "opensearch_counts": {cloud_ingest.RUN_ID_BASE + 1: 50},
            "opensearch_unkeyed_docs": 0,
            "postgres_counts": {cloud_ingest.RUN_ID_BASE + 1: 1},
        }
        with (
            patch.object(cloud_ingest, "current_total", side_effect=[100, 101]),
            patch.object(cloud_ingest, "audit_synthetic_state",
                         side_effect=[empty_audit_state(), partial_state]),
            patch.object(cloud_ingest, "read_json_file", return_value=make_template()),
            patch.object(cloud_ingest, "load_range_map", return_value=self.range_map),
            patch.object(cloud_ingest, "build_varied_template", return_value=make_template()),
            patch.object(cloud_ingest, "raw_robot_doc_count", return_value=1000),
            patch.object(cloud_ingest, "wait_for_expected_doc_count", return_value=1051),
            patch.object(cloud_ingest, "run_ingester_tee_scrubbed",
                         return_value=(0, "test-log")) as run_ingester,
        ):
            with self.assertRaisesRegex(SystemExit, "Verification failed"):
                cloud_ingest.do_ingest(args, "example", "index", {
                    "name": "test-db", "username": "test-user", "password": "test-password",
                })
        run_ingester.assert_called_once()


class CloudIngestAuditTests(unittest.TestCase):
    def mapping(self, run_id_type="long", job_id_mapping=None):
        if job_id_mapping is None:
            job_id_mapping = {"type": "keyword"}
        return {
            "synthetic-index": {
                "mappings": {
                    "properties": {
                        "run_id": {"type": run_id_type},
                        "weld_session": {
                            "properties": {"job_id": job_id_mapping},
                        },
                    },
                },
            },
        }

    def test_resolves_numeric_run_id_and_text_keyword_job_id(self):
        mapping = self.mapping(
            job_id_mapping={
                "type": "text",
                "fields": {"keyword": {"type": "keyword"}},
            }
        )
        self.assertEqual(
            cloud_ingest.resolve_audit_fields(mapping),
            ("run_id", "weld_session.job_id.keyword"),
        )

    def test_mapping_rejects_missing_and_inconsistent_fields(self):
        missing = self.mapping()
        del missing["synthetic-index"]["mappings"]["properties"]["run_id"]
        with self.assertRaisesRegex(ValueError, "missing field run_id"):
            cloud_ingest.resolve_audit_fields(missing)

        inconsistent = self.mapping()
        inconsistent["second-index"] = self.mapping("keyword")["synthetic-index"]
        with self.assertRaisesRegex(ValueError, "mappings disagree"):
            cloud_ingest.resolve_audit_fields(inconsistent)

    def test_automatic_audit_uses_mapping_and_groups_both_stores(self):
        search_response = {
            "timed_out": False,
            "_shards": {"failed": 0},
            "aggregations": {
                "runs": {
                    "buckets": [{"key": cloud_ingest.RUN_ID_BASE + 1, "doc_count": 51}],
                    "sum_other_doc_count": 0,
                },
                "missing_run_id": {"doc_count": 0},
            },
        }
        connection = FakeConnection([(cloud_ingest.RUN_ID_BASE + 1, 1)])
        with (
            patch.object(
                cloud_ingest,
                "sigv4_request",
                side_effect=[
                    (FakeResponse(self.mapping()), None),
                    (FakeResponse(search_response), None),
                ],
            ) as request,
            patch.object(cloud_ingest, "pg_connect", return_value=connection),
        ):
            state = cloud_ingest.audit_synthetic_state("example", "synthetic-index", {})

        self.assertEqual(state, complete_audit_state(1))
        self.assertEqual(request.call_args_list[0].args[0], "GET")
        self.assertEqual(request.call_args_list[0].args[3], "/synthetic-index/_mapping")
        self.assertEqual(request.call_args_list[1].args[3], "/synthetic-index/_search")
        search_body = json.loads(request.call_args_list[1].kwargs["data"])
        self.assertEqual(
            search_body["query"]["term"],
            {"weld_session.job_id": "PERF-ING-JOB-1555"},
        )
        self.assertEqual(
            search_body["aggs"]["runs"]["terms"]["field"],
            "run_id",
        )
        self.assertEqual(connection.fake_cursor.params, (1555, cloud_ingest.RUN_ID_BASE))
        self.assertTrue(connection.closed)

    def test_mapping_store_error_stops_before_postgres(self):
        with (
            patch.object(cloud_ingest, "signed_opensearch_json",
                         side_effect=ValueError("mapping unavailable")),
            patch.object(cloud_ingest, "postgres_run_counts") as postgres_counts,
        ):
            with self.assertRaisesRegex(ValueError, "mapping unavailable"):
                cloud_ingest.audit_synthetic_state("example", "index", {})
        postgres_counts.assert_not_called()

    def test_postgres_connection_error_is_reported(self):
        with patch.object(
            cloud_ingest, "pg_connect", side_effect=psycopg2.OperationalError("database unavailable")
        ):
            with self.assertRaisesRegex(ValueError, "Postgres synthetic-run audit failed"):
                cloud_ingest.postgres_run_counts({})

    def test_audit_reports_missing_extra_and_wrong_multiplicities(self):
        first_id = cloud_ingest.RUN_ID_BASE + 1
        second_id = cloud_ingest.RUN_ID_BASE + 2
        third_id = cloud_ingest.RUN_ID_BASE + 3
        state = {
            "opensearch_counts": {first_id: 50, second_id: 51},
            "opensearch_unkeyed_docs": 0,
            "postgres_counts": {first_id: 1, third_id: 2},
        }
        issues = cloud_ingest.audit_issues(state, {first_id})
        report = "; ".join(issues)
        self.assertIn(f"OpenSearch has unexpected run IDs: {second_id}", report)
        self.assertIn(f"Postgres has unexpected run IDs: {third_id}", report)
        self.assertIn(f"OpenSearch run {first_id} has 50 documents", report)
        self.assertIn(f"Postgres run {third_id} has 2 association rows", report)

        missing_state = {
            "opensearch_counts": {first_id: 51},
            "opensearch_unkeyed_docs": 0,
            "postgres_counts": {first_id: 1},
        }
        self.assertTrue(
            any("OpenSearch is missing run IDs" in issue
                for issue in cloud_ingest.audit_issues(missing_state, {first_id, second_id}))
        )
        self.assertTrue(
            any("Postgres is missing run IDs" in issue
                for issue in cloud_ingest.audit_issues(missing_state, {first_id, second_id}))
        )

        duplicate_state = {
            "opensearch_counts": {first_id: 102},
            "opensearch_unkeyed_docs": 0,
            "postgres_counts": {first_id: 1},
        }
        self.assertIn(
            f"OpenSearch run {first_id} has 102 documents",
            "; ".join(cloud_ingest.audit_issues(duplicate_state, {first_id})),
        )


if __name__ == "__main__":
    unittest.main()

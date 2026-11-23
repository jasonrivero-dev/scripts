import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STEP_FILE = ROOT / "novhub-local-stack" / "steps" / "cloud_local.sh"


class CloudLocalTests(unittest.TestCase):
    def run_shell(self, script, extra_env=None):
        env = os.environ.copy()
        env["CLOUD_LOCAL_STEP_FILE"] = str(STEP_FILE)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", "-c", script],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_runtime_environment_is_private_and_quotes_secret_values(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            novhub = root / "novhub"
            novapi = root / "NovApi"
            novapi.mkdir()
            db_init = novapi / "db_init.sql"
            db_init.write_text("SELECT 1;\n", encoding="utf-8")
            env = {
                "NOVHUB_ROOT": str(novhub),
                "NOVAPI_REPO": str(novapi),
                "CLOUD_LOCAL_DB_NAME": "dev-db",
                "CLOUD_LOCAL_DB_USERNAME": "test-user",
                "CLOUD_LOCAL_DB_PASSWORD": "test password#value",
                "CLOUD_LOCAL_DB_LOCAL_PORT": "25432",
                "CLOUD_LOCAL_ES_HOST": "dev.example.invalid",
                "CLOUD_LOCAL_ES_INDEX": "weld-data-stream",
                "CLOUD_LOCAL_S3_BUCKET_NAME": "test-robot-data-bucket",
                "CLOUD_LOCAL_JWT_SECRET": "test-jwt-secret",
            }
            result = self.run_shell(
                'source "$CLOUD_LOCAL_STEP_FILE"\ncloud_local_write_runtime_env',
                env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            runtime_dir = novhub / ".state" / "cloud-local" / "novapi-runtime"
            runtime_env = runtime_dir / ".env"
            self.assertEqual(stat.S_IMODE(runtime_env.stat().st_mode), 0o600)
            self.assertEqual((runtime_dir / "db_init.sql").resolve(), db_init)
            content = runtime_env.read_text(encoding="utf-8")
            self.assertIn("DB_PASSWORD='test password#value'\n", content)
            self.assertIn("DB_HOST=127.0.0.1\n", content)
            self.assertIn("DB_PORT=25432\n", content)
            self.assertIn("OPENSEARCH_HOST=https://dev.example.invalid\n", content)
            self.assertIn("S3_BUCKET_NAME=test-robot-data-bucket\n", content)
            self.assertIn("JWT_SECRET=test-jwt-secret\n", content)
            self.assertIn("JWT_USER_TOKEN_EXPIRATION=1d\n", content)
            self.assertNotIn("AWS_ACCESS_KEY_ID", content)
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", content)
            self.assertNotIn("test-jwt-secret", result.stdout + result.stderr)

    def test_start_requires_preflight_before_starting_either_service(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            calls = Path(temp_dir) / "calls"
            result = self.run_shell(
                r'''
set -euo pipefail
source "$CLOUD_LOCAL_STEP_FILE"
log() { :; }
error() { :; }
warn() { :; }
is_running() { return 1; }
listening_on_address() { return 1; }
cloud_local_preflight() {
  printf 'preflight\n' >> "$CALLS"
  return 1
}
start_background() {
  printf 'start:%s\n' "$1" >> "$CALLS"
}
if cloud_local_start dev; then
  exit 1
fi
''',
                {
                    "NOVHUB_ROOT": temp_dir,
                    "CALLS": str(calls),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.read_text(encoding="utf-8"), "preflight\n")

    def test_start_uses_separate_managed_processes_after_preflight(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            calls = Path(temp_dir) / "calls"
            result = self.run_shell(
                r'''
set -euo pipefail
source "$CLOUD_LOCAL_STEP_FILE"
log() { :; }
error() { printf '%s\n' "$*" >&2; }
warn() { :; }
_cloud_local_is_running() {
  grep -Fqx "start:$1" "$CALLS"
}
listening_on_address() { return 1; }
cloud_local_preflight() {
  printf 'preflight\n' >> "$CALLS"
}
start_background() {
  printf 'start:%s\n' "$1" >> "$CALLS"
  shift
  printf 'args:%s\n' "$*" >> "$CALLS"
}
wait_for_port() { :; }
_cloud_local_wait_for_api() { :; }
cloud_local_start dev
''',
                {
                    "NOVHUB_ROOT": temp_dir,
                    "CALLS": str(calls),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            content = calls.read_text(encoding="utf-8")
            self.assertLess(content.index("preflight"), content.index("start:cloud-local-novapi"))
            self.assertLess(content.index("start:cloud-local-novapi"), content.index("start:cloud-local-novapp"))
            self.assertIn("AWS_PROFILE=novai-dev", content)
            self.assertIn("VITE_SERVER_URL=http://localhost:3000", content)
            self.assertNotIn("--envDir", content)


if __name__ == "__main__":
    unittest.main()

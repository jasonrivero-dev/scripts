#!/usr/bin/env python3
"""HUB-106: read-only credential check for dev/test, through cloud-tunnel.sh's tunnels. Tries
DB (SELECT 1 + robot count) and OpenSearch both ways NovApi might reach it - basic auth from
the secrets file, and AWS SigV4 via the default credential chain - and reports which works.
Never prints a secret value, only pass/fail, counts, and key NAMES on a missing-key error.
"""
import fnmatch
import json
import os
import sys

import psycopg2
import requests

# cloud_common silences urllib3's InsecureRequestWarning globally on import (see its own
# comment for why verify=False is correct here) - importing it before any request() call,
# as below, is what makes that take effect for this file's own requests too.
from cloud_common import (
    normalize_host, read_kv, require, reduce_arn, scrub_arns, sso_login_hint,
    sigv4_sign, get_caller_identity,
)

ENV = os.environ.get("CLOUD_CHECK_ENV")
DB_LOCAL_PORT = os.environ.get("CLOUD_CHECK_DB_LOCAL_PORT")
ES_LOCAL_PORT = os.environ.get("CLOUD_CHECK_ES_LOCAL_PORT")
SECRETS_DIR = os.environ.get("CLOUD_CHECK_SECRETS_DIR")
VIA_HOSTNAME = os.environ.get("CLOUD_CHECK_VIA_HOSTNAME") == "1"

if not all([ENV, DB_LOCAL_PORT, ES_LOCAL_PORT, SECRETS_DIR]):
    sys.exit("missing env vars - run this via cloud-check.sh, not directly")


def check_db():
    path = os.path.join(SECRETS_DIR, "DB.secrets")
    if not os.path.exists(path):
        return {"ok": False, "error": f"missing: {path}"}
    kv = read_kv(path)
    require(kv, ["host", "name", "username", "password"], path)
    try:
        conn = psycopg2.connect(
            host="127.0.0.1", port=DB_LOCAL_PORT, dbname=kv["name"],
            user=kv["username"], password=kv["password"], connect_timeout=10, sslmode="require",
        )
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
                cur.execute("SELECT COUNT(*) FROM robot")
                count = cur.fetchone()[0]
            return {"ok": True, "robot_count": count}
        finally:
            conn.close()
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def es_base_url(es_host):
    if VIA_HOSTNAME:
        return f"https://{es_host}:{ES_LOCAL_PORT}"
    return f"https://127.0.0.1:{ES_LOCAL_PORT}"


def describe_failed(label, resp):
    """AWS/OpenSearch error bodies are plain diagnostic JSON (type, message) - they never
    echo back credentials, so it's safe to show verbatim once any embedded ARN is reduced.
    This is what lets the owner tell a 403 "identity not allowed by the domain's access
    policy" (body names the denied action, e.g. "is not authorized to perform") apart from a
    signature problem (body says something like "SignatureDoesNotMatch" / "does not match") -
    this script doesn't guess which one it is, it just shows AWS's own message."""
    body = scrub_arns(resp.text.strip())
    if len(body) > 500:
        body = body[:500] + "...(truncated)"
    return f"{label}={resp.status_code} body={body}"


def check_opensearch_basic(kv, es_host):
    require(kv, ["username", "password", "index"], "OPENSEARCH.secrets")
    base = es_base_url(es_host)
    headers = {} if VIA_HOSTNAME else {"Host": es_host}
    try:
        health = requests.get(f"{base}/_cluster/health", auth=(kv["username"], kv["password"]),
                               headers=headers, timeout=15, verify=False)
        count = requests.get(f"{base}/{kv['index']}/_count", auth=(kv["username"], kv["password"]),
                              headers=headers, timeout=15, verify=False)
        if health.ok and count.ok:
            return {"ok": True, "cluster_status": health.json().get("status"),
                     "index_count": count.json().get("count")}
        parts = [describe_failed("health", health)] if not health.ok else []
        parts += [describe_failed("count", count)] if not count.ok else []
        return {"ok": False, "error": "; ".join(parts)}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def check_opensearch_sigv4(kv, es_host):
    require(kv, ["index"], "OPENSEARCH.secrets")
    region = os.environ.get("CLOUD_CHECK_AWS_REGION")
    profile = os.environ.get("CLOUD_CHECK_AWS_PROFILE")
    if not region:
        return {"ok": False, "error": "CLOUD_CHECK_AWS_REGION is not set - run via cloud-check.sh, not directly"}
    if not profile:
        return {"ok": False, "error": "CLOUD_CHECK_AWS_PROFILE is not set - run via cloud-check.sh, not directly"}

    caller_identity, identity_err = get_caller_identity(region, profile)
    base_result = {"caller_identity": caller_identity}
    if identity_err:
        base_result["caller_identity_error"] = identity_err

    base = es_base_url(es_host)
    try:
        results = {}
        for label, path in [("health", "/_cluster/health"), ("count", f"/{kv['index']}/_count")]:
            sign_url = f"https://{es_host}{path}"
            signed_headers, err = sigv4_sign("GET", sign_url, region, profile, {"Host": es_host})
            if err:
                return {**base_result, "ok": False, "error": err}
            resp = requests.get(f"{base}{path}", headers=signed_headers, timeout=15, verify=False)
            results[label] = resp
        if results["health"].ok and results["count"].ok:
            return {**base_result, "ok": True, "cluster_status": results["health"].json().get("status"),
                     "index_count": results["count"].json().get("count")}
        parts = [describe_failed(l, r) for l, r in results.items() if not r.ok]
        return {**base_result, "ok": False, "error": "; ".join(parts)}
    except Exception as e:
        return {**base_result, "ok": False, "error": f"{type(e).__name__}: {e}{sso_login_hint(e, profile)}"}


SECURITY_CHECK_ROLE = "opensearch-API-role"


def check_security_admin(kv, es_host):
    """Whether the basic-auth login can administer the security plugin: GET rolesmapping and
    GET roles for SECURITY_CHECK_ROLE. Reports status/success, the role NAMES found in the
    mapping (the dict's own top-level keys - just a name, not a value), and the NUMBER of
    backend roles - never the backend roles' ARNs themselves."""
    require(kv, ["username", "password"], "OPENSEARCH.secrets")
    base = es_base_url(es_host)
    headers = {} if VIA_HOSTNAME else {"Host": es_host}
    auth = (kv["username"], kv["password"])
    try:
        mapping = requests.get(f"{base}/_plugins/_security/api/rolesmapping/{SECURITY_CHECK_ROLE}",
                                auth=auth, headers=headers, timeout=15, verify=False)
        roles = requests.get(f"{base}/_plugins/_security/api/roles/{SECURITY_CHECK_ROLE}",
                              auth=auth, headers=headers, timeout=15, verify=False)
        result = {"rolesmapping_status": mapping.status_code, "roles_status": roles.status_code,
                   "ok": mapping.ok and roles.ok}
        errors = []
        if mapping.ok:
            body = mapping.json()
            result["role_names_found"] = sorted(body.keys())
            backend_roles = body.get(SECURITY_CHECK_ROLE, {}).get("backend_roles", [])
            result["backend_role_count"] = len(backend_roles)
        else:
            errors.append(describe_failed("rolesmapping", mapping))
        if not roles.ok:
            errors.append(describe_failed("roles", roles))
        if errors:
            result["error"] = "; ".join(errors)
        return result
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


WRITE_ACTION_HINTS = ("write", "crud", "delete", "index", "bulk", "update", "*")


def _looks_like_write(action):
    """Heuristic only - OpenSearch action-group names aren't fully standardized, so this
    flags anything plausibly write-capable rather than claiming a certified answer. "crud"
    and "*" cover read+write; a role is reported write-capable if ANY matched action hints
    at it, erring toward over-reporting (a false "maybe write" is safer than a false "no")."""
    a = action.lower()
    return any(h in a for h in WRITE_ACTION_HINTS)


def check_opensearch_sigv4_permissions(region, profile, es_host, index):
    """What the SigV4 identity is actually allowed, via the security plugin's own authinfo +
    role-definition endpoints - never an ARN (these are OpenSearch role NAMES, not IAM). This
    is a best-effort read of the role definition's allowed_actions against the target index
    pattern, not a certified authorization decision - OpenSearch's own enforcement is what
    actually governs a real write attempt."""
    base = es_base_url(es_host)
    headers_extra = {} if VIA_HOSTNAME else {}
    try:
        signed, err = sigv4_sign("GET", f"https://{es_host}/_plugins/_security/authinfo", region, profile,
                                   {"Host": es_host, **headers_extra})
        if err:
            return {"ok": False, "error": err}
        resp = requests.get(f"{base}/_plugins/_security/authinfo", headers=signed, timeout=15, verify=False)
        if not resp.ok:
            return {"ok": False, "error": describe_failed("authinfo", resp)}
        info = resp.json()
        role_names = sorted(set(info.get("roles", [])))

        role_results = {}
        for role in role_names:
            signed_r, err_r = sigv4_sign("GET", f"https://{es_host}/_plugins/_security/api/roles/{role}",
                                           region, profile, {"Host": es_host})
            if err_r:
                role_results[role] = {"error": err_r}
                continue
            r_resp = requests.get(f"{base}/_plugins/_security/api/roles/{role}", headers=signed_r,
                                    timeout=15, verify=False)
            if not r_resp.ok:
                role_results[role] = {"error": describe_failed("role", r_resp)}
                continue
            role_def = r_resp.json().get(role, {})
            matches = []
            for ip in role_def.get("index_permissions", []):
                patterns = ip.get("index_patterns", [])
                actions = ip.get("allowed_actions", [])
                if any(fnmatch.fnmatch(index, p) for p in patterns):
                    matches.append({"index_patterns": patterns, "allowed_actions": actions,
                                      "looks_write_capable": any(_looks_like_write(a) for a in actions)})
            role_results[role] = {"index_permissions_matching_index": matches}
        return {"ok": True, "mapped_role_names": role_names, "role_permissions": role_results}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}{sso_login_hint(e, profile)}"}


def check_dev_write_privileges():
    """Postgres has_table_privilege() checks for the tables opensearch-ingester's Postgres
    writer actually touches - confirmed from its own source (internal/rds/pgx_repository.go):
    it reads weld_monitoring_presets (to find a robot's preset) and writes only to
    weld_presets_associations (INSERT ... ON CONFLICT DO UPDATE, so UPDATE matters too, not
    just INSERT/DELETE). Never attempts a real write - has_table_privilege is a pure read.
    Also reports whether a preset row already exists for INGEST_ROBOT_ID (count only)."""
    path = os.path.join(SECRETS_DIR, "DB.secrets")
    if not os.path.exists(path):
        return {"ok": False, "error": f"missing: {path}"}
    kv = read_kv(path)
    require(kv, ["host", "name", "username", "password"], path)
    robot_id = os.environ.get("CLOUD_CHECK_INGEST_ROBOT_ID")
    try:
        conn = psycopg2.connect(
            host="127.0.0.1", port=DB_LOCAL_PORT, dbname=kv["name"],
            user=kv["username"], password=kv["password"], connect_timeout=10, sslmode="require",
        )
        try:
            result = {"tables": {}}
            with conn.cursor() as cur:
                for table in ("weld_presets_associations", "weld_monitoring_presets"):
                    privs = {}
                    for priv in ("INSERT", "UPDATE", "DELETE", "SELECT"):
                        cur.execute("SELECT has_table_privilege(current_user, %s, %s)", (table, priv))
                        privs[priv] = bool(cur.fetchone()[0])
                    result["tables"][table] = privs
                if robot_id:
                    cur.execute(
                        "SELECT COUNT(*) FROM weld_monitoring_presets WHERE robot_id = %s AND deleted_at IS NULL",
                        (robot_id,))
                    result["preset_rows_for_ingest_robot"] = cur.fetchone()[0]
                else:
                    result["preset_rows_for_ingest_robot"] = "CLOUD_CHECK_INGEST_ROBOT_ID not set - skipped"
            result["ok"] = True
            return result
        finally:
            conn.close()
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def main():
    print(f"[INFO] env={ENV} via_hostname={VIA_HOSTNAME} "
          f"(connecting through 127.0.0.1 unless via_hostname)", file=sys.stderr)

    db_result = check_db()

    es_path = os.path.join(SECRETS_DIR, "OPENSEARCH.secrets")
    if not os.path.exists(es_path):
        es_basic = es_sigv4 = es_security_admin = es_sigv4_permissions = {"ok": False, "error": f"missing: {es_path}"}
        es_host = None
    else:
        es_kv = read_kv(es_path)
        require(es_kv, ["host"], es_path)
        es_host = normalize_host(es_kv["host"])
        if es_host is None:
            sys.exit(f"{es_path}: 'host' value doesn't look like a plain hostname after "
                     f"stripping scheme/path/port - refusing to build a request from it")
        es_basic = check_opensearch_basic(es_kv, es_host)
        es_sigv4 = check_opensearch_sigv4(es_kv, es_host)
        es_security_admin = check_security_admin(es_kv, es_host)
        region = os.environ.get("CLOUD_CHECK_AWS_REGION")
        profile = os.environ.get("CLOUD_CHECK_AWS_PROFILE")
        es_sigv4_permissions = check_opensearch_sigv4_permissions(region, profile, es_host, es_kv.get("index", ""))

    db_write_privileges = check_dev_write_privileges()

    summary = {
        "env": ENV,
        "db": db_result,
        "opensearch_basic_auth": es_basic,
        "opensearch_sigv4": es_sigv4,
        "opensearch_sigv4_permissions": es_sigv4_permissions,
        "opensearch_basic_auth_security_admin": es_security_admin,
        "db_write_privileges": db_write_privileges,
    }
    print(json.dumps(summary, indent=2))

    if es_basic.get("ok") and not es_sigv4.get("ok"):
        print("\n[RESULT] OpenSearch: basic auth works, SigV4 does not.", file=sys.stderr)
    elif es_sigv4.get("ok") and not es_basic.get("ok"):
        print("\n[RESULT] OpenSearch: SigV4 works (matches how NovApi itself connects), basic auth does not.",
              file=sys.stderr)
    elif es_basic.get("ok") and es_sigv4.get("ok"):
        print("\n[RESULT] OpenSearch: both basic auth and SigV4 work.", file=sys.stderr)
    else:
        print("\n[RESULT] OpenSearch: neither basic auth nor SigV4 worked - see the errors above.",
              file=sys.stderr)

    identity = es_sigv4.get("caller_identity")
    if identity:
        print(f"[RESULT] SigV4 caller identity (account:role, no session name): {identity} "
              f"- pass this to whoever manages the domain's fine-grained security role mapping.",
              file=sys.stderr)
    elif es_sigv4.get("caller_identity_error"):
        print(f"[RESULT] Could not determine the SigV4 caller identity: {es_sigv4['caller_identity_error']}",
              file=sys.stderr)

    if es_security_admin.get("ok"):
        print(f"[RESULT] Basic-auth login CAN administer the security plugin - role names found: "
              f"{es_security_admin.get('role_names_found')}, "
              f"{es_security_admin.get('backend_role_count')} backend role(s) mapped to "
              f"'{SECURITY_CHECK_ROLE}'.", file=sys.stderr)
    else:
        print(f"[RESULT] Basic-auth login cannot administer the security plugin "
              f"(rolesmapping={es_security_admin.get('rolesmapping_status')}, "
              f"roles={es_security_admin.get('roles_status')}).", file=sys.stderr)

    if es_sigv4_permissions.get("ok"):
        print(f"[RESULT] SigV4 identity's mapped OpenSearch role(s): "
              f"{es_sigv4_permissions.get('mapped_role_names')} - see opensearch_sigv4_permissions "
              f"in the JSON above for whether any look write-capable on this index (best-effort "
              f"reading of each role's own definition, not a certified answer).", file=sys.stderr)
    elif es_sigv4_permissions.get("error"):
        print(f"[RESULT] Could not read the SigV4 identity's permissions: {es_sigv4_permissions['error']}",
              file=sys.stderr)

    if db_write_privileges.get("ok"):
        print(f"[RESULT] Postgres privileges (has_table_privilege, never attempted for real): "
              f"{db_write_privileges['tables']} - preset rows for the configured ingest robot: "
              f"{db_write_privileges.get('preset_rows_for_ingest_robot')}.", file=sys.stderr)
    else:
        print(f"[RESULT] Could not check Postgres write privileges: {db_write_privileges.get('error')}",
              file=sys.stderr)


if __name__ == "__main__":
    main()

"""HUB-106: shared helpers for cloud-check.py and cloud-ingest.py - one place for secrets-file
reading, host normalization, SigV4 signing, and SSO-liveness/ARN-reduction, so the two scripts'
answers never drift apart. Never prints a secret value; ARNs are always reduced to account:role.
"""
import re

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

import botocore.auth
import botocore.awsrequest
import botocore.session

# Every OpenSearch request in these tools uses verify=False: the connection is to 127.0.0.1
# through cloud-tunnel.sh's local forward, not the real TLS endpoint directly, so there's no
# real certificate to validate against that address - and NovApi itself already does the same
# for OpenSearch (osRepo/queries.js: `ssl: { rejectUnauthorized: false }`), so this isn't a new
# weakening. Silenced once here (a global filter) so neither this module's own requests nor
# cloud-check.py's/cloud-ingest.py's need to repeat it.
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

ARN_RE = re.compile(r"arn:[a-z\-]+:[a-z0-9\-]+:[a-z0-9\-]*:\d{12}:[^\s\"'<>]+")
SSO_ERROR_TYPES = ("UnauthorizedSSOTokenError", "SSOTokenLoadError", "TokenRetrievalError")


def normalize_host(raw):
    """Same contract as lib/common.sh's normalize_host: strips a leading scheme, trailing
    path, and :port from a secrets-file host value. Returns None if what's left doesn't look
    like a plain hostname/IP - callers must treat that as a parse error, never build a
    URL/Host header from it and call the result a real answer."""
    h = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", raw)
    h = h.split("/", 1)[0]
    h = h.split(":", 1)[0]
    if h and re.fullmatch(r"[A-Za-z0-9.-]+", h):
        return h
    return None


def read_kv(path):
    """Tolerant key=value reader: skips blank lines and any line with no literal '=' at all
    (the pasted "Secret key / Secret value" header row some of these files carry has none),
    strips whitespace around key/value. Returns a dict - callers check keys by NAME only; the
    values this returns are never logged or re-printed."""
    out = {}
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or "=" not in line:
                continue
            key, _, value = line.partition("=")
            out[key.strip()] = value.strip()
    return out


def require(kv, keys, path):
    missing = [k for k in keys if not kv.get(k)]
    if missing:
        raise SystemExit(f"{path}: missing required key(s): {', '.join(missing)}")


def reduce_arn(arn):
    """Reduce an ARN to 'account:resource-type/name' - drops partition/service/region, and
    for an assumed-role ARN (SSO sessions are always this shape) the session-name segment
    too, since that can carry a username/email. Returns None if it doesn't parse as an ARN."""
    if not arn:
        return None
    parts = arn.split(":", 5)
    if len(parts) != 6 or parts[0] != "arn":
        return None
    account = parts[4]
    resource_parts = parts[5].split("/")
    if resource_parts[0] == "assumed-role" and len(resource_parts) >= 2:
        return f"{account}:role/{resource_parts[1]}"
    if len(resource_parts) >= 2:
        return f"{account}:{resource_parts[0]}/{resource_parts[1]}"
    return f"{account}:{resource_parts[0]}"


def scrub_arns(text):
    """Defense in depth: an OpenSearch/IAM permission denial sometimes embeds the caller's
    own full ARN in the message text. Reduce any ARN found the same way reduce_arn does,
    rather than trust every error body is ARN-free."""
    return ARN_RE.sub(lambda m: reduce_arn(m.group(0)) or "arn:***", text)


# A signature-mismatch 403 from AWS can echo back the Canonical Request / String to Sign it
# computed, which embeds the actual request headers it was given - including a REAL,
# usable session token or access key. Confirmed for real (the owner's dev run echoed
# x-amz-security-token back in exactly this way). Key name kept, value replaced - never drop
# the key entirely, since which key was echoed is itself diagnostic.
SECRET_VALUE_PATTERNS = [
    re.compile(r'(?i)(x-amz-security-token["\']?\s*[:=]\s*["\']?)([^"\'&,\s]+)'),
    re.compile(r'(?i)(x-amz-signature["\']?\s*[:=]\s*["\']?)([^"\'&,\s]+)'),
    re.compile(r'(?i)(awsaccesskeyid["\']?\s*[:=]\s*["\']?)([^"\'&,\s]+)'),
    re.compile(r'(?i)(authorization["\']?\s*[:=]\s*["\']?)([^"\'\n]+)'),
]


def scrub_secrets(text):
    for pat in SECRET_VALUE_PATTERNS:
        text = pat.sub(lambda m: m.group(1) + "<redacted>", text)
    return text


def scrub_sensitive(text):
    """Everything that must never reach a log, a tee'd file, or this tool's own stdout
    unscrubbed: full ARNs (session names can carry a username/email) and any of the actual
    secret VALUES AWS can echo back in a signature-mismatch error body. Call this on every
    response body before showing or storing it - never show one raw."""
    return scrub_secrets(scrub_arns(text))


def sso_login_hint(exc, profile):
    if type(exc).__name__ in SSO_ERROR_TYPES or "sso" in str(exc).lower():
        return f" - run: aws sso login --profile {profile}"
    return ""


def sigv4_sign(method, url, region, profile, headers, data=None):
    session = botocore.session.Session(profile=profile)
    creds = session.get_credentials()
    if creds is None:
        return None, (f"no AWS credentials found for profile '{profile}' - check it exists "
                       f"(SSO profiles live in ~/.aws/config, static-key profiles in ~/.aws/credentials)")
    frozen = creds.get_frozen_credentials()
    headers = dict(headers)
    # A body with no Content-Type gets a flat 406 from OpenSearch ("Content-Type header []
    # is not supported") - requests' own data=<bytes> never sets one on its own. Added BEFORE
    # signing (not after) so it's included in SignedHeaders and the signature still matches
    # the header actually sent - the one real correctness constraint here.
    if data is not None and "Content-Type" not in headers:
        headers["Content-Type"] = "application/json"
    request = botocore.awsrequest.AWSRequest(method=method, url=url, data=data, headers=headers)
    botocore.auth.SigV4Auth(frozen, "es", region).add_auth(request)
    return dict(request.headers), None


def sigv4_request(method, es_host, es_loopback, path, region, profile, via_hostname=False,
                    data=None, timeout=15):
    """One signed request through cloud-tunnel.sh's local forward. The URL used for SIGNING
    (and the Host header actually sent) never carries a port - a tunnel on a high port makes
    the client sign "host:PORT" while AWS recomputes the signature for "host" alone, so every
    request gets a 403 "signature we calculated does not match" (the real bug this chases).
    That's why the OpenSearch forward is pinned to port 443 locally (cloud-tunnel.sh) instead
    of a configurable high port like the DB one - the connection target here is that per-env
    loopback address (es_loopback) unless via_hostname says to use the real name directly
    (needs the owner's /etc/hosts line mapping it to that same loopback - see cloud-hosts.sh).
    TLS cert verification is off, matching NovApi's own osRepo/queries.js
    (rejectUnauthorized: false) - not a new weakening."""
    base = f"https://{es_host}" if via_hostname else f"https://{es_loopback}"
    url = f"https://{es_host}{path}"
    signed, err = sigv4_sign(method, url, region, profile, {"Host": es_host}, data=data)
    if err:
        return None, err
    try:
        resp = requests.request(method, f"{base}{path}", headers=signed, data=data,
                                  timeout=timeout, verify=False)
        return resp, None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}{sso_login_hint(e, profile)}"


def get_caller_identity(region, profile):
    """STS GetCallerIdentity for the resolved profile, reduced to account+role (no session
    name) - so the owner can hand this to whoever manages the domain's fine-grained security
    role mapping, and so other checks can confirm the SSO session is actually live right now
    (a real, free, read-only API call - not a guess based on file timestamps)."""
    try:
        session = botocore.session.Session(profile=profile)
        sts = session.create_client("sts", region_name=region)
        identity = sts.get_caller_identity()
        return reduce_arn(identity.get("Arn", "")), None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}{sso_login_hint(e, profile)}"

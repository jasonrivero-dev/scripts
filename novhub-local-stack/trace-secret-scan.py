#!/usr/bin/env python3
"""HUB-106: scans a Chrome DevTools Performance trace (raw trace JSON, "Save profile...") for
anything that looks like an Authorization header, a cookie, a Bearer token, or a JWT - without
ever printing the matched value. Reports only yes/no and where (event name + JSON key path).

Chrome's own docs don't say whether a Performance recording can embed request/response header
data (it depends on which trace categories were recorded) - this exists to answer that
empirically, once, before a trace is shared anywhere.
"""
import json
import re
import sys
from collections import Counter

BEARER_RE = re.compile(r"Bearer\s+[A-Za-z0-9\-_.=]{10,}", re.IGNORECASE)
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}")
SENSITIVE_KEY_NAMES = {"authorization", "cookie", "set-cookie", "jwt_token", "proxy-authorization"}
MAX_LOCATIONS_SHOWN = 20


def scan(obj, path, event_name, findings):
    if isinstance(obj, dict):
        for k, v in obj.items():
            next_event_name = event_name
            if path == [] and isinstance(obj.get("name"), str):
                next_event_name = obj["name"]
            if isinstance(k, str) and k.strip().lower() in SENSITIVE_KEY_NAMES:
                findings.append((next_event_name or "(top level)", ".".join(path + [k]), f"key named '{k}'"))
                # still recurse into the value below, in case it's itself a dict of headers
            scan(v, path + [str(k)], next_event_name, findings)
    elif isinstance(obj, list):
        for v in obj:
            scan(v, path, event_name, findings)
    elif isinstance(obj, str):
        if BEARER_RE.search(obj):
            findings.append((event_name or "(top level)", ".".join(path), "Bearer-token-shaped value"))
        if JWT_RE.search(obj):
            findings.append((event_name or "(top level)", ".".join(path), "JWT-shaped value"))
    # numbers/bools/None: nothing to check


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        print("Usage: trace-secret-scan.py <path-to-trace.json>")
        print("Exit 0 = nothing found. Exit 1 = found something - see the printed locations.")
        sys.exit(0)

    path = sys.argv[1]
    with open(path) as f:
        raw = json.load(f)
    events = raw if isinstance(raw, list) else raw.get("traceEvents", [])

    findings = []
    for event in events:
        scan(event, [], None, findings)

    if not findings:
        print(f"NOT FOUND: scanned {len(events)} trace events in {path} - "
              f"no Authorization/Cookie/Bearer-token/JWT-shaped value found.")
        sys.exit(0)

    by_location = Counter((ev, loc, kind) for ev, loc, kind in findings)
    print(f"FOUND: {len(findings)} match(es) across {len(by_location)} distinct location(s) "
          f"in {path} - values are NOT printed, only where they are:")
    for (ev, loc, kind), count in sorted(by_location.items(), key=lambda kv: -kv[1])[:MAX_LOCATIONS_SHOWN]:
        print(f"  event '{ev}' -> {loc} ({kind}) x{count}")
    if len(by_location) > MAX_LOCATIONS_SHOWN:
        print(f"  ... and {len(by_location) - MAX_LOCATIONS_SHOWN} more distinct location(s)")
    print("Do not share this file until this is resolved.")
    sys.exit(1)


if __name__ == "__main__":
    main()

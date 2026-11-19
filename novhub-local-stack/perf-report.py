#!/usr/bin/env python3
"""HUB-106: ONE zero-install graphical report, built from any combination of:
  --novapi-log  NovApi's own request log (server-side time per request)
  --har         a HAR file (browser-side time per request - the owner's export or Playwright's)
  --trace       a Chrome DevTools Performance recording ("Save profile...", raw trace JSON) -
                total scripting time, longest task, long task count (>50ms), main-thread busy
                time, and top JS functions by self time
  --capture-metrics  a *-metrics.json from perf-capture.js, shown next to --trace's numbers
                for direct comparison (same field definitions: see --trace's note)
  --os-container / --pg-container  OpenSearch/Postgres slow logs for the same window
                (only meaningful alongside --novapi-log; turn slow logs on first with
                perf-slowlog.sh on)

Given --novapi-log and --har together, matches requests by route + closest start time and
shows browser time vs. server time per request - the report states plainly how many matched
and how many didn't, never silently drops anything.

Before sharing any trace file, run trace-secret-scan.py/.sh on it first - a DevTools trace can
embed request/response data, and this tool does not check for that.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

NOVAPI_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\s+(?P<method>\w+)\s+(?P<path>\S+)\s+(?P<status>\d+)\s+\S*\s+-\s+"
    r"(?P<time_ms>[\d.]+)\s+ms"
)
ROBOT_RE = re.compile(r"/robots/\d+/")
OS_RE = re.compile(r"^\[(?P<ts>[\d-]+T[\d:,]+)\]\[WARN\s*\]\[i\.s\.s\.(query|fetch)\s*\].*?took_millis\[(?P<ms>\d+)\]")
PG_RE = re.compile(r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+) UTC \[\d+\] LOG:\s+duration: (?P<ms>[\d.]+) ms")


def route_of(path):
    return ROBOT_RE.sub("/robots/:robot_id/", path.split("?", 1)[0])


def detect_brand():
    """Reads the same ground truth as brand-check.sh: NovApi's own startup log line and
    NovApp's .env - never an ambient env var. Best-effort; a report still renders without it."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    novapi_brand = "unknown"
    novapi_log = os.path.join(script_dir, ".state", "novapi.log")
    if os.path.exists(novapi_log):
        with open(novapi_log) as f:
            lines = [l for l in f if "IS_NOVAI" in l]
        if lines:
            novapi_brand = "NovAI" if "true" in lines[-1] else ("SWR" if "false" in lines[-1] else "unknown")
    novapp_brand = "unknown"
    novapp_env = os.path.expanduser(os.environ.get("NOVAPP_REPO", "~/dev/novhub") + "/.env")
    if os.path.exists(novapp_env):
        with open(novapp_env) as f:
            for line in f:
                if line.startswith("VITE_IS_NOVAI="):
                    novapp_brand = "NovAI" if line.strip().endswith("true") else "SWR"
    return {"novapi": novapi_brand, "novapp": novapp_brand}


# ---------- NovApi log ----------

def parse_novapi(path):
    entries = []
    with open(path) as f:
        for line in f:
            m = NOVAPI_RE.match(line)
            if not m:
                continue
            end = datetime.fromisoformat(m["ts"].replace("Z", "+00:00"))
            resp_ms = float(m["time_ms"])
            entries.append({
                "route": f"{m['method']} {route_of(m['path'])}", "method": m["method"],
                "path": m["path"], "status": int(m["status"]),
                "start": end - timedelta(milliseconds=resp_ms), "end": end, "server_ms": resp_ms,
            })
    return entries


def novapi_summary(entries):
    by_route = {}
    for e in entries:
        by_route.setdefault(e["route"], []).append(e["server_ms"])
    out = {}
    for route, times in by_route.items():
        out[route] = {"count": len(times), "median_ms": statistics.median(times),
                       "slowest_ms": max(times), "total_ms": sum(times)}
    return out


# ---------- HAR ----------

def parse_har(path):
    with open(path) as f:
        har = json.load(f)
    entries = har["log"]["entries"]
    if not entries:
        return []
    starts = [datetime.fromisoformat(e["startedDateTime"].replace("Z", "+00:00")) for e in entries]
    t0 = min(starts)
    out = []
    for e, started in zip(entries, starts):
        timings = e.get("timings", {})
        total_ms = e.get("time", 0)
        url = e["request"]["url"]
        out.append({
            # path is the URL's path only (no scheme/host/query) - route_of() and the NovApi
            # log's route both key on path alone, so this must match or routes never line up.
            "url": url, "method": e["request"]["method"],
            "status": e["response"]["status"], "path": urlparse(url).path,
            "start": started, "end": started + timedelta(milliseconds=total_ms),
            "offset_ms": (started - t0).total_seconds() * 1000,
            "total_ms": total_ms, "wait_ms": max(timings.get("wait", 0), 0),
        })
    return out


def har_route(e):
    """Same shape as NovApi's own route key ("METHOD /path/pattern") - method must be part of
    the key or an OPTIONS preflight and its real request collapse into the same route."""
    return f"{e['method']} {route_of(e['path'])}"


def har_concurrency(entries):
    events = []
    for e in entries:
        events.append((e["offset_ms"], 1))
        events.append((e["offset_ms"] + e["total_ms"], -1))
    events.sort()
    cur = peak = 0
    for _, delta in events:
        cur += delta
        peak = max(peak, cur)
    return peak


def har_summary(entries):
    by_route = {}
    for e in entries:
        by_route.setdefault(har_route(e), []).append(e)
    out = {}
    for route, rows in by_route.items():
        totals = [r["total_ms"] for r in rows]
        waits = [r["wait_ms"] for r in rows]
        out[route] = {"count": len(rows), "median_total_ms": statistics.median(totals),
                       "slowest_total_ms": max(totals), "median_wait_ms": statistics.median(waits)}
    # Each real request fires its own CORS preflight (OPTIONS, same path) - attach that count
    # to its real-request row instead of leaving it to be read as a separate, unrelated route.
    for route, row in out.items():
        method, _, rest = route.partition(" ")
        if method == "OPTIONS":
            continue
        pf = out.get(f"OPTIONS {rest}")
        row["preflight_count"] = pf["count"] if pf else 0
    return out


def har_request_totals(entries):
    preflight = sum(1 for e in entries if e["method"] == "OPTIONS")
    return {"total": len(entries), "preflight": preflight, "real": len(entries) - preflight}


# ---------- OpenSearch / Postgres slow logs ----------

def docker_logs(container, since, until):
    cmd = ["docker", "logs", container, "--since", since.isoformat(), "--until", until.isoformat()]
    r = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return r.stdout.splitlines() + r.stderr.splitlines()


def parse_os_log(lines):
    out = []
    for line in lines:
        m = OS_RE.match(line)
        if m:
            out.append((datetime.fromisoformat(m["ts"].replace(",", ".") + "+00:00"), float(m["ms"])))
    return out


def parse_pg_log(lines):
    out = []
    for line in lines:
        m = PG_RE.match(line)
        if m:
            out.append((datetime.fromisoformat(m["ts"] + "+00:00"), float(m["ms"])))
    return out


# ---------- Chrome DevTools Performance trace ("Save profile...") ----------
# Schema confirmed against devtools-frontend source (models/trace/types/TraceEvents.ts,
# models/cpu_profile/CPUProfileDataModel.ts): top-level tasks are {name:"RunTask", ph:"X"}
# (Phase.COMPLETE); CPU-profile events are {name:"Profile"|"ProfileChunk", ph:"P"} (Phase.SAMPLE)
# with samples/timeDeltas/cpuProfile.nodes under args.data; the main thread is the
# {ph:"M", name:"thread_name", args:{name:"CrRendererMain"}} metadata event's (pid,tid).
# "Total scripting ms"/"longest task"/"long task count" are defined exactly as perf-capture.js's
# Long Tasks API metrics (tasks over 50ms only) so the two are directly comparable;
# "main-thread busy ms" is a separate, additional sum of every top-level task regardless of size.
LONG_TASK_THRESHOLD_MS = 50
TOP_FUNCTIONS_LIMIT = 10


def _trace_events(path):
    with open(path) as f:
        raw = json.load(f)
    return raw if isinstance(raw, list) else raw.get("traceEvents", [])


def _find_main_thread(events):
    candidates = [(e["pid"], e["tid"]) for e in events
                  if e.get("ph") == "M" and e.get("name") == "thread_name"
                  and e.get("args", {}).get("name") == "CrRendererMain"]
    if not candidates:
        return None, "no CrRendererMain thread_name metadata event found"
    if len(candidates) == 1:
        return candidates[0], None
    counts = Counter(
        (e["pid"], e["tid"]) for e in events
        if e.get("ph") == "X" and e.get("name") == "RunTask" and (e["pid"], e["tid"]) in candidates
    )
    if not counts:
        return candidates[0], f"{len(candidates)} CrRendererMain threads found, none had RunTask events - used the first"
    best = counts.most_common(1)[0][0]
    return best, f"{len(candidates)} CrRendererMain threads found (multiple renderer processes) - used the busiest ({counts[best]} tasks)"


def _run_task_events(events, thread):
    pid, tid = thread
    return [e for e in events
            if e.get("ph") == "X" and e.get("name") == "RunTask"
            and e.get("pid") == pid and e.get("tid") == tid and "dur" in e]


def _cpu_profile_for_thread(events, thread):
    """Stitches Profile+ProfileChunk events for the main thread's profile into one
    (nodes, samples, timeDeltas). The head "Profile" event's (pid,tid) identifies which thread
    is being profiled, but its "ProfileChunk" continuations are written by v8's own sampling
    thread under a DIFFERENT tid (same pid) - confirmed against a real trace, where every
    ProfileChunk shared the head's pid+id but a tid belonging to no CrRendererMain thread at
    all. Chunks are correlated to their head by (pid, id), never by tid."""
    pid, tid = thread
    head_events = [e for e in events
                    if e.get("ph") == "P" and e.get("name") == "Profile"
                    and e.get("pid") == pid and e.get("tid") == tid]
    profile_ids = {e.get("id") for e in head_events if e.get("id") is not None}
    if profile_ids:
        sample_events = [e for e in events
                          if e.get("ph") == "P" and e.get("name") in ("Profile", "ProfileChunk")
                          and e.get("pid") == pid and e.get("id") in profile_ids]
    else:
        sample_events = []
    if not sample_events:
        # Schema-based fallback, in case this Chrome version doesn't use ph:"P"/these names/an
        # `id` field - still correct if args.data really does hold cpuProfile/timeDeltas, scoped
        # to this pid only (tid is not a reliable filter for these events - see above).
        sample_events = [e for e in events
                          if e.get("pid") == pid
                          and isinstance(e.get("args", {}).get("data"), dict)
                          and ("cpuProfile" in e["args"]["data"] or "timeDeltas" in e["args"]["data"])]
    if not sample_events:
        return None, None, None, "no Profile/ProfileChunk (or schema-matching) events found for the main thread's process"

    sample_events.sort(key=lambda e: e.get("ts", 0))
    nodes_by_id = {}
    samples = []
    time_deltas = []
    for e in sample_events:
        data = e.get("args", {}).get("data", {})
        for node in (data.get("cpuProfile", {}) or {}).get("nodes", []) or []:
            nodes_by_id[node["id"]] = node
        samples.extend((data.get("cpuProfile", {}) or {}).get("samples", []) or [])
        time_deltas.extend(data.get("timeDeltas", []) or [])

    if not nodes_by_id or not samples:
        return None, None, None, "Profile/ProfileChunk events found but carried no nodes/samples - trace may have been recorded without JS sampling enabled"
    return nodes_by_id, samples, time_deltas, None


def _top_functions_by_self_time(nodes_by_id, samples, time_deltas):
    # Confirmed in CPUProfileDataModel.ts: timeDeltas[i+1] is the duration attributed to
    # samples[i] (the gap between sample i and sample i+1). The leading timeDeltas[0] (startTime
    # -> first sample) and any trailing sample with no following delta are not attributable to a
    # specific sample and are dropped - a small, documented undercount, not a silent one.
    self_ms_by_node = Counter()
    n = min(len(samples), len(time_deltas) - 1)
    for i in range(max(n, 0)):
        self_ms_by_node[samples[i]] += time_deltas[i + 1] / 1000.0

    self_ms_by_function = Counter()
    for node_id, self_ms in self_ms_by_node.items():
        node = nodes_by_id.get(node_id)
        if not node:
            continue
        cf = node.get("callFrame", {})
        key = (cf.get("functionName") or "(anonymous)", cf.get("url", ""), cf.get("lineNumber", -1))
        self_ms_by_function[key] += self_ms

    total_ms = sum(self_ms_by_function.values())
    top = self_ms_by_function.most_common(TOP_FUNCTIONS_LIMIT)
    return [{"function": k[0], "url": k[1], "line": k[2] + 1 if k[2] >= 0 else None,
             "self_ms": v, "self_pct": (v / total_ms * 100) if total_ms else 0} for k, v in top], total_ms


def _render_settle_ms(events, thread, url_substring, run_task_events):
    """Best-effort "time from the last matching network response to the page settling" - a raw
    trace has no explicit 'table rendered' mark, so this uses the end of the last main-thread
    RunTask (the thread going idle) as a render-complete proxy. Explicitly caveated, never
    presented as more precise than it is."""
    pid, tid = thread
    url_by_request_id = {
        e["args"]["data"]["requestId"]: e["args"]["data"]["url"]
        for e in events
        if e.get("name") == "ResourceSendRequest" and isinstance(e.get("args", {}).get("data"), dict)
        and "url" in e["args"]["data"] and "requestId" in e["args"]["data"]
    }
    finish_name, note_suffix = "ResourceFinish", ""
    matches = [e for e in events if e.get("name") == finish_name
               and e.get("args", {}).get("data", {}).get("requestId") in url_by_request_id
               and url_substring in url_by_request_id[e["args"]["data"]["requestId"]]]
    if not matches:
        finish_name, note_suffix = "ResourceReceiveResponse", " (no ResourceFinish events matched - used ResourceReceiveResponse/first-byte time instead, an earlier point than response-complete)"
        matches = [e for e in events if e.get("name") == finish_name
                   and e.get("args", {}).get("data", {}).get("requestId") in url_by_request_id
                   and url_substring in url_by_request_id[e["args"]["data"]["requestId"]]]
    if not matches:
        return None, f"no network events found for a URL containing '{url_substring}' - can't compute this"

    last_response_ts = max(e["ts"] for e in matches)
    idle_candidates = [e["ts"] + e["dur"] for e in run_task_events if e["ts"] + e["dur"] > last_response_ts]
    if not idle_candidates:
        return None, "found the last matching response, but no main-thread activity after it to measure settling against"
    settle_ts = max(idle_candidates)
    return (settle_ts - last_response_ts) / 1000.0, \
        f"proxy: last '{finish_name}' matching '{url_substring}' -> end of the last main-thread task after it (not an explicit render mark){note_suffix}"


def parse_trace(path):
    events = _trace_events(path)
    thread, thread_note = _find_main_thread(events)
    out = {"event_count": len(events), "main_thread_note": thread_note}
    if thread is None:
        out["error"] = thread_note
        return out

    run_task_events = _run_task_events(events, thread)
    tasks_ms = [e["dur"] / 1000.0 for e in run_task_events]
    long_tasks_ms = [t for t in tasks_ms if t > LONG_TASK_THRESHOLD_MS]
    out["total_scripting_ms"] = sum(long_tasks_ms)
    out["longest_task_ms"] = max(long_tasks_ms) if long_tasks_ms else 0
    out["long_task_count"] = len(long_tasks_ms)
    out["main_thread_busy_ms"] = sum(tasks_ms)
    out["run_task_count"] = len(tasks_ms)
    if not tasks_ms:
        out["run_task_note"] = "no RunTask events found on the main thread - this Chrome version may name top-level tasks differently"

    out["render_settle_ms"], out["render_settle_note"] = _render_settle_ms(
        events, thread, "weld_test_reports", run_task_events)

    nodes_by_id, samples, time_deltas, profile_note = _cpu_profile_for_thread(events, thread)
    if profile_note:
        out["top_functions"] = []
        out["top_functions_note"] = profile_note
    else:
        out["top_functions"], sampled_total_ms = _top_functions_by_self_time(nodes_by_id, samples, time_deltas)
        out["sampled_total_ms"] = sampled_total_ms
    return out


def sum_in_window(timed_values, start, end):
    return sum(ms for ts, ms in timed_values if start <= ts <= end)


def breakdown_summary(novapi_entries, os_lines, pg_lines):
    by_route = {}
    for e in novapi_entries:
        os_ms = sum_in_window(os_lines, e["start"], e["end"])
        pg_ms = sum_in_window(pg_lines, e["start"], e["end"])
        rest_ms = max(0.0, e["server_ms"] - os_ms - pg_ms)
        by_route.setdefault(e["route"], []).append((e["server_ms"], os_ms, pg_ms, rest_ms))
    out = {}
    for route, rows in by_route.items():
        out[route] = {
            "count": len(rows),
            "novapi_median_ms": statistics.median(r[0] for r in rows),
            "opensearch_median_ms": statistics.median(r[1] for r in rows),
            "postgres_median_ms": statistics.median(r[2] for r in rows),
            "rest_median_ms": statistics.median(r[3] for r in rows),
        }
    return out


# ---------- Matching NovApi <-> HAR ----------

def _by_route_reason(entries_with_reason):
    """Groups (entry, reason) pairs into {route: {count, reason}} - one reason per route since
    in practice every request on a route is unmatched for the same cause."""
    out = {}
    for route, reason in entries_with_reason:
        slot = out.setdefault(route, {"count": 0, "reason": reason})
        slot["count"] += 1
    return out


def match_novapi_har(novapi_entries, har_entries, api_host, tolerance_s=5):
    # OPTIONS preflights have no server-side counterpart to match against - NovApi's CORS
    # middleware answers them in <0.1ms before any route handler runs, so they're excluded
    # here and counted separately (har_summary's preflight_count, har_request_totals).
    har_by_route = {}
    for h in har_entries:
        if h["method"] == "OPTIONS":
            continue
        har_by_route.setdefault(har_route(h), []).append(h)
    matched = []
    used_har_ids = set()
    unmatched_novapi = []  # (route, reason)
    for n in novapi_entries:
        if n["method"] == "OPTIONS":
            unmatched_novapi.append((n["route"], "preflight - answered by CORS middleware before any route handler runs, never reaches the browser's real-request timing"))
            continue
        candidates = [h for h in har_by_route.get(n["route"], []) if id(h) not in used_har_ids]
        if not candidates:
            unmatched_novapi.append((n["route"], "no HAR entry for this route at all - likely outside the HAR's capture window, or this route was excluded from a filtered HAR export"))
            continue
        best = min(candidates, key=lambda h: abs((h["start"] - n["start"]).total_seconds()))
        if abs((best["start"] - n["start"]).total_seconds()) > tolerance_s:
            unmatched_novapi.append((n["route"], f"closest HAR entry on this route is >{tolerance_s}s away in time - likely a different page load or log window mismatch"))
            continue
        used_har_ids.add(id(best))
        matched.append({"route": n["route"], "server_ms": n["server_ms"],
                         "browser_total_ms": best["total_ms"], "browser_wait_ms": best["wait_ms"]})
    unmatched_har = []  # (route, reason)
    for h in har_entries:
        if h["method"] == "OPTIONS" or id(h) in used_har_ids:
            continue
        host = urlparse(h["url"]).netloc
        if api_host and host != api_host:
            reason = f"different host ({host}, not {api_host}) - a page asset or dev-server request, never reaches NovApi's log"
        else:
            reason = "no NovApi-log entry for this route at all - likely outside the --novapi-log slice's time window"
        unmatched_har.append((har_route(h), reason))
    return matched, _by_route_reason(unmatched_novapi), _by_route_reason(unmatched_har)


# ---------- Report assembly ----------

def build_report(args):
    data = {"generated_note": "Zero-install HTML - open report.html directly in a browser.",
            "brand": detect_brand()}
    novapi_entries = parse_novapi(args.novapi_log) if args.novapi_log else []
    har_entries = parse_har(args.har) if args.har else []

    if novapi_entries:
        data["novapi_summary"] = novapi_summary(novapi_entries)
        data["novapi_window"] = {
            "start": min(e["start"] for e in novapi_entries).isoformat(),
            "end": max(e["end"] for e in novapi_entries).isoformat(),
            "requests": [{"route": e["route"], "offset_ms":
                          (e["start"] - min(x["start"] for x in novapi_entries)).total_seconds() * 1000,
                          "server_ms": e["server_ms"]} for e in novapi_entries],
        }
    if har_entries:
        data["har_summary"] = har_summary(har_entries)
        data["har_concurrency"] = har_concurrency(har_entries)
        data["har_request_totals"] = har_request_totals(har_entries)
        data["har_requests"] = [{"route": har_route(e), "offset_ms": e["offset_ms"],
                                  "total_ms": e["total_ms"], "wait_ms": e["wait_ms"]} for e in har_entries]

    if novapi_entries and har_entries:
        # The HAR's host for real API calls - inferred from whichever host actually carries
        # routes that also show up in the NovApi log, so an unfiltered HAR (page assets +
        # dev-server requests mixed in with the API calls) can tell them apart by host too.
        novapi_routes = {e["route"] for e in novapi_entries}
        candidate_hosts = [urlparse(h["url"]).netloc for h in har_entries
                           if h["method"] != "OPTIONS" and har_route(h) in novapi_routes]
        api_host = Counter(candidate_hosts).most_common(1)[0][0] if candidate_hosts else None

        matched, unmatched_n_by_route, unmatched_h_by_route = match_novapi_har(novapi_entries, har_entries, api_host)
        unmatched_n = sum(v["count"] for v in unmatched_n_by_route.values())
        unmatched_h = sum(v["count"] for v in unmatched_h_by_route.values())
        data["combined"] = {
            "how_matched": "Same route pattern + closest start time within 5s.",
            "matched_count": len(matched), "unmatched_novapi_count": unmatched_n,
            "unmatched_har_count": unmatched_h, "pairs": matched,
            "unmatched_novapi_by_route": unmatched_n_by_route,
            "unmatched_har_by_route": unmatched_h_by_route,
        }

    if args.trace:
        data["trace_summary"] = parse_trace(args.trace)
    if args.capture_metrics:
        with open(args.capture_metrics) as f:
            data["capture_metrics"] = json.load(f)

    if args.os_container and args.pg_container and novapi_entries:
        window_start = min(e["start"] for e in novapi_entries) - timedelta(seconds=2)
        window_end = max(e["end"] for e in novapi_entries) + timedelta(seconds=2)
        os_lines = parse_os_log(docker_logs(args.os_container, window_start, window_end))
        pg_lines = parse_pg_log(docker_logs(args.pg_container, window_start, window_end))
        data["breakdown"] = breakdown_summary(novapi_entries, os_lines, pg_lines)

    return data


# ---------- Before/After comparison mode ----------

def load_json(path):
    with open(path) as f:
        return json.load(f)


def _page_analysis(har_path, novapi_path):
    if not har_path:
        return None
    har_entries = parse_har(har_path)
    out = {
        "har_totals": har_request_totals(har_entries),
        "har_summary": har_summary(har_entries),
        "har_requests": [{"route": har_route(e), "offset_ms": e["offset_ms"], "total_ms": e["total_ms"],
                           "method": e["method"]} for e in har_entries],
        "matched": None,
    }
    if novapi_path:
        novapi_entries = parse_novapi(novapi_path)
        novapi_routes = {e["route"] for e in novapi_entries}
        candidate_hosts = [urlparse(h["url"]).netloc for h in har_entries
                           if h["method"] != "OPTIONS" and har_route(h) in novapi_routes]
        api_host = Counter(candidate_hosts).most_common(1)[0][0] if candidate_hosts else None
        matched, _, _ = match_novapi_har(novapi_entries, har_entries, api_host)
        by_route = {}
        for p in matched:
            by_route.setdefault(p["route"], []).append(p)
        out["matched"] = {
            "matched_count": len(matched),
            "by_route": {route: {
                "count": len(rows),
                "median_server_ms": statistics.median(r["server_ms"] for r in rows),
                "median_browser_ms": statistics.median(r["browser_total_ms"] for r in rows),
            } for route, rows in by_route.items()},
        }
    return out


def _trial_stats(metrics_paths, fields):
    """median/min/max per field across N perf-capture.js metrics.json files - a single-element
    list (one trial) still reports correctly, with min==max==median and trial_count:1, so the
    report can label it a single trial rather than silently presenting it as a real range."""
    if not metrics_paths:
        return None
    rows = [load_json(p) for p in metrics_paths]
    out = {"trial_count": len(rows), "fields": {}}
    for f in fields:
        vals = [r.get(f) for r in rows if r.get(f) is not None]
        out["fields"][f] = {"median": statistics.median(vals), "min": min(vals), "max": max(vals)} if vals else None
    return out


TRIAL_FIELDS = ["time_to_usable_ms", "list_usable_ms", "detail_usable_ms",
                "total_scripting_ms", "longest_task_ms", "long_task_count"]


def build_compare_report(args):
    data = {"generated_note": "Zero-install HTML - open report.html directly in a browser.",
            "mode": "compare", "brand": detect_brand()}
    not_comparable = []

    def add_pair(label, before_val, after_val):
        if bool(before_val) != bool(after_val):
            not_comparable.append(f"{label}: only present for {'BEFORE' if before_val else 'AFTER'}.")

    pages = {}
    for key, label in [("analytics", "Analytics"), ("qc", "QC Report")]:
        before_har = getattr(args, f"before_har_{key}")
        after_har = getattr(args, f"after_har_{key}")
        before_novapi = getattr(args, f"before_novapi_{key}")
        after_novapi = getattr(args, f"after_novapi_{key}")
        add_pair(f"{label} HAR", before_har, after_har)
        pages[key] = {"label": label,
                      "before": _page_analysis(before_har, before_novapi),
                      "after": _page_analysis(after_har, after_novapi)}
    data["pages"] = pages

    trials = {}
    for key, label in [("analytics", "Analytics"), ("qc", "QC Report")]:
        before_paths = getattr(args, f"before_capture_{key}") or []
        after_paths = getattr(args, f"after_capture_{key}") or []
        add_pair(f"{label} Playwright capture", before_paths, after_paths)
        trials[key] = {"label": label,
                       "before": _trial_stats(before_paths, TRIAL_FIELDS),
                       "after": _trial_stats(after_paths, TRIAL_FIELDS)}
    data["trials"] = trials

    add_pair("Performance trace", args.before_trace, args.after_trace)
    data["traces"] = {
        "before": parse_trace(args.before_trace) if args.before_trace else None,
        "after": parse_trace(args.after_trace) if args.after_trace else None,
    }

    data["not_comparable"] = not_comparable
    return data


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HUB-106 Perf Report</title>
<style>
  .viz-root {
    color-scheme: light;
    --surface-1: #fcfcfb; --surface-2: #f3f2ef; --text-primary: #0b0b0b;
    --text-secondary: #52514e; --text-muted: #86857f; --grid: #dedcd6;
    --series-1: #2a78d6; --series-2: #eb6834; --series-3: #1baf7a; --good: #008300;
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) .viz-root {
      color-scheme: dark; --surface-1: #1a1a19; --surface-2: #232320; --text-primary: #f0efec;
      --text-secondary: #c3c2b7; --text-muted: #8c8b83; --grid: #3a3a36;
      --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --good: #0ca30c;
    }
  }
  :root[data-theme="dark"] .viz-root {
    color-scheme: dark; --surface-1: #1a1a19; --surface-2: #232320; --text-primary: #f0efec;
    --text-secondary: #c3c2b7; --text-muted: #8c8b83; --grid: #3a3a36;
    --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --good: #0ca30c;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--surface-1); font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; }
  .viz-root { background: var(--surface-1); color: var(--text-primary); padding: 24px 16px 48px; max-width: 1000px; margin: 0 auto; }
  h1 { font-size: 1.4rem; margin: 0 0 4px; }
  h2 { font-size: 1.1rem; margin: 32px 0 4px; }
  .sub { color: var(--text-secondary); font-size: 0.85rem; margin: 0 0 8px; }
  table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 0.83rem; }
  th, td { text-align: right; padding: 6px 9px; border-bottom: 1px solid var(--grid); }
  th:first-child, td:first-child { text-align: left; }
  th { color: var(--text-secondary); font-weight: 500; }
  tbody tr:hover { background: var(--surface-2); }
  svg text { fill: var(--text-primary); font-size: 11px; }
  svg .grid-line { stroke: var(--grid); stroke-width: 1; }
  .note { background: var(--surface-2); border-left: 3px solid var(--good); border-radius: 6px; padding: 8px 12px; font-size: 0.82rem; color: var(--text-secondary); margin: 8px 0; }
  .legend { display: flex; gap: 18px; margin: 4px 0 10px; font-size: 0.82rem; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .legend i { width: 11px; height: 11px; border-radius: 2px; display: inline-block; }
</style>
</head>
<body>
<div class="viz-root" id="root">
  <h1>HUB-106 performance report</h1>
  <p id="brand-line"></p>
  <p class="sub" id="meta-line"></p>
  <div id="sections"></div>
</div>
<script>
const DATA = __DATA_JSON__;

function el(tag, attrs, html) {
  const e = document.createElement(tag);
  for (const k in (attrs || {})) e.setAttribute(k, attrs[k]);
  if (html !== undefined) e.innerHTML = html;
  return e;
}

function table(headers, rows) {
  const t = el("table");
  t.innerHTML = "<thead><tr>" + headers.map(h => `<th>${h}</th>`).join("") + "</tr></thead>" +
    "<tbody>" + rows.map(r => "<tr>" + r.map(c => `<td>${c}</td>`).join("") + "</tr>").join("") + "</tbody>";
  return t;
}

function barChartSVG(rows, msMin, msMax, colorFn) {
  const W = 920, rowH = 26, padL = 230, padR = 80, padT = 10, padB = 30;
  const plotW = W - padL - padR;
  const H = padT + rows.length * rowH + padB;
  const x = (ms) => padL + (Math.log10(Math.max(ms, msMin)) - Math.log10(msMin)) / (Math.log10(msMax) - Math.log10(msMin)) * plotW;
  let parts = [`<svg viewBox="0 0 ${W} ${H}" width="100%" role="img">`];
  [Math.round(msMin), 10, 100, 1000, Math.round(msMax)].filter((v,i,a)=>a.indexOf(v)===i && v>=msMin && v<=msMax).forEach(tick => {
    const gx = x(tick);
    parts.push(`<line class="grid-line" x1="${gx}" y1="${padT}" x2="${gx}" y2="${H-padB}"/>`);
    parts.push(`<text x="${gx}" y="${H-padB+16}" text-anchor="middle" fill="var(--text-secondary)">${tick}ms</text>`);
  });
  rows.forEach((r, i) => {
    const y = padT + i * rowH;
    parts.push(`<text x="${padL-10}" y="${y+rowH/2+4}" text-anchor="end">${r.label}</text>`);
    const barX = x(msMin);
    const barW = Math.max(2, x(r.value) - barX);
    parts.push(`<rect x="${barX}" y="${y+4}" width="${barW}" height="${rowH-10}" rx="3" fill="${colorFn(r)}"><title>${r.label}: ${r.value.toFixed(1)}ms</title></rect>`);
    parts.push(`<text x="${barX+barW+6}" y="${y+rowH/2+4}" fill="var(--text-secondary)">${r.value.toFixed(1)}ms</text>`);
  });
  parts.push("</svg>");
  return parts.join("");
}

function timelineSVG(points, colorFn, maxOffset) {
  const W = 920, H = 160, padL = 40, padR = 20, padT = 10, padB = 24;
  const plotW = W - padL - padR, plotH = H - padT - padB;
  const x = (ms) => padL + (ms / maxOffset) * plotW;
  let parts = [`<svg viewBox="0 0 ${W} ${H}" width="100%" role="img">`];
  parts.push(`<line class="grid-line" x1="${padL}" y1="${padT}" x2="${padL}" y2="${H-padB}"/>`);
  parts.push(`<line class="grid-line" x1="${padL}" y1="${H-padB}" x2="${W-padR}" y2="${H-padB}"/>`);
  points.forEach(p => {
    const cx = x(p.offset_ms);
    const cy = padT + plotH - Math.min(1, p.value / p.scaleMax) * plotH;
    parts.push(`<circle cx="${cx}" cy="${cy}" r="3" fill="${colorFn(p)}" opacity="0.75"><title>${p.label}</title></circle>`);
  });
  parts.push(`<text x="${padL}" y="${H-6}" fill="var(--text-muted)">0ms</text>`);
  parts.push(`<text x="${W-padR}" y="${H-6}" text-anchor="end" fill="var(--text-muted)">${maxOffset.toFixed(0)}ms</text>`);
  parts.push("</svg>");
  return parts.join("");
}

function section(title, note, bodyNode) {
  const s = document.createElement("div");
  s.appendChild(el("h2", {}, title));
  if (note) s.appendChild(el("div", {class: "note"}, note));
  s.appendChild(bodyNode);
  return s;
}

function dualWaterfallSVG(beforeReqs, afterReqs, windowMs) {
  const W = 920, laneH = 90, padL = 40, padR = 20, padT = 20, padB = 24;
  const plotW = W - padL - padR;
  const H = padT + laneH * 2 + padB + 20;
  const x = (ms) => padL + (Math.min(ms, windowMs) / windowMs) * plotW;
  const barH = 6;
  let parts = [`<svg viewBox="0 0 ${W} ${H}" width="100%" role="img">`];
  parts.push(`<text x="${padL}" y="${padT - 6}" fill="var(--text-muted)" font-size="11">BEFORE</text>`);
  parts.push(`<text x="${padL}" y="${padT + laneH - 6}" fill="var(--text-muted)" font-size="11">AFTER</text>`);
  [beforeReqs, afterReqs].forEach((reqs, lane) => {
    const laneY = padT + lane * laneH;
    const color = lane === 0 ? "var(--series-1)" : "var(--series-2)";
    (reqs || []).filter(r => r.offset_ms < windowMs).forEach((r, i) => {
      const y = laneY + (i % Math.floor((laneH - 10) / (barH + 2))) * (barH + 2);
      const bx = x(r.offset_ms);
      const bw = Math.max(1.5, x(r.offset_ms + r.total_ms) - bx);
      parts.push(`<rect x="${bx}" y="${y}" width="${bw}" height="${barH}" rx="1.5" fill="${color}" opacity="0.8"><title>${r.method} ${r.route}: ${r.total_ms.toFixed(1)}ms @ ${r.offset_ms.toFixed(0)}ms</title></rect>`);
    });
  });
  parts.push(`<line class="grid-line" x1="${padL}" y1="${padT+laneH*2+4}" x2="${W-padR}" y2="${padT+laneH*2+4}"/>`);
  parts.push(`<text x="${padL}" y="${H-4}" fill="var(--text-muted)" font-size="11">0ms</text>`);
  parts.push(`<text x="${W-padR}" y="${H-4}" text-anchor="end" fill="var(--text-muted)" font-size="11">${windowMs}ms</text>`);
  parts.push("</svg>");
  return parts.join("");
}

function pctCell(before, after) {
  if (before === null || before === undefined || after === null || after === undefined || before === 0) return "-";
  const pct = (after - before) / before * 100;
  const sign = pct > 0 ? "+" : "";
  const cls = pct > 0 ? "bad" : (pct < 0 ? "good" : "");
  return `<span class="${cls}">${sign}${pct.toFixed(1)}%</span>`;
}

function renderCompare() {
  const sections = document.getElementById("sections");
  document.querySelector("h1").textContent = "HUB-106: Before vs After";
  document.getElementById("brand-line").textContent = `Brand: NovApi=${DATA.brand.novapi}, NovApp=${DATA.brand.novapp}`;

  if (DATA.not_comparable.length) {
    const box = el("div", {class: "note", style: "border:1px solid var(--bad); border-radius:6px; padding:10px 14px;"});
    box.appendChild(el("div", {}, "Not yet comparable (present on only one side):"));
    DATA.not_comparable.forEach(m => box.appendChild(el("div", {class: "sub"}, m)));
    sections.appendChild(box);
  }

  // Headline: 5 numbers.
  const a = DATA.pages.analytics, q = DATA.pages.qc;
  const aTrialsA = DATA.trials.analytics.after, aTrialsB = DATA.trials.analytics.before;
  const headline = [];
  if (a && a.before && a.after) {
    headline.push(["Analytics real API requests", a.before.har_totals.real, a.after.har_totals.real, pctCell(a.before.har_totals.real, a.after.har_totals.real)]);
  }
  if (aTrialsB && aTrialsA && aTrialsB.fields.total_scripting_ms && aTrialsA.fields.total_scripting_ms) {
    headline.push(["Analytics scripting (median ms)", aTrialsB.fields.total_scripting_ms.median.toFixed(0), aTrialsA.fields.total_scripting_ms.median.toFixed(0), pctCell(aTrialsB.fields.total_scripting_ms.median, aTrialsA.fields.total_scripting_ms.median)]);
    headline.push(["Analytics longest task (median ms)", aTrialsB.fields.longest_task_ms.median.toFixed(0), aTrialsA.fields.longest_task_ms.median.toFixed(0), pctCell(aTrialsB.fields.longest_task_ms.median, aTrialsA.fields.longest_task_ms.median)]);
  }
  if (aTrialsA && aTrialsA.fields.list_usable_ms) {
    headline.push(["Analytics LIST usable (AFTER only, median ms)", "-", aTrialsA.fields.list_usable_ms.median.toFixed(0), "-"]);
  }
  if (DATA.trials.qc.before && DATA.trials.qc.after) {
    const qb = DATA.trials.qc.before.fields.time_to_usable_ms, qa = DATA.trials.qc.after.fields.time_to_usable_ms;
    if (qb && qa) headline.push(["QC Report control (time-to-usable, median ms)", qb.median.toFixed(0), qa.median.toFixed(0), pctCell(qb.median, qa.median)]);
  }
  if (headline.length) {
    const wrap = document.createElement("div");
    wrap.appendChild(table(["Headline", "Before", "After", "Change"], headline));
    sections.appendChild(section("Five numbers for a manager", "Full detail below - every item labelled BEFORE-only/AFTER-only where it isn't a real comparison.", wrap));
  }

  ["analytics", "qc"].forEach(key => {
    const p = DATA.pages[key];
    if (!p.before && !p.after) return;
    const wrap = document.createElement("div");
    const bt = p.before && p.before.har_totals, at = p.after && p.after.har_totals;
    wrap.appendChild(el("p", {class: "sub"}, !p.before ? "BEFORE not available." : (!p.after ? "AFTER not available." : "")));
    if (bt || at) {
      wrap.appendChild(table(["HAR requests", "Before", "After", "Change"], [
        ["Real", bt ? bt.real : "-", at ? at.real : "-", pctCell(bt && bt.real, at && at.real)],
        ["Preflight (OPTIONS)", bt ? bt.preflight : "-", at ? at.preflight : "-", pctCell(bt && bt.preflight, at && at.preflight)],
        ["Total", bt ? bt.total : "-", at ? at.total : "-", "-"],
      ]));
    }
    const bm = p.before && p.before.matched, am = p.after && p.after.matched;
    if (bm || am) {
      const routes = new Set([...(bm ? Object.keys(bm.by_route) : []), ...(am ? Object.keys(am.by_route) : [])]);
      const rows = [...routes].map(r => {
        const b = bm && bm.by_route[r], aft = am && am.by_route[r];
        return [r + " (server)", b ? b.median_server_ms.toFixed(2) : "-", aft ? aft.median_server_ms.toFixed(2) : "-", pctCell(b && b.median_server_ms, aft && aft.median_server_ms)];
      }).concat([...routes].map(r => {
        const b = bm && bm.by_route[r], aft = am && am.by_route[r];
        return [r + " (browser)", b ? b.median_browser_ms.toFixed(2) : "-", aft ? aft.median_browser_ms.toFixed(2) : "-", pctCell(b && b.median_browser_ms, aft && aft.median_browser_ms)];
      }));
      wrap.appendChild(table(["Matched endpoint (median ms)", "Before", "After", "Change"], rows));
    }
    if ((p.before && p.before.har_requests) || (p.after && p.after.har_requests)) {
      const tl = document.createElement("div");
      tl.innerHTML = dualWaterfallSVG(p.before && p.before.har_requests, p.after && p.after.har_requests, 2500);
      wrap.appendChild(el("div", {class: "note"}, "Waterfall, first 2.5s, same time axis - before (top lane) vs after (bottom lane)."));
      wrap.appendChild(tl);
    }
    sections.appendChild(section(`${p.label} - HAR`, null, wrap));
  });

  ["analytics", "qc"].forEach(key => {
    const t = DATA.trials[key];
    if (!t.before && !t.after) return;
    const wrap = document.createElement("div");
    const labelOf = {time_to_usable_ms: "time_to_usable_ms (network-idle proxy)", list_usable_ms: "list_usable_ms (DOM)",
                     detail_usable_ms: "detail_usable_ms (DOM)", total_scripting_ms: "total_scripting_ms",
                     longest_task_ms: "longest_task_ms", long_task_count: "long_task_count"};
    const rows = [];
    TRIAL_FIELDS_JS.forEach(f => {
      const b = t.before && t.before.fields[f], aft = t.after && t.after.fields[f];
      if (!b && !aft) return;
      rows.push([labelOf[f],
        b ? `${b.median.toFixed(0)} (${b.min.toFixed(0)}-${b.max.toFixed(0)})` : "-",
        aft ? `${aft.median.toFixed(0)} (${aft.min.toFixed(0)}-${aft.max.toFixed(0)})` : "-",
        pctCell(b && b.median, aft && aft.median)]);
    });
    wrap.appendChild(el("p", {class: "sub"},
      `Before: ${t.before ? t.before.trial_count + ' trial' + (t.before.trial_count>1?'s':'') : 'n/a'}. After: ${t.after ? t.after.trial_count + ' trial' + (t.after.trial_count>1?'s':'') : 'n/a'}. Median (min-max).`));
    wrap.appendChild(table(["Playwright metric", "Before", "After", "Change (median)"], rows));
    sections.appendChild(section(`${t.label} - Playwright capture`, null, wrap));
  });

  const tb = DATA.traces.before, ta = DATA.traces.after;
  if (tb || ta) {
    const wrap = document.createElement("div");
    wrap.appendChild(el("p", {class: "sub"}, !tb ? "BEFORE trace not available." : (!ta ? "AFTER trace not available." : "")));
    const row = (label, bv, av) => [label, bv !== undefined && bv !== null ? bv : "-", av !== undefined && av !== null ? av : "-", pctCell(bv, av)];
    wrap.appendChild(table(["Trace metric", "Before", "After", "Change"], [
      row("Total scripting ms (tasks >50ms)", tb && !tb.error && tb.total_scripting_ms, ta && !ta.error && ta.total_scripting_ms),
      row("Longest task ms", tb && !tb.error && tb.longest_task_ms, ta && !ta.error && ta.longest_task_ms),
      row("Long task count (>50ms)", tb && !tb.error && tb.long_task_count, ta && !ta.error && ta.long_task_count),
      row("Main-thread busy ms", tb && !tb.error && tb.main_thread_busy_ms, ta && !ta.error && ta.main_thread_busy_ms),
    ]));
    sections.appendChild(section("Performance trace - main thread", null, wrap));

    if ((tb && tb.top_functions && tb.top_functions.length) || (ta && ta.top_functions && ta.top_functions.length)) {
      const fwrap = document.createElement("div");
      const names = new Set([...(tb ? tb.top_functions.map(f=>f.function) : []), ...(ta ? ta.top_functions.map(f=>f.function) : [])]);
      const byName = (tf, name) => (tf || []).find(f => f.function === name);
      fwrap.appendChild(table(["Function", "Before self ms", "After self ms", "Change"],
        [...names].map(n => {
          const b = byName(tb && tb.top_functions, n), af = byName(ta && ta.top_functions, n);
          return [n, b ? b.self_ms.toFixed(1) : "-", af ? af.self_ms.toFixed(1) : "-", pctCell(b && b.self_ms, af && af.self_ms)];
        }).sort((x,y) => (parseFloat(y[2])||0) - (parseFloat(x[2])||0)).slice(0, 10)));
      sections.appendChild(section("Top JS functions by self time", "Matched by function name - a name only on one side appears with \"-\" on the other.", fwrap));
    }
  }
}

const TRIAL_FIELDS_JS = ["time_to_usable_ms", "list_usable_ms", "detail_usable_ms", "total_scripting_ms", "longest_task_ms", "long_task_count"];

const sections = document.getElementById("sections");
let metaParts = [];

if (DATA.mode === "compare") {
  renderCompare();
} else if (DATA.brand) {
  const ok = DATA.brand.novapi === "NovAI" && DATA.brand.novapp === "NovAI";
  const bl = document.getElementById("brand-line");
  bl.textContent = `Brand: NovApi=${DATA.brand.novapi}, NovApp=${DATA.brand.novapp}` + (ok ? " (NovAI, as TAS requires)" : " — NOT NovAI on both sides, this measurement may not represent TAS");
  bl.style.cssText = ok ? "color: var(--good); font-weight: 600; margin: 0 0 4px;" : "color: var(--series-2); font-weight: 700; margin: 0 0 4px;";
}

if (DATA.novapi_summary) {
  metaParts.push(`NovApi log window: ${DATA.novapi_window.start} → ${DATA.novapi_window.end}`);
  const rows = Object.entries(DATA.novapi_summary).map(([k,v]) => ({label: k, value: v.median_ms, count: v.count, slowest: v.slowest_ms}));
  const msMax = Math.max(...rows.map(r => r.slowest), 10);
  const wrap = document.createElement("div");
  wrap.innerHTML = barChartSVG(rows.map(r=>({label:`${r.label} (n=${r.count})`, value: r.value})), 1, msMax, () => "var(--series-1)");
  wrap.appendChild(table(["Endpoint","n","Median ms","Slowest ms","Total ms"],
    Object.entries(DATA.novapi_summary).map(([k,v]) => [k, v.count, v.median_ms.toFixed(2), v.slowest_ms.toFixed(2), v.total_ms.toFixed(1)])));
  sections.appendChild(section("NovApi server time per endpoint", "Server-measured (morgan log), not client wall-clock.", wrap));

  const tl = document.createElement("div");
  const maxOff = Math.max(...DATA.novapi_window.requests.map(r => r.offset_ms), 1);
  const scaleMax = Math.max(...DATA.novapi_window.requests.map(r => r.server_ms), 1);
  tl.innerHTML = timelineSVG(DATA.novapi_window.requests.map(r => ({offset_ms: r.offset_ms, value: r.server_ms, scaleMax, label: `${r.route}: ${r.server_ms.toFixed(1)}ms`})), () => "var(--series-1)", maxOff);
  sections.appendChild(section("Request timeline (NovApi)", "Each dot is one request; height is its server time.", tl));
}

if (DATA.har_summary) {
  const t = DATA.har_request_totals;
  metaParts.push(`HAR requests: ${t.total} (${t.real} real, ${t.preflight} preflight OPTIONS), peak concurrency ${DATA.har_concurrency}`);
  const wrap = document.createElement("div");
  wrap.appendChild(table(["Endpoint","n","Median total ms","Slowest total ms","Median wait ms","Preflights"],
    Object.entries(DATA.har_summary).map(([k,v]) => [k, v.count, v.median_total_ms.toFixed(2), v.slowest_total_ms.toFixed(2), v.median_wait_ms.toFixed(2), v.preflight_count ?? "-"])));
  sections.appendChild(section("Browser (HAR) time per endpoint", `Peak concurrent in-flight requests: ${DATA.har_concurrency}${DATA.har_concurrency > 1 && DATA.har_concurrency < DATA.har_requests.length ? " — staircase pattern" : ""}.`, wrap));

  const tl = document.createElement("div");
  const maxOff = Math.max(...DATA.har_requests.map(r => r.offset_ms + r.total_ms), 1);
  tl.innerHTML = timelineSVG(DATA.har_requests.map(r => ({offset_ms: r.offset_ms, value: r.total_ms, scaleMax: Math.max(...DATA.har_requests.map(x=>x.total_ms),1), label: `${r.route}: ${r.total_ms.toFixed(1)}ms (wait ${r.wait_ms.toFixed(1)}ms)`})), () => "var(--series-2)", maxOff);
  sections.appendChild(section("Request timeline (browser)", "Each dot is one request; height is its total client-measured time.", tl));
}

if (DATA.combined) {
  const wrap = document.createElement("div");
  wrap.appendChild(el("p", {class:"sub"}, `Matched ${DATA.combined.matched_count} requests (${DATA.combined.how_matched}). Unmatched: ${DATA.combined.unmatched_novapi_count} NovApi-log requests, ${DATA.combined.unmatched_har_count} HAR requests - every one listed below by endpoint and why, nothing dropped silently.`));
  wrap.appendChild(table(["Endpoint","Server ms","Browser total ms","Browser wait ms","Browser overhead ms"],
    DATA.combined.pairs.map(p => [p.route, p.server_ms.toFixed(2), p.browser_total_ms.toFixed(2), p.browser_wait_ms.toFixed(2), Math.max(0, p.browser_total_ms - p.server_ms).toFixed(2)])));
  sections.appendChild(section("Browser time vs. server time (matched requests)", null, wrap));

  if (Object.keys(DATA.combined.unmatched_novapi_by_route).length) {
    const w2 = document.createElement("div");
    w2.appendChild(table(["Endpoint (NovApi-log side)","n","Why unmatched"],
      Object.entries(DATA.combined.unmatched_novapi_by_route).map(([k,v]) => [k, v.count, v.reason])));
    sections.appendChild(section("Unmatched - NovApi log", "Requests in the NovApi log with no paired HAR entry.", w2));
  }
  if (Object.keys(DATA.combined.unmatched_har_by_route).length) {
    const w3 = document.createElement("div");
    w3.appendChild(table(["Endpoint (HAR side)","n","Why unmatched"],
      Object.entries(DATA.combined.unmatched_har_by_route).map(([k,v]) => [k, v.count, v.reason])));
    sections.appendChild(section("Unmatched - HAR", "Requests in the HAR with no paired NovApi-log entry.", w3));
  }
}

if (DATA.breakdown) {
  const wrap = document.createElement("div");
  wrap.appendChild(table(["Endpoint","n","NovApi ms","OpenSearch ms","Postgres ms","Rest ms"],
    Object.entries(DATA.breakdown).map(([k,v]) => [k, v.count, v.novapi_median_ms.toFixed(2), v.opensearch_median_ms.toFixed(2), v.postgres_median_ms.toFixed(2), v.rest_median_ms.toFixed(2)])));
  sections.appendChild(section("Where NovApi's time goes (median per request)", "Rest = S3 + Node/Express time not accounted for by OpenSearch or Postgres.", wrap));
}

if (DATA.trace_summary) {
  const t = DATA.trace_summary;
  const wrap = document.createElement("div");
  if (t.error) {
    wrap.appendChild(el("p", {class:"sub"}, `Could not read this trace: ${t.error}`));
  } else {
    const notes = [t.main_thread_note, t.run_task_note, t.top_functions_note, t.render_settle_note].filter(Boolean);
    if (notes.length) wrap.appendChild(el("p", {class:"sub"}, notes.join(" · ")));
    const m = DATA.capture_metrics;
    const header = ["Metric", "Chrome trace"].concat(m ? ["Playwright capture"] : []);
    const row = (label, traceVal, mKey) => [label, traceVal].concat(m ? [m[mKey] !== undefined ? m[mKey] : "-"] : []);
    wrap.appendChild(table(header, [
      row("Total scripting ms (tasks >50ms)", t.total_scripting_ms.toFixed(1), "total_scripting_ms"),
      row("Longest task ms", t.longest_task_ms.toFixed(1), "longest_task_ms"),
      row("Long task count (>50ms)", t.long_task_count, "long_task_count"),
      row("Main-thread busy ms (all tasks)", t.main_thread_busy_ms.toFixed(1), null),
      row("Top-level task count", t.run_task_count, null),
      row("Last weld_test_reports response -> settle ms", t.render_settle_ms !== null ? t.render_settle_ms.toFixed(1) : "n/a", null),
    ]));
    sections.appendChild(section("Browser Performance trace", m ? "Chrome trace vs. this session's own Playwright capture (perf-capture.js) - same field definitions, directly comparable." : "Open the trace's own HAR/metrics.json alongside this (--capture-metrics) for a side-by-side.", wrap));

    if (t.top_functions && t.top_functions.length) {
      const fwrap = document.createElement("div");
      fwrap.appendChild(table(["Function", "File", "Line", "Self ms", "Self %"],
        t.top_functions.map(f => [f.function, f.url || "-", f.line ?? "-", f.self_ms.toFixed(1), f.self_pct.toFixed(1) + "%"])));
      sections.appendChild(section("Top JS functions by self time", `Sampled ${t.sampled_total_ms.toFixed(0)}ms total on the main thread.`, fwrap));
    }
  }
}

if (DATA.mode !== "compare") {
  document.getElementById("meta-line").textContent = metaParts.join(" · ") || "No input data.";
}
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--novapi-log")
    ap.add_argument("--har")
    ap.add_argument("--trace", help="a Chrome DevTools Performance recording (raw trace JSON)")
    ap.add_argument("--capture-metrics", help="a *-metrics.json from perf-capture.js, shown next to --trace")
    ap.add_argument("--os-container")
    ap.add_argument("--pg-container")
    ap.add_argument("--out", required=True, help="output directory for report.html + data.json")

    ap.add_argument("--compare", action="store_true",
                     help="BEFORE/AFTER comparison mode - needs --before-X/--after-X flags below instead of --har/--novapi-log/--trace")
    for key, label in [("analytics", "Analytics"), ("qc", "QC Report")]:
        ap.add_argument(f"--before-har-{key}", help=f"{label} HAR, BEFORE")
        ap.add_argument(f"--after-har-{key}", help=f"{label} HAR, AFTER")
        ap.add_argument(f"--before-novapi-{key}", help=f"{label}'s matching NovApi-log slice, BEFORE")
        ap.add_argument(f"--after-novapi-{key}", help=f"{label}'s matching NovApi-log slice, AFTER")
        ap.add_argument(f"--before-capture-{key}", action="append",
                         help=f"{label} perf-capture.js metrics.json, BEFORE - repeatable for multiple trials")
        ap.add_argument(f"--after-capture-{key}", action="append",
                         help=f"{label} perf-capture.js metrics.json, AFTER - repeatable for multiple trials")
    ap.add_argument("--before-trace", help="owner's Performance trace, BEFORE")
    ap.add_argument("--after-trace", help="owner's Performance trace, AFTER")

    args = ap.parse_args()

    if args.compare:
        data = build_compare_report(args)
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "data.json"), "w") as f:
            json.dump(data, f, indent=2, default=str)
        html = HTML_TEMPLATE.replace("__DATA_JSON__", json.dumps(data, default=str))
        with open(os.path.join(args.out, "report.html"), "w") as f:
            f.write(html)
        print(f"report: {os.path.join(args.out, 'report.html')}")
        print(f"data:   {os.path.join(args.out, 'data.json')}")
        return

    if not args.novapi_log and not args.har and not args.trace:
        sys.exit("need at least one of --novapi-log, --har or --trace (or --compare for a before/after report)")

    data = build_report(args)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "data.json"), "w") as f:
        json.dump(data, f, indent=2, default=str)
    html = HTML_TEMPLATE.replace("__DATA_JSON__", json.dumps(data, default=str))
    with open(os.path.join(args.out, "report.html"), "w") as f:
        f.write(html)
    print(f"report: {os.path.join(args.out, 'report.html')}")
    print(f"data:   {os.path.join(args.out, 'data.json')}")


if __name__ == "__main__":
    main()

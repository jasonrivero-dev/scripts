# TRD: novhub-local-stack Component Control

**Status:** Draft
**Author:** Jason Rivero
**Date:** 2026-11-17
**Related PRD:** [PRD.md](PRD.md)

---

## Architecture Overview

`steps/*.sh` stays exactly where it is and exactly as it is today — sourced-only, no shebang,
no execute bit, owned entirely by `run-novhub.sh`/`reset.sh`/`setup-host.sh`/
`opensearch-resize-heap.sh`, which keep sourcing it from `steps/<name>.sh` unchanged.

The shared dispatch logic (help text, `start`/`stop`/`status` → `_up`/`_down`/`_check` mapping,
the "no persistent state" fallback for a component missing one of those) lives **once**, as a
new `component_dispatch(name, verb)` function in `lib/common.sh` — not duplicated per file. Each
component gets a **thin standalone wrapper script** at the top level of `novhub-local-stack/`
(same shape as `opensearch-resize-heap.sh`: shebang, `set -euo pipefail`, source `lib/common.sh`
+ the relevant `steps/<name>.sh`) whose entire body is one call into that shared function —
balancing "thin wrapper" against "don't duplicate the same dispatch logic nine times." No
dual-mode/`BASH_SOURCE` guard trickery is needed — the wrapper is always executed,
`steps/<name>.sh` is always sourced; each file has exactly one mode.

```
run-novhub.sh start|stop|status [component]
        |
        +-- no [component]  -> existing ORDERED_STEPS loop, unchanged (cmd_up/cmd_down/cmd_status)
        |
        +-- [component] given -> validate against the component registry, then call
                                  component_dispatch "$component" "$cmd"  (shared helper, below)

novhub-local-stack/<component>.sh   (NEW, thin wrapper - e.g. opensearch.sh, novapi.sh, ...)
        |
        +-- source lib/common.sh, source steps/<component>.sh
        +-- component_dispatch "<name>" "$@"   <- the wrapper's entire body, one line

lib/common.sh: component_dispatch(name, verb)   (NEW, shared - used by every wrapper AND by
        |                                         run-novhub.sh's targeted-component path)
        +-- verb is "", "-h", or "--help" -> print usage, return 0 (no prereqs check needed -
        |                                     printing usage text requires nothing to be installed)
        +-- else -> prereqs_check first (step 0, every real call - idempotent, read-only; lib/
        |           common.sh sources steps/prereqs.sh itself so this is always available,
        |           reused verbatim, not duplicated). Fails -> return its exit code immediately,
        |           do not proceed to the component.
        +-- verb is start/stop/status -> map to <name>_up/_down/_check
                +-- function exists (declare -f) -> call it, return its exit code
                +-- function doesn't exist -> log "<name> has no persistent state to <verb>",
                    return 0   (this is what makes sync's stop/status and prereqs' start/stop
                    "just work" with no per-component special-casing: sync has no sync_down/
                    sync_check, prereqs has no prereqs_up/prereqs_down, so each naturally falls
                    into this branch instead of needing hardcoded exceptions)
                +-- unrecognized verb -> error, return 1

novhub-local-stack/steps/<component>.sh   (UNCHANGED - still sourced-only, same file, same path)
```

Idempotency carries through unchanged: `component_dispatch` and every wrapper only ever call
the existing `<name>_up`/`_down`/`_check` functions, which are already idempotent (unchanged
bodies) — re-running `start` on an already-correct state still prints `already ...` and changes
nothing, whether invoked standalone or via `run-novhub.sh`. New code added by this feature
(`component_dispatch`, the 9 wrapper files, `run-novhub.sh`'s dispatch) keeps comments to the
repo's standing limit — one line, only where a reader couldn't tell why from the code itself.

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| File layout | `steps/*.sh` stays in place, unchanged; add one new thin wrapper script per component at the top level | Owner's explicit preference; also the lower-risk option — zero changes to `run-novhub.sh`/`reset.sh`/`setup-host.sh`/`opensearch-resize-heap.sh`'s existing `source steps/<name>.sh` lines |
| Wrapper mechanism | Plain standalone script (shebang, `set -euo pipefail`, `-h`/`--help` first, then source `lib/common.sh` + `steps/<name>.sh`, then dispatch) | Identical to the existing `opensearch-resize-heap.sh` convention already in this repo — no new idiom introduced, no `BASH_SOURCE` dual-mode guard needed since each file now has exactly one mode |
| CLI verbs | `start`/`stop`/`status`; no `up`/`down` alias | Matches the PRD's approved Scope decision |
| Component registry | Extend the existing `ORDERED_STEPS` array (`ALL_COMPONENTS = ORDERED_STEPS + sync`), not a second hardcoded list | One source of truth; avoids the two lists drifting apart |
| `sync`'s verbs | Only `start` does real work; `stop`/`status` print a one-line explanation and exit 0 | `sync_up` has no `_check`/`_down` counterpart today — it's a one-shot job, not a persistent component. Inventing fake check/stop behavior would print dishonest output |
| `prereqs.sh` wrapper | New thin wrapper added (sources `steps/prereqs.sh`, unchanged), gets `--help`, direct run does `prereqs_check`; **not** added to the component registry | It's a pre-flight gate that always runs first (unchanged from today), not a start/stop/status component — matches the PRD's component list, which excludes it |
| `prereqs_check` placement | Runs automatically as step 0 inside `component_dispatch` itself, for every real `start`/`stop`/`status` call (standalone wrapper or targeted `run-novhub.sh`) — not a selectable component, not re-implemented, just reused | Owner's explicit direction: it's idempotent/read-only, so it should run everywhere a component is actually touched, not only through the whole-stack `run-novhub.sh up` path (today's gap: a standalone wrapper would otherwise skip it entirely) |
| Internal function bodies | No changes, no new logging added inside any `_check`/`_up`/`_down` | PRD Non-Goals forbid changing internal component logic. The existing `log`/`warn`/`error` calls already narrate every check/action (confirmed by reading every `steps/*.sh` file) — the actual gap is CLI-level (targeting, help, clear errors), not logging-level |

## Data Model

No data model changes. This repo has no database/ORM layer of its own (Bash tooling only, per
`CLAUDE.md` Structural Overrides); NovApi's and NovData's own schemas are untouched — this
feature only changes how existing shell functions are invoked.

## CLI Contract

(This repo has no web API — this section replaces "API Contract" with the actual interface
being built, per `CLAUDE.md`'s Structural Overrides pattern.)

### `run-novhub.sh start|stop|status [component]`

```text
run-novhub.sh start [component]     # no component = whole stack, existing fixed order
run-novhub.sh stop [component]
run-novhub.sh status [component]
run-novhub.sh -h|--help
```

Valid `[component]` values: `opensearch novdata novapi novapp plcsim plcnode luna sync`
(`sync` only does real work under `start`; see Stack Decisions). Omitting `[component]` runs
the existing `ORDERED_STEPS` sequence (`opensearch novdata novapi novapp plcsim plcnode luna`)
exactly as today's `up`/`down`/`status` do — `sync` is never implicitly included, matching
current behavior.

**Exit codes** (unchanged convention, just reachable per-component now):

| Code | Condition |
|------|-----------|
| 0    | Success, or an idempotent no-op (prints `already ...`) |
| 1    | A real failure, an unknown component name, or an unknown verb |
| 2    | Manual action needed (existing convention — PLCSIM/plc-node/LUNA `_check` functions) |

### `novhub-local-stack/<component>.sh start|stop|status`

```
<component>.sh start|stop|status   # opensearch, novdata, novapi, novapp, plcsim, plcnode, luna
sync.sh start                      # sync: start only; stop/status print an explanation, exit 0
prereqs.sh status                  # prereqs: status only (read-only host check), no start/stop
<component>.sh -h|--help
```

Both open design questions from the first draft are resolved — see Clarifications below.

## Implementation Plan

### Step 1: Add the shared `component_dispatch` helper to `lib/common.sh`

- **Files:** `novhub-local-stack/lib/common.sh`
- **What:** Source `steps/prereqs.sh` from this file's own preamble (`BASH_SOURCE[0]`-relative,
  alongside where it already sources `dev-log-lib`), so `prereqs_check` is always available
  wherever `lib/common.sh` is sourced — no file needs to source it separately for this feature
  to work (existing explicit `source steps/prereqs.sh` lines in `run-novhub.sh`/`setup-host.sh`
  are left as-is; sourcing the same file twice is harmless). Add one new function,
  `component_dispatch(name, verb)`: empty/`-h`/`--help` verb prints a generic usage block and
  returns 0 (no prereqs check for this path); any other verb first runs `prereqs_check` and
  returns its exit code immediately if it fails; otherwise maps `start`/`stop`/`status` to
  `<name>_up`/`_down`/`_check`; if that function exists (`declare -f`), call it and return its
  exit code; if it doesn't exist, `log` a one-line "`<name>` has no persistent state to `<verb>`"
  and return 0 (this is what makes `sync`'s `stop`/`status` and `prereqs`'s `start`/`stop`
  behave sensibly with zero per-component special-casing); any other verb errors and returns 1.
  No changes to any existing function in this file or in `steps/*.sh`.
- **Verify:** `bash -n`. Owner manually sources the file and calls `component_dispatch
  opensearch status` (after also sourcing `steps/opensearch.sh`) to confirm it reaches
  `prereqs_check` then `opensearch_check` in order, and `component_dispatch sync stop` to
  confirm the friendly fallback message.

### Step 2: Add the 9 thin wrapper scripts

- **Files:** `novhub-local-stack/{opensearch,novdata,novapi,novapp,plcsim,plcnode,luna,sync,prereqs}.sh`
  (new files, top level, alongside `opensearch-resize-heap.sh`/`perf-seed.sh`)
- **What:** Each file is the same four lines: shebang, `set -euo pipefail`, `SCRIPT_DIR` via
  `readlink -f "$0"` (matching this repo's existing standalone-script convention), `source
  "$SCRIPT_DIR/lib/common.sh"` then `source "$SCRIPT_DIR/steps/<name>.sh"`, then
  `component_dispatch <name> "$@"`. `chmod +x` all 9. `steps/*.sh` is not touched.
- **Verify:** `bash -n` all 9. Owner manually runs `--help` and `status` standalone on at least
  one real component (e.g. `./novhub-local-stack/opensearch.sh status`, confirming it matches
  what `run-novhub.sh status` already shows today), plus `sync.sh stop` and `prereqs.sh start`
  to confirm the friendly fallback message appears instead of an error.

### Step 3: Rewrite `run-novhub.sh`'s verb handling

- **Files:** `run-novhub.sh`
- **What:** Rename `up`/`down`/`status` to `start`/`stop`/`status` (no alias). Add
  `ALL_COMPONENTS=("${ORDERED_STEPS[@]}" sync)`. Add optional `[component]` parsing: when given,
  validate against `ALL_COMPONENTS` (clear error + the valid list if not found), then call the
  same shared `component_dispatch "$component" "$cmd"` from Step 1 — no new dispatch logic
  written here, so a wrapper script and `run-novhub.sh start <component>` are guaranteed
  identical (same function, same call). When `[component]` is omitted, run the existing
  `cmd_up`/`cmd_down`/`cmd_status` loops unchanged. Update `usage()` to document the new verbs
  and the component list.
- **Verify:** `bash -n`. Owner manually runs: `start opensearch` (targeted), `status novapi`
  (targeted, no state change), `start badname` (expect a clear error naming the unknown
  component and listing valid ones), and `start`/`status` with no component (expect identical
  behavior to today's `up`/`status` across the whole stack).

### Step 4: Update `README.md`

- **Files:** `novhub-local-stack/README.md`
- **What:** Add one row per new wrapper script to the Scripts table (the `steps/*.sh` row stays,
  unchanged, since those files are untouched). Replace every `up`/`down` verb reference with
  `start`/`stop`. Add a short "Controlling one component" section showing both invocation styles
  (standalone wrapper script, and `run-novhub.sh start|stop|status <component>`), referencing
  the OpenSearch manual-ops section already there as the detailed example.
- **Verify:** Owner reads the updated sections and confirms accuracy against the actual script
  behavior from Steps 1–3.

## Test Plan

### Unit Tests

N/A — no automated test framework exists in this repo for shell scripts (`CLAUDE.md`
Structural Overrides). The Layer 1 equivalent (`bash -n` on every changed file) is listed under
each step's Verify above, run before each commit.

### Integration Tests

No automated E2E framework either (same Structural Overrides). Per standing project feedback,
the owner validates manually once the code is stable — the agent does not run these to "confirm"
on the owner's behalf. Suggested manual pass, covering every PRD Acceptance Criterion:

| Scenario | Manual Command | PRD Criterion |
|----------|-----------------|---------------|
| Standalone single component | `./novhub-local-stack/novapi.sh start` while opensearch/novapp are stopped; confirm only NovApi (+ its Postgres) changes state | AC1 |
| Dispatch parity | `./novhub-local-stack/run-novhub.sh start novapi` vs. the standalone run above; compare output and end state | AC2 |
| Idempotent no-op | Run `start` twice on an already-up component; expect `already ...` and no changes | AC3 |
| Whole-stack unchanged | `run-novhub.sh start` with no argument on a fully-down stack; expect the existing fixed order, unchanged | AC4 |
| Help text | `-h`/`--help` on every component script and on `run-novhub.sh` | AC5 |
| Targeted status | `run-novhub.sh status novapp` while other components vary; confirm no state changes anywhere | AC6 |
| Unknown component | `run-novhub.sh start doesnotexist`; expect a clear error listing valid names | AC7 |

## Rollout

- [ ] No migration — pure script refactor, no persisted state or schema touched.
- [ ] Owner manually runs the Integration Tests table above once implementation is complete.
- [ ] Rollback plan: `git revert` the feature's commits (or `git checkout <pre-change-sha> --
      novhub-local-stack/`). No component's own data (OpenSearch index, Postgres rows) is
      touched by this refactor, so reverting the code has no data-side effect either way.

## Clarifications

> Answers to UNBACKED assumptions raised during `/implement`. Each row backs later steps and
> sessions as `TRD: Clarifications #<n>`. Never record secret values here.

| # | Step | Question | Answer | Source | Date |
|---|------|----------|--------|--------|------|
| 1 | Step 3 | Keep `run-novhub.sh sync` as a standalone verb, or replace it with `start sync`? | Replaced — no alias kept; `start sync` is the only way to run it. | user | 2026-11-17 |
| 2 | Step 1 | Should `prereqs` be a selectable component (`start\|stop\|status prereqs`), or run automatically elsewhere? | Neither as originally framed — `prereqs_check` runs automatically as step 0 inside `component_dispatch`, for every real verb call (standalone or targeted), reusing `steps/prereqs.sh` unchanged. Not a selectable component. | user | 2026-11-17 |

## Traceability Matrix

| PRD Acceptance Criterion | TRD Step | Test |
|---------------------------|----------|------|
| Standalone single-component start, no cross-component side effects | Step 2 | Integration: Standalone single component |
| `run-novhub.sh start <component>` identical to standalone | Step 3 | Integration: Dispatch parity |
| Already-up component re-run is a no-op (`already ...`) | Steps 1–2 | Integration: Idempotent no-op |
| No-component `start` runs the whole stack in the existing fixed order | Step 3 | Integration: Whole-stack unchanged |
| `-h`/`--help` on every component script and on `run-novhub.sh` | Steps 2–3 | Integration: Help text |
| `status <component>` reports only that component, no state changes | Step 3 | Integration: Targeted status |
| Unknown component errors clearly, lists valid names | Step 3 | Integration: Unknown component |

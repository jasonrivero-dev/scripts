# Quick: novhub-local-stack reset script

**Track:** Quick
**Status:** Approved
**Date:** 2026-11-16
**Tickets:** (none)

## What changes
Add `novhub-local-stack/reset.sh`, a standalone dev-hygiene script (not a `run-novhub.sh`
subcommand) that selectively wipes containers/data this stack touches: NOVAPI's `cloud_db_dev`
(via its own `docker compose`), NovData's `novdata-pg`, OpenSearch's `os-local` (container +
index), and this stack's own `.state/` pidfiles+logs. Each is independently selectable via a
flag; no flags prints usage and does nothing.

## Why
Repeated local testing can leave dirty/partial state behind in another repo's container (e.g. a
migration that failed partway, as happened with NovApi's `cloud_db_dev`), and there's currently
no tool to reset to a clean slate short of hand-run `docker` commands. `run-novhub.sh down` stays
intentionally stop-only (its own PRD's Non-Goals), so this is a separate script. Selective, not
all-or-nothing, since some components' data may need to persist between runs.

## How to check it
- `reset.sh` with no args prints usage and makes no changes
- `reset.sh --novapi-db` removes `cloud_db_dev` via `docker compose`; rerun prints `already absent`
- `reset.sh --novdata-db` removes `novdata-pg`; rerun prints `already absent`
- `reset.sh --opensearch` removes `os-local`; rerun prints `already absent`
- `reset.sh --state` stops any running background service (checked via pidfile) then clears `.state/`
- `reset.sh --all` runs all four
- `bash -n novhub-local-stack/reset.sh` passes (Layer 1 override for this repo)

## Files
- `novhub-local-stack/reset.sh` (new)

## Clarifications

> Answers to UNBACKED assumptions raised while implementing. Never record secret values here.

| # | Question | Answer | Source | Date |
|---|----------|--------|--------|------|

# PRD: md2word-gdocs-upload

**Status:** Draft
**Author:** Jaguar Rivero
**Date:** 2026-09-17
**Related TRD:** [TRD.md](TRD.md)

---

## Problem Statement

Non-technical stakeholders can't comment or edit directly on the Markdown docs this repo
produces — the existing pipeline (`tools/md2html/convert.sh`) only outputs standalone HTML,
and a plain `.docx` file still requires opening a desktop app and manually uploading it to
Drive. There is no automated path from a Markdown source tree into native Google Docs, where
stakeholders can comment/suggest/edit using tools they already know.

If this isn't built: every document that needs stakeholder review keeps requiring a manual
convert-then-upload step per file, which doesn't scale as the number of docs grows and is
easy to get wrong (wrong folder, forgotten conversion step, stale re-uploads).

## Users & Personas

| Persona | Description | Primary Need |
|---------|-------------|--------------|
| Tool operator | The repo owner, running this from the command line on their own dev machine | One command converts a Markdown tree to Google Docs, uploaded and ready to share |
| Stakeholder reader | Non-technical recipient who opens the resulting file in Google Drive | A native Google Doc they can comment/edit in directly — not an HTML file or local .docx |

## Goals

1. Running one command against a source Markdown tree produces local `.docx` files mirroring
   the source folder structure (same pattern as `tools/md2html/convert.sh`'s local output),
   with zero changes required to that existing tool or its output.
2. Every generated `.docx` is uploaded to a designated Google Drive folder, into a matching
   mirrored subfolder structure, and lands as a **native Google Doc** (not a stored `.docx`
   file) — verified via the Drive API's `mimeType: application/vnd.google-apps.document`
   conversion-on-upload behavior.
3. Headings/TOC, tables, fenced code blocks, and Mermaid diagrams all survive the full
   Markdown → `.docx` → Google Doc pipeline intact and legible.
4. Authentication is a one-time OAuth consent per machine; every run after that reuses a
   cached, auto-refreshed token with no re-prompting.

## Non-Goals (Explicitly Out of Scope)

- Does **not** modify `tools/md2html/convert.sh` or its HTML output in any way — this is a
  brand-new, separate script under `tools/md2word/`. Non-destructive to the existing tool is a
  hard requirement, not a preference.
- Does not implement Drive → local sync, or any handling of edits made in Google Docs after
  upload (one-way pipeline: Markdown → Drive, not round-trip).
- Does not support service-account or team-shared authentication in this version — personal
  OAuth user-consent only, single Google account.
- Does not attempt to preserve the HTML output's custom CSS/theming — Word/Docs styling is a
  different, simpler rendering target (headings, tables, code, images), not a visual match to
  the HTML version.
- Does not guarantee preservation of stakeholder comments/suggestions left on a previously
  uploaded Doc when it's overwritten on a later run — overwrite replaces the Doc's content, and
  whether Google Docs retains comment anchors through that replace is not something this
  feature promises or is responsible for.

## User Stories

### Must Have (P0)

- As the tool operator, I want to run a single command against a source Markdown tree so that
  every `.md` file converts to `.docx` locally, mirroring the source folder structure, without
  touching the existing HTML converter or its output.
- As the tool operator, I want the generated `.docx` files automatically uploaded to a
  designated Google Drive folder, mirrored into matching subfolders, so that I never have to
  manually upload a file.
- As the tool operator, I want to specify the destination Drive folder via a required CLI flag
  (mirroring how `-s`/`-t` work for source/target directories on the existing tool), with no
  hidden default, so uploads always go exactly where I intend.
- As the tool operator, I want re-running the tool against a file I've already uploaded to
  overwrite/update the existing Google Doc in place, rather than creating a duplicate, so my
  Drive folder doesn't accumulate copies every time I tweak a source file.
- As the tool operator, I want each uploaded file automatically converted into a native Google
  Doc (not left as a `.docx` attachment) so that stakeholders can comment/edit directly in
  Google Docs.
- As the tool operator, I want a one-time OAuth authorization that's cached and auto-refreshed
  so that I don't have to re-authenticate on every run.
- As a stakeholder reader, I want headings, tables, code blocks, and Mermaid diagrams to render
  correctly in the Google Doc so the content is usable without referring back to the source.

### Should Have (P1)

- As the tool operator, I want clear console output per file (converted / uploaded / failed) so
  I can spot problems without digging through logs.
- As the tool operator, I want the tool to fail clearly — not silently — when Drive credentials
  are missing or expired, and tell me exactly how to re-authenticate.

### Nice to Have (P2)

- As the tool operator, I want an option to skip the Drive upload step and only produce local
  `.docx` files (offline/dry-run mode), so I can review before publishing.

## Acceptance Criteria

- GIVEN a source directory containing nested `.md` files (e.g. `dir1/dir2/file1.md`,
  `dir1/file2.md`), WHEN the new `md2word` tool runs against that source and a local target
  directory, THEN a mirrored `.docx` tree is created locally under
  `<target>/<source-basename>/...` matching the source's subfolder structure exactly, and
  `tools/md2html/convert.sh` plus its own output are completely unaffected by this run.
- GIVEN a valid cached OAuth token (or a first-run browser consent flow completed
  successfully), WHEN the local `.docx` files exist, THEN each one is uploaded to the
  configured Drive destination folder, into a matching mirrored subfolder structure.
- GIVEN the tool is run without the required destination-Drive-folder CLI flag, WHEN it
  starts, THEN it fails immediately with a clear usage error, mirroring how the existing tool
  requires `-s`. There is no hardcoded or config-file default folder.
- GIVEN a Google Doc already exists at the mirrored Drive path from a previous run of the same
  source file, WHEN the tool re-uploads that file, THEN it overwrites/updates that existing
  Doc's content in place (a Drive API content update, not a new file), rather than creating a
  duplicate.
- GIVEN a `.docx` file is uploaded, WHEN the Drive API create request is made, THEN the
  request's file metadata specifies `mimeType: application/vnd.google-apps.document`, and the
  resulting Drive item opens as a native Google Doc, not a stored `.docx`.
- GIVEN a Markdown file containing headings, a table, a fenced code block, and a Mermaid
  diagram, WHEN it is converted end-to-end into a Google Doc, THEN the heading structure
  appears in the Doc's outline, the table renders as a real Docs table, the code block stays
  legible/monospaced, and the Mermaid diagram appears as an embedded image.
- GIVEN no cached OAuth token exists, WHEN the tool runs, THEN it opens a browser consent flow
  once, and on approval caches a token locally so subsequent runs do not prompt again.
- GIVEN Drive upload fails for one file (network error, invalid folder ID, expired token,
  etc.), WHEN the tool finishes its run, THEN it reports which specific file(s) failed and why,
  without aborting the rest of the batch.

## Constraints

- **Deadline:** none.
- **Tech stack:** Bash orchestration matching `tools/md2html/convert.sh`'s existing
  conventions, using `pandoc` for Markdown → `.docx` conversion. The Drive-upload/OAuth step's
  implementation language (Bash + `curl`, or a small helper in Python/Node using a Drive API
  client library) is a TRD decision, not mandated here.
- **Dependencies:** `pandoc` (already required by the existing tool); network access to
  Google's OAuth and Drive API endpoints. A Google Cloud project with the Drive API enabled
  and an OAuth 2.0 client (Desktop app type) does **not** exist yet — only a normal Google
  account does. Creating that GCP project + OAuth client is in scope as a one-time setup step
  (covered in the TRD), not a precondition assumed to already be in place.
- **Other:** Per this repo's security rules (`CLAUDE.md`), OAuth client secrets and cached
  tokens must never be hardcoded or committed — referenced via env var and/or a gitignored
  local file path, matching how `tools/jiracli/token` and `telemetry/config/configure.*` are
  already handled in this repo.

## Open Questions

> Must be empty (all answered) before TRD generation begins.

(None — all resolved during `/prd-review`:)

- Re-run/duplicate handling: **overwrite** the existing Doc in place (see Acceptance Criteria
  and the P0 user story).
- Destination Drive folder: **required CLI flag**, no hardcoded or config-file default (see
  Acceptance Criteria and the P0 user story).
- OAuth credentials: **do not exist yet** — only a normal Google account does. Creating the GCP
  project + OAuth 2.0 client is in scope as a one-time setup step for the TRD (see Constraints
  → Dependencies).

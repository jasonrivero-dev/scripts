# TRD: md2word-gdocs-upload

**Status:** Draft
**Author:** Jaguar Rivero
**Date:** 2026-09-17
**Related PRD:** [PRD.md](PRD.md)

---

## Note on template fit

This repo has no database and no HTTP API of its own (`CLAUDE.md` → `## Structural
Overrides`: Bash scripts, no framework). This feature is a CLI tool that *calls* an external
API (Google Drive) as a client. Sections below are adapted accordingly: **Data Model** is
N/A, and **API Contract** documents the external Drive API calls this tool makes, not an
API this repo exposes.

## Architecture Overview

```
Markdown source tree (-s/--source)
        │
        ▼  find -name '*.md' + mkdir -p, mirroring the source tree
            (exact idiom reused from tools/md2html/convert.sh)
tools/md2word/convert.sh  ──▶  pandoc --filter mermaid-filter -o *.docx  ──▶  Local .docx tree
   (Bash, orchestration)                                                     (-t/--target,
        │                                                                     mirrored, same as
        │  invoked once per run, after ALL local conversion finishes          md2html's output)
        ▼
tools/md2word/drive_upload.py  (Python — see Stack Decisions)
        │
        ├─ OAuth: load cached token → refresh if expired,
        │         OR first-run InstalledAppFlow (one-time browser consent)
        │
        ├─ For each relative directory in the local tree:
        │     find-or-create the matching Drive folder (mimeType=
        │     application/vnd.google-apps.folder) under the -g/--drive-folder root,
        │     caching name→id for the run to avoid duplicate lookups
        │
        └─ For each .docx file:
              query Drive for an existing file with this name under its parent folder id
                0 matches   → files.create (media=.docx bytes,
                              metadata.mimeType=application/vnd.google-apps.document)
                              ⇒ Drive auto-converts on upload ⇒ native Google Doc
                1 match     → files.update (new media content on that file id) — overwrite
                2+ matches  → files.update on the most-recently-modified match (by
                              modifiedTime) — overwrite, plus a WARN noting the duplicates
```

**Resolved (was ⚠️ ASSUMPTION, confirmed during `/trd-review` follow-up):** Google Drive
permits multiple files with the identical name in the same parent folder (unlike a
filesystem), which the PRD's "overwrite the existing Doc" criterion didn't anticipate. Decided
behavior: on 2+ matches, overwrite the most-recently-modified match (sorted by the API's
`modifiedTime` field) rather than skipping — deterministic, and matches the PRD's general
"overwrite, don't duplicate" intent even in this edge case. The tool also emits a `WARN`
(not just silent overwrite) naming the duplicate count, so the operator knows to clean up
stray copies in Drive at their convenience.

**Resolved (was ⚠️ ASSUMPTION, confirmed during `/trd-review` follow-up):** whether
`mermaid-filter` (used today only in the HTML/`--embed-resources` pipeline) produces correct
output combined with pandoc's **docx** writer was unverified — general pandoc knowledge
suggests it should work (the filter substitutes an image into the pandoc AST before any
writer runs, so it's writer-agnostic in principle), but image sizing/DPI defaults tuned for
HTML/PDF are a known risk class for docx output. The operator will verify this visually (Step
5 below) as part of implementation, rather than this being asserted as working ahead of time.
If it doesn't render correctly, fall back to pre-rendering Mermaid to PNG via `mmdc`
(mermaid-cli) and substituting the image ahead of pandoc, as Plan B — this would be a
follow-up TRD amendment, not silently absorbed into Step 4.

## Stack Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| New script location | `tools/md2word/convert.sh` (Bash orchestration) + `tools/md2word/drive_upload.py` (Python helper) | Matches PRD's explicit requirement: a brand-new, separate script that does not touch `tools/md2html/convert.sh`. |
| Local `.md`→`.docx` conversion | Bash + `pandoc`, reusing `tools/md2html/convert.sh`'s exact tree-mirroring idiom (`find`+`mapfile -d ''`, `SOURCE_BASENAME`, `OUTPUT_ROOT`, per-file `rel_path`/`rel_dir` stripping) | Already proven in this repo; PRD requires identical local-mirroring behavior. No reason to reinvent it. |
| Drive API + OAuth implementation language | **Python**, using Google's official `google-auth`, `google-auth-oauthlib`, and `google-api-python-client` libraries — invoked as a subprocess from the Bash wrapper, once per run (not once per file) | Hand-rolling OAuth token exchange/refresh and Drive's multipart/resumable upload protocol in Bash+`curl` is fragile and a real security/correctness risk (token handling, retries, error codes). Google's SDK handles this correctly. The repo already has one precedent for a non-Bash script (`celeste/send_plc_msg.py`) — this isn't a deviation from "Bash shell scripts (+ one Python script)" (`CLAUDE.md` → Structural Overrides), it's the second instance of that same allowed exception. One process per run (not per file) lets it cache Drive folder-id lookups in memory across the whole batch. |
| Python dependency management | A `tools/md2word/requirements.txt` scoped to this one tool (`google-auth`, `google-auth-oauthlib`, `google-api-python-client`) | The repo has no project-wide package manager by design (Structural Overrides), but that's about the *repo* not being one unified app — a small, scoped requirements file for one tool's Python dependencies doesn't contradict that; it's the standard way to declare them without inventing repo-wide tooling. |
| Argument parsing | Manual `while [[ $# -gt 0 ]]; do case "$1" in ... esac; done`, supporting both short and long flags (`-s`/`--source`, `-t`/`--target`, `-g`/`--drive-folder`, `-c`/`--client-secret`, `-k`/`--token-cache`, `-n`/`--no-upload`, `-h`/`--help`) | This tool has more flags (incl. two new credential-path overrides) than `md2html`'s single-char `getopts` comfortably supports with self-documenting names. `licensing/licadmin-ec2-deploy` and `telemetry/vector-test.sh` already establish this exact style in this repo for multi-flag scripts — not a new convention. |
| Logging | Inline `log()`/`warn()`/`error()` defined directly in `convert.sh` (timestamped, colored — same shape as `licadmin-ec2-deploy`'s, without its extra `section`/`step`/`cmd` UI helpers, which don't apply here) | `lib/dev-log-lib` is scoped to celeste/telemetry scripts per `README.md`; no `tools/` script sources it today. `md2html/convert.sh` uses bare `echo` with no error/warn distinction, which is too thin for a multi-stage pipeline (convert → auth → upload) where per-file, per-stage failure clarity is a P1 requirement. |
| Credential storage | `client_secret.json` (user-downloaded from Google Cloud Console, never generated by this tool) and the OAuth token cache both default to `$HOME/.config/md2word/`, fully **outside** the git repo tree — overridable via `MD2WORD_CLIENT_SECRET` / `MD2WORD_TOKEN_CACHE` env vars, following the repo-wide `VAR="${VAR:-default}"` pattern | Stronger than the repo's existing `tools/jiracli/token` pattern (in-repo-but-gitignored) — keeping secrets outside the repo entirely removes any chance of an accidental commit. Consistent with `CLAUDE.md` → Security (no hardcoded secrets, env-var-referenced). |
| Env var docs | Documented in the script's own `--help` output and in `README.md`, **not** a `.env.example` | This repo has no `.env`/dotenv convention anywhere (every existing script documents its overridable env vars in its own usage text) — introducing `.env.example` here would contradict established practice, not follow it. |

## Security

- **Does this feature handle PII, passwords, tokens, API keys, or financial data?** Yes —
  an OAuth `client_secret.json` (client ID/secret, downloaded by the operator from Google
  Cloud Console) and a cached OAuth access/refresh token, both credential-equivalent to API
  keys.
- **Where do secrets come from?** Local files only, never generated or embedded by this tool:
  `client_secret.json` is downloaded manually by the operator (Step 1); the token cache is
  written by the OAuth flow itself on first run. Both paths default to
  `$HOME/.config/md2word/` — **outside the git repo tree entirely** — and are overridable via
  `MD2WORD_CLIENT_SECRET` / `MD2WORD_TOKEN_CACHE` env vars, following this repo's existing
  `VAR="${VAR:-default}"` pattern (`licadmin-ec2-deploy`). Neither is ever hardcoded.
- **New environment variables:** `MD2WORD_CLIENT_SECRET`, `MD2WORD_TOKEN_CACHE`. Per this
  repo's Structural Overrides, there is no `.env`/dotenv convention here — these are
  documented in `convert.sh --help` and `README.md` instead, matching every other
  credential-path override in this repo (e.g. `KEY_FILE` in `licadmin-ec2-deploy`).
- **Does this feature expose user data in API responses?** N/A — no API server; Drive API
  responses (file IDs, `webViewLink`) are consumed internally and only their non-sensitive
  fields (link, filename) are printed to console. The OAuth client secret and token contents
  themselves must never be printed — only their file paths and existence, matching
  `telemetry/vector-test.sh`'s `[REDACTED]` convention for its own AWS secret.
- **Does this feature call external services?** Yes — Google's OAuth 2.0 token endpoint and
  Drive API v3. Credentials for that access are the two local files above; the Drive OAuth
  scope requested is the minimum needed (`drive.file` — access limited to files this app
  creates/opens — not the broader `drive` scope).
- Before the first commit touching this feature: confirm `$HOME/.config/md2word/` (the
  default credential location) is outside the repo and needs no `.gitignore` entry; if a
  future override ever points either path *inside* the repo, that path must be added to
  `.gitignore` before use.

## Data Model

N/A — no database, no schema. The only persistent state this feature introduces is the local
OAuth token cache file (`$HOME/.config/md2word/token.json`, JSON, managed entirely by
`google-auth-oauthlib`'s own serialization — not a format this TRD defines).

## External API Integration (Google Drive API v3)

This tool is a **client** of Google's existing Drive API — no new API is exposed by this repo.
Calls made, via `google-api-python-client`'s `drive` service (`v3`):

### Folder find-or-create

**Request** (search): `files().list(q="name='<dirname>' and '<parentId>' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false", fields="files(id,name)")`

**Request** (create, if no match): `files().create(body={"name": "<dirname>", "mimeType": "application/vnd.google-apps.folder", "parents": ["<parentId>"]}, fields="id")`

**Response:** the folder's `id`, used as `parentId` for the next path segment / for files in that directory.

**Error handling:** any API error here aborts only the branch under that folder (files within it are reported as failed with the folder-creation error as the reason); other branches continue.

### File find (for overwrite-vs-create decision)

**Request:** `files().list(q="name='<basename>.docx' and '<parentId>' in parents and trashed=false", fields="files(id,name,modifiedTime)")`

**Response handling:**
| Match count | Action |
|---|---|
| 0 | `files().create(...)` — see below |
| 1 | `files().update(fileId=<id>, media_body=<local docx path>)` — overwrites content in place, Doc stays a native Google Doc (mimeType doesn't change on update) |
| 2+ | Sort matches by `modifiedTime` descending, `files().update(fileId=<most-recent id>, ...)` — overwrite that one, and `WARN` naming the duplicate count so the operator can clean up stray copies |

### File create-with-conversion

**Request:** `files().create(body={"name": "<basename>.docx", "parents": ["<parentId>"], "mimeType": "application/vnd.google-apps.document"}, media_body=MediaFileUpload("<local docx path>", mimetype="application/vnd.openxmlformats-officedocument.wordprocessingml.document"), fields="id,webViewLink")`

**Response (success):** `id` and `webViewLink` — printed to console for the operator.

**Error codes surfaced by the API (handled per-file, do not abort the batch):**
| Code | Condition |
|------|-----------|
| 401  | Access token expired/invalid mid-run — attempt one token refresh, retry once, then fail this file |
| 403  | Insufficient permission on the target Drive folder, or Drive API not enabled on the GCP project |
| 404  | `-g/--drive-folder` ID does not exist or isn't accessible to this account |
| 429  | Rate-limited — back off and retry with jitter (max 3 attempts) before failing this file |

### OAuth token flow

- First run (no cached token, or `refresh_token` itself invalid): `google_auth_oauthlib.flow.InstalledAppFlow.from_client_secrets_file(<client_secret path>, scopes=["https://www.googleapis.com/auth/drive.file"]).run_local_server()` — opens a browser once.
- Subsequent runs: load cached `Credentials`, call `.refresh(Request())` if expired. Persist the refreshed token back to the cache file after every run.
- **Scope choice:** `drive.file` (access limited to files this app creates/opens), not the broader `drive` scope — least-privilege, and it's sufficient since this tool never needs to read arbitrary existing Drive content.

## Implementation Plan

### Step 1: `tools/md2word/README.md` — one-time setup docs

- **Files:** `tools/md2word/README.md`
- **What:** Step-by-step instructions for the one-time setup this operator doesn't have yet
  (confirmed in `/prd-review`): create a Google Cloud project, enable the Drive API, create an
  OAuth 2.0 Client ID (Desktop app type), download it as `client_secret.json`, and where to
  place it (default `$HOME/.config/md2word/client_secret.json`, or point `MD2WORD_CLIENT_SECRET`
  elsewhere). Also documents `pip install -r tools/md2word/requirements.txt`.
- **Verify:** A reader with no prior GCP experience can follow it start to finish and end up
  with a valid `client_secret.json` in the right place.

### Step 2: `tools/md2word/requirements.txt`

- **Files:** `tools/md2word/requirements.txt`
- **What:** Pin `google-auth`, `google-auth-oauthlib`, `google-api-python-client` to current
  stable major versions.
- **Verify:** `pip install -r tools/md2word/requirements.txt` succeeds in a clean venv.

### Step 3: `tools/md2word/drive_upload.py` — OAuth + Drive upload engine

- **Files:** `tools/md2word/drive_upload.py`
- **What:** A CLI Python script taking `--local-root <dir> --drive-folder-id <id> --client-secret <path> --token-cache <path>`. Walks `--local-root` recursively; for each `.docx` file, mirrors its relative directory into Drive (find-or-create folders per the External API Integration section), then finds-or-creates-or-updates the file per the match-count table above (0 → create, 1 → update, 2+ → update the most-recently-modified match plus a `WARN`). Prints one line per file: `UPLOADED <rel_path> -> <webViewLink>`, `UPDATED <rel_path> -> <webViewLink>`, `WARN <rel_path>: N duplicate names found in Drive, updated the most recently modified`, or `FAILED <rel_path>: <reason>` — machine-parseable prefixes so `convert.sh` can tally a summary. Wraps the whole run in a top-level `try/except ImportError` that prints a clear "run `pip install -r tools/md2word/requirements.txt`" hint if the Google libraries aren't installed (P1: fail clearly).
- **Verify:** Run directly against a scratch local `.docx` tree and a disposable test Drive
  folder; confirm folder mirroring (including nested subfolders, at least two levels deep),
  first-run OAuth consent, cached-token reuse on a second run, the overwrite path on a third
  run against the same files, and the duplicate-name path against a folder with two
  pre-existing same-named files.

### Step 4: `tools/md2word/convert.sh` — Bash orchestration

- **Files:** `tools/md2word/convert.sh`
- **What:** `#!/usr/bin/env bash` + `set -euo pipefail`. Manual `while`/`case` flag parser (see
  Stack Decisions) for `-s/--source` (required), `-t/--target` (default `~/Documents`, matching
  `md2html`), `-g/--drive-folder` (required, no default — per PRD), `-c/--client-secret`
  (default `$HOME/.config/md2word/client_secret.json`, env-overridable via
  `MD2WORD_CLIENT_SECRET`), `-k/--token-cache` (default `$HOME/.config/md2word/token.json`,
  env-overridable via `MD2WORD_TOKEN_CACHE`), `-n/--no-upload` (P2: local-only, skip the Python
  step entirely), `-h/--help`. Reuses `tools/md2html/convert.sh`'s exact `find`/`mapfile -d
  ''`/`SOURCE_BASENAME`/`OUTPUT_ROOT`/relative-path-stripping logic, swapping the pandoc
  invocation:
  ```bash
  pandoc "$file" \
    --from=gfm \
    --toc --toc-depth=3 \
    --filter mermaid-filter \
    --metadata title="${basename}" \
    -o "${output_path}"   # ${output_path} ends in .docx, not .html
  ```
  (Drops `--standalone`/`--embed-resources`/`--css`/`--include-before-body`, which are
  HTML-only concerns — see PRD Non-Goals: no CSS/theming parity required.) After all local
  conversions succeed, and unless `-n/--no-upload` was passed, invokes
  `drive_upload.py --local-root "${OUTPUT_ROOT}" --drive-folder-id "${DRIVE_FOLDER}" ...`,
  captures its per-file output lines, and prints a final summary count
  (`N uploaded, N updated, N warnings, N failed`).
- **Verify:** `bash -n tools/md2word/convert.sh`; run against the same scratch tree used to
  verify Step 3, end-to-end this time (conversion + upload in one command); confirm
  `tools/md2html/convert.sh` and its own scratch-tree output are byte-for-byte unaffected by
  running this new script (per the PRD's non-destructiveness requirement).

### Step 5: Visual verification of the Mermaid-in-docx assumption

- **Files:** none (verification-only step, not a code change)
- **What:** Convert a test Markdown file containing a Mermaid diagram through the full
  pipeline (Step 4's `convert.sh`) and open the resulting Google Doc. Confirm the diagram
  appears as a legible embedded image. If it does not render correctly, fall back to
  pre-rendering with `mmdc` (mermaid-cli) into a PNG and substituting the image reference
  ahead of the pandoc call, as Plan B — this would be a follow-up TRD amendment, not silently
  absorbed into Step 4.
- **Verify:** Human visual inspection of the resulting Doc.

### Step 6: Documentation

- **Files:** `README.md` (repo root)
- **What:** Add a `tools/md2word/` entry to the Repository Map and the `## tools/` section
  (mirroring how `md2html` is documented today), and a bullet in `## Safety and Secrets`
  covering where the OAuth client secret / token cache live and that they must never be
  committed — matching how every other credential-handling script in this repo is documented.
- **Verify:** Read-through; confirm no path/flag documented there is wrong.

## Test Plan

Per `CLAUDE.md` → Structural Overrides, this repo has no automated lint/test framework —
verification is manual, and that applies here too (this is not a new exception, it's the
already-agreed repo-wide approach applied consistently).

### Unit-level (manual, no framework — per Structural Overrides)

| Check | How | PRD Criterion |
|------|------|---------------|
| `convert.sh` syntax | `bash -n tools/md2word/convert.sh` | N/A (hygiene) |
| Local tree mirroring | Scratch source tree with nested dirs → confirm local `.docx` output matches `tools/md2html/convert.sh`'s proven mirroring pattern, just with `.docx` extensions | AC1 |
| `md2html` untouched | Diff `tools/md2html/convert.sh` before/after; re-run it against its own existing scratch fixture and confirm identical output | AC1 |
| Required-flag enforcement | Run `convert.sh` without `-g` → confirm immediate usage error, no partial run | AC3 |
| `drive_upload.py` missing deps | Temporarily uninstall a dependency in a venv, run the script, confirm the clear pip-install hint (not a raw traceback) | (P1 — fail clearly) |

### Integration-level (manual dry-run against a real, disposable Drive folder — see `validate-e2e.md`'s shell-scripts variant)

| Scenario | Tool | PRD Criterion |
|----------|------|---------------|
| First-run OAuth consent | Run against a fresh (no cached token) setup, complete the browser flow, confirm token cached | AC7 |
| Cached-token reuse | Second run, same machine, confirm no browser prompt | AC7 (part 2) |
| Create-as-native-Doc | Upload a new file, open it in Drive, confirm it's a native Google Doc (not a `.docx` viewer) | AC5 (Drive create-with-conversion) |
| Nested Drive folder mirroring | Source tree with at least two levels of nested subdirectories (e.g. `dir1/dir2/file1.md`), confirm matching nested folders are created in Drive and each file lands in the correct one | AC2 |
| Overwrite on re-run | Re-run against an already-uploaded file after editing the source, confirm the same Doc's content updates (same file id / URL), not a new Doc | AC4 |
| Formatting fidelity | Doc containing headings, a table, a code block, and (per Step 5 above) a Mermaid diagram — visually confirm all four render correctly | AC6 |
| Partial-batch failure | Force one file's upload to fail (e.g. temporarily revoke folder access), confirm the rest of the batch still completes and the failure is reported clearly | AC8 |
| Duplicate-name resolution | Manually create two same-named files in the target Drive folder ahead of a run, confirm the most-recently-modified one is overwritten and a `WARN` is reported (not a guess, not a skip) | AC4 (multi-match case) |

## Rollout

This is personal CLI tooling — "deploy" means the operator installs and runs it locally, there
is no server-side rollout.

- [ ] Create the GCP project + OAuth 2.0 Desktop client, download `client_secret.json` (Step 1
      README)
- [ ] `pip install -r tools/md2word/requirements.txt`
- [ ] Dry run with `-n/--no-upload` against a real doc tree to confirm local `.docx` output
      looks right before ever touching Drive
- [ ] First real run against a **disposable/test** Drive folder (not the real target folder)
      to complete the OAuth consent flow and sanity-check uploads
- [ ] Point `-g/--drive-folder` at the real destination folder for actual use
- **Rollback:** Nothing to roll back server-side. To undo: revoke this app's access at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions) and delete the
  local token cache (`$HOME/.config/md2word/token.json`) to force a fresh consent next run. The
  Bash/Python files can simply be deleted or left unused — nothing else in the repo depends on
  them (that's the whole point of the non-destructiveness requirement).

## Traceability Matrix

| PRD Acceptance Criterion | TRD Step | Test |
|--------------------------|----------|------|
| Local `.docx` tree mirrors source, `md2html` unaffected | Step 4 | Unit: local tree mirroring, `md2html` untouched |
| Files upload to configured Drive folder, mirrored subfolders | Steps 3–4 | Integration: nested Drive folder mirroring |
| No required-flag → immediate usage error, no hidden default folder | Step 4 | Unit: required-flag enforcement |
| Re-upload overwrites existing Doc in place (not duplicate); duplicate-named matches resolve to the most-recently-modified one, with a WARN | Step 3 (file find/match-count table) | Integration: overwrite on re-run + duplicate-name resolution |
| Drive API create request forces native Google Doc conversion | External API Integration → File create-with-conversion | Integration: create-as-native-Doc |
| Headings/TOC, tables, code blocks, Mermaid diagrams survive conversion | Step 4 (pandoc invocation) + Step 5 (visual check) | Integration: formatting fidelity |
| First run opens OAuth consent once; later runs reuse cached token | Step 3 (OAuth token flow) | Integration: first-run consent + cached-token reuse |
| One file's upload failure doesn't abort the batch; failure is reported | Step 3 (per-file try/except, prefixed output) | Integration: partial-batch failure |

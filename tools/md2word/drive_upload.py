#!/usr/bin/env python3
"""Uploads a local .docx tree to Google Drive as native Google Docs.

Mirrors the local folder structure into matching Drive folders under a given
destination folder id, converting each uploaded .docx into a native Google Doc
(one API call, via files().create with mimeType=google-apps.document).
Invoked by tools/md2word/convert.sh after local Markdown->docx conversion.
"""
import argparse
import random
import sys
import time
from pathlib import Path

try:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload
except ImportError as exc:
    print(
        f"FAILED startup: missing dependency ({exc}). "
        "Run: pip install -r tools/md2word/requirements.txt",
        file=sys.stderr,
    )
    sys.exit(1)

SCOPES = ["https://www.googleapis.com/auth/drive.file"]
FOLDER_MIME = "application/vnd.google-apps.folder"
DOC_MIME = "application/vnd.google-apps.document"
DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
MAX_RATE_LIMIT_RETRIES = 3


def get_credentials(client_secret_path: Path, token_cache_path: Path) -> Credentials:
    creds = None
    if token_cache_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_cache_path), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(client_secret_path), SCOPES)
            creds = flow.run_local_server(port=0)
        token_cache_path.parent.mkdir(parents=True, exist_ok=True)
        token_cache_path.write_text(creds.to_json())

    return creds


def escape_drive_query_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def find_or_create_folder(service, name: str, parent_id: str, cache: dict) -> str:
    cache_key = (parent_id, name)
    if cache_key in cache:
        return cache[cache_key]

    safe_name = escape_drive_query_value(name)
    query = (
        f"name='{safe_name}' and '{parent_id}' in parents "
        f"and mimeType='{FOLDER_MIME}' and trashed=false"
    )
    response = (
        service.files()
        .list(q=query, fields="files(id,name)", supportsAllDrives=True, includeItemsFromAllDrives=True)
        .execute()
    )
    matches = response.get("files", [])

    if matches:
        folder_id = matches[0]["id"]
    else:
        body = {"name": name, "mimeType": FOLDER_MIME, "parents": [parent_id]}
        created = service.files().create(body=body, fields="id", supportsAllDrives=True).execute()
        folder_id = created["id"]

    cache[cache_key] = folder_id
    return folder_id


def resolve_parent_folder(service, drive_root_id: str, rel_dir: Path, cache: dict) -> str:
    parent_id = drive_root_id
    if str(rel_dir) == ".":
        return parent_id
    for part in rel_dir.parts:
        parent_id = find_or_create_folder(service, part, parent_id, cache)
    return parent_id


def find_existing_files(service, name: str, parent_id: str) -> list:
    safe_name = escape_drive_query_value(name)
    query = f"name='{safe_name}' and '{parent_id}' in parents and trashed=false"
    response = (
        service.files()
        .list(
            q=query,
            fields="files(id,name,modifiedTime)",
            supportsAllDrives=True,
            includeItemsFromAllDrives=True,
        )
        .execute()
    )
    return response.get("files", [])


def fetch_comments(service, file_id: str) -> list:
    """Fetches all (non-deleted) comments + replies on a file, before its content is
    replaced. A content-replacing files().update() wipes existing comments outright (not
    just their anchors) - this must be called before that update, not after."""
    comments = []
    page_token = None
    while True:
        response = (
            service.comments()
            .list(
                fileId=file_id,
                fields=(
                    "nextPageToken,comments(content,author(displayName),createdTime,"
                    "replies(content,author(displayName),createdTime))"
                ),
                pageToken=page_token,
            )
            .execute()
        )
        comments.extend(response.get("comments", []))
        page_token = response.get("nextPageToken")
        if not page_token:
            break
    return comments


def _attributed_text(item: dict) -> str:
    author = item.get("author", {}).get("displayName", "Unknown")
    created = item.get("createdTime", "")
    date_str = created.split("T")[0] if created else "unknown date"
    return f"[Originally by {author}, {date_str}] {item.get('content', '')}"


def restore_comments(service, file_id: str, comments: list) -> int:
    """Re-posts previously-fetched comments (with reply threading) onto file_id as new,
    unanchored comments - the best available approximation given the Drive API cannot
    preserve the original anchor, author identity, or created timestamp on a repost.
    Best-effort: one comment/reply failing to restore does not abort the rest."""
    restored = 0
    for comment in comments:
        try:
            created = (
                service.comments()
                .create(fileId=file_id, body={"content": _attributed_text(comment)}, fields="id")
                .execute()
            )
        except Exception:
            continue
        comment_id = created["id"]
        restored += 1
        for reply in comment.get("replies", []):
            try:
                service.replies().create(
                    fileId=file_id,
                    commentId=comment_id,
                    body={"content": _attributed_text(reply)},
                    fields="id",
                ).execute()
            except Exception:
                continue
    return restored


def upload_with_retry(service, credentials, existing_id, name, parent_id, local_path):
    rate_limit_attempts = 0
    refreshed_once = False
    while True:
        media = MediaFileUpload(str(local_path), mimetype=DOCX_MIME, resumable=False)
        try:
            if existing_id:
                return (
                    service.files()
                    .update(
                        fileId=existing_id,
                        media_body=media,
                        fields="id,webViewLink",
                        supportsAllDrives=True,
                    )
                    .execute()
                )
            body = {"name": name, "parents": [parent_id], "mimeType": DOC_MIME}
            return (
                service.files()
                .create(
                    body=body,
                    media_body=media,
                    fields="id,webViewLink",
                    supportsAllDrives=True,
                )
                .execute()
            )
        except HttpError as e:
            status = e.resp.status if hasattr(e, "resp") else None
            if status == 401 and not refreshed_once:
                refreshed_once = True
                credentials.refresh(Request())
                continue
            if status == 429 and rate_limit_attempts < MAX_RATE_LIMIT_RETRIES:
                rate_limit_attempts += 1
                time.sleep((2**rate_limit_attempts) + random.uniform(0, 1))
                continue
            raise


def upload_file(service, credentials, local_path: Path, rel_path: Path, drive_root_id: str, folder_cache: dict, progress: str):
    rel_dir = rel_path.parent
    # Drive strips the .docx extension when it converts an upload into a native Google
    # Doc (a converted Doc is not a .docx container - Drive names it without the
    # extension, matching what the Drive UI shows). Search and create using that same
    # extension-less name, or a same-name lookup on a later run would never match the
    # file this tool already created, and would create a brand new Doc every time
    # instead of overwriting it.
    doc_name = rel_path.stem

    print(f"{progress} Uploading {rel_path}...")

    # Broad except (not just HttpError) below is deliberate: the PRD's "one file's failure
    # doesn't abort the batch" requirement explicitly lists "expired token" as an example
    # failure. A mid-batch token refresh failure raises google.auth.exceptions.RefreshError,
    # not an HttpError - it must still be isolated to this one file, not crash the run.
    try:
        parent_id = resolve_parent_folder(service, drive_root_id, rel_dir, folder_cache)
    except Exception as e:
        print(f"FAILED {progress} {rel_path}: could not create/find Drive folder ({e})")
        return

    try:
        matches = find_existing_files(service, doc_name, parent_id)
    except Exception as e:
        print(f"FAILED {progress} {rel_path}: could not query existing Drive files ({e})")
        return

    try:
        if len(matches) == 0:
            result = upload_with_retry(service, credentials, None, doc_name, parent_id, local_path)
            print(f"UPLOADED {progress} {rel_path} -> {result.get('webViewLink')}")
            return

        target = matches[0] if len(matches) == 1 else sorted(matches, key=lambda f: f["modifiedTime"], reverse=True)[0]

        # A content-replacing update wipes existing comments outright, not just their
        # anchors - must fetch them before the overwrite, not after. Best-effort: if this
        # fails, proceed with the overwrite anyway rather than blocking on it (the upload
        # itself is the point; comment restoration is a bonus, not a hard dependency).
        existing_comments = []
        try:
            existing_comments = fetch_comments(service, target["id"])
        except Exception as e:
            print(f"WARN {progress} {rel_path}: could not fetch existing comments before overwrite ({e}); proceeding without them")

        result = upload_with_retry(service, credentials, target["id"], doc_name, parent_id, local_path)

        restored = restore_comments(service, target["id"], existing_comments) if existing_comments else 0

        if len(matches) == 1:
            print(f"UPDATED {progress} {rel_path} -> {result.get('webViewLink')}")
        else:
            print(
                f"WARN {progress} {rel_path}: {len(matches)} duplicate names found in Drive, "
                f"updated the most recently modified -> {result.get('webViewLink')}"
            )
        if restored:
            print(f"  -> restored {restored} comment thread(s) as new, unanchored comments (see help for why)")
    except Exception as e:
        print(f"FAILED {progress} {rel_path}: Drive upload failed ({e})")


def main():
    # Force line-buffering even when stdout is piped (convert.sh pipes this through `tee`
    # for its live progress display) - otherwise Python fully buffers non-tty stdout and
    # nothing appears until the process exits, defeating the point of per-file progress.
    sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(
        description="Upload a local .docx tree to Google Drive as native Google Docs."
    )
    parser.add_argument("--local-root", required=True, type=Path)
    parser.add_argument("--drive-folder-id", required=True)
    parser.add_argument("--client-secret", required=True, type=Path)
    parser.add_argument("--token-cache", required=True, type=Path)
    parser.add_argument("--pattern", default="*", help="Glob matched against filenames without extension (default: * = everything)")
    args = parser.parse_args()

    if not args.client_secret.exists():
        print(
            f"FAILED startup: client secret not found at {args.client_secret}. "
            "See tools/md2word/README.md for one-time setup.",
            file=sys.stderr,
        )
        sys.exit(1)

    docx_files = sorted(args.local_root.rglob(f"{args.pattern}.docx"))
    if not docx_files:
        print(f"No .docx files matching '{args.pattern}.docx' found under {args.local_root}", file=sys.stderr)
        sys.exit(0)

    try:
        credentials = get_credentials(args.client_secret, args.token_cache)
    except Exception as exc:
        print(
            f"FAILED startup: could not obtain Drive credentials ({exc}). "
            f"Delete {args.token_cache} to force a fresh sign-in, or re-check the "
            "one-time setup in tools/md2word/README.md.",
            file=sys.stderr,
        )
        sys.exit(1)

    service = build("drive", "v3", credentials=credentials)

    folder_cache: dict = {}
    total = len(docx_files)
    for index, local_path in enumerate(docx_files, start=1):
        rel_path = local_path.relative_to(args.local_root)
        progress = f"[{index}/{total}]"
        upload_file(service, credentials, local_path, rel_path, args.drive_folder_id, folder_cache, progress)


if __name__ == "__main__":
    main()

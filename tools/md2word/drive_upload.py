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


def upload_file(service, credentials, local_path: Path, rel_path: Path, drive_root_id: str, folder_cache: dict):
    rel_dir = rel_path.parent
    name = rel_path.name

    # Broad except (not just HttpError) below is deliberate: the PRD's "one file's failure
    # doesn't abort the batch" requirement explicitly lists "expired token" as an example
    # failure. A mid-batch token refresh failure raises google.auth.exceptions.RefreshError,
    # not an HttpError - it must still be isolated to this one file, not crash the run.
    try:
        parent_id = resolve_parent_folder(service, drive_root_id, rel_dir, folder_cache)
    except Exception as e:
        print(f"FAILED {rel_path}: could not create/find Drive folder ({e})")
        return

    try:
        matches = find_existing_files(service, name, parent_id)
    except Exception as e:
        print(f"FAILED {rel_path}: could not query existing Drive files ({e})")
        return

    try:
        if len(matches) == 0:
            result = upload_with_retry(service, credentials, None, name, parent_id, local_path)
            print(f"UPLOADED {rel_path} -> {result.get('webViewLink')}")
        elif len(matches) == 1:
            result = upload_with_retry(service, credentials, matches[0]["id"], name, parent_id, local_path)
            print(f"UPDATED {rel_path} -> {result.get('webViewLink')}")
        else:
            most_recent = sorted(matches, key=lambda f: f["modifiedTime"], reverse=True)[0]
            result = upload_with_retry(service, credentials, most_recent["id"], name, parent_id, local_path)
            print(
                f"WARN {rel_path}: {len(matches)} duplicate names found in Drive, "
                f"updated the most recently modified -> {result.get('webViewLink')}"
            )
    except Exception as e:
        print(f"FAILED {rel_path}: Drive upload failed ({e})")


def main():
    parser = argparse.ArgumentParser(
        description="Upload a local .docx tree to Google Drive as native Google Docs."
    )
    parser.add_argument("--local-root", required=True, type=Path)
    parser.add_argument("--drive-folder-id", required=True)
    parser.add_argument("--client-secret", required=True, type=Path)
    parser.add_argument("--token-cache", required=True, type=Path)
    args = parser.parse_args()

    if not args.client_secret.exists():
        print(
            f"FAILED startup: client secret not found at {args.client_secret}. "
            "See tools/md2word/README.md for one-time setup.",
            file=sys.stderr,
        )
        sys.exit(1)

    docx_files = sorted(args.local_root.rglob("*.docx"))
    if not docx_files:
        print(f"No .docx files found under {args.local_root}", file=sys.stderr)
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
    for local_path in docx_files:
        rel_path = local_path.relative_to(args.local_root)
        upload_file(service, credentials, local_path, rel_path, args.drive_folder_id, folder_cache)


if __name__ == "__main__":
    main()

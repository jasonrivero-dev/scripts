# md2word

Converts a Markdown source tree to `.docx` files (mirroring the source folder structure
locally, same pattern as `tools/md2html/convert.sh`), then uploads each `.docx` to a Google
Drive folder, forcing conversion into a native Google Doc on upload. Separate from
`tools/md2html/convert.sh` — does not touch it.

## One-time setup

You need a Google Cloud OAuth 2.0 client before this tool can upload anything. This is a
one-time setup per machine.

1. Go to [console.cloud.google.com](https://console.cloud.google.com/) and create a new
   project (or select an existing one you're comfortable using for this).
2. In **APIs & Services → Library**, search for **Google Drive API** and enable it for that
   project.
3. Go to **Google Auth Platform** (Google's current name for what used to be called "OAuth
   consent screen" — reachable from the left nav, or via
   `console.cloud.google.com/auth/overview?project=<your-project-id>`).
   - If this is the first OAuth client on this project, the Overview page will say "You
     haven't configured any OAuth clients for this project yet" with a **Create OAuth
     client** button. Clicking it first walks you through **Branding** and **Audience**
     setup (app name, support email, user type — choose **External** unless you're on a
     Workspace account restricted to your own org — and adding yourself as a test user).
     This is the modern equivalent of the old "consent screen" step.
   - Once that's done, go to **Clients → Create client** (or use the Overview page's
     **Create OAuth client** button again).
4. On the **Create OAuth client ID** page, set **Application type** to **Desktop app** (it's
   one of the options in that dropdown, alongside Web application/Android/iOS/etc.), give it
   any name, and click **Create**.
5. Download the resulting JSON as your `client_secret.json` (a download option appears right
   after creation, or from the client's row under **Clients** afterward).
6. Move it to `$HOME/.config/md2word/client_secret.json`:
   ```bash
   mkdir -p ~/.config/md2word
   mv ~/Downloads/client_secret_*.json ~/.config/md2word/client_secret.json
   ```
   (Or leave it anywhere and point `MD2WORD_CLIENT_SECRET` at it instead — see Environment
   variables below.)
7. Install the Python dependencies:
   ```bash
   pip install -r tools/md2word/requirements.txt
   ```

The first time you run `convert.sh` with Drive upload enabled, it opens a browser window
asking you to authorize the app against your own Google account. After you approve, a token
is cached at `$HOME/.config/md2word/token.json` (also relocatable via `MD2WORD_TOKEN_CACHE`)
and refreshed automatically — you won't be prompted again on later runs unless that file is
deleted or access is revoked.

## Usage

```bash
tools/md2word/convert.sh -s <source_dir> -g <drive_folder_id> [-t <target_dir>] [-p <pattern>] [-n|-u]
```

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-s`, `--source` | yes | — | Markdown source directory (searched recursively); with `-u`, an existing `.docx` tree instead |
| `-g`, `--drive-folder` | yes | — | Destination Google Drive folder ID (no default — always explicit) |
| `-t`, `--target` | no | `~/Documents/md2word` | Local directory to stage the generated `.docx` tree in (ignored with `-u`) |
| `-c`, `--client-secret` | no | `$HOME/.config/md2word/client_secret.json` | Path to the OAuth client secret JSON (see setup above) |
| `-k`, `--token-cache` | no | `$HOME/.config/md2word/token.json` | Path to the cached OAuth token |
| `-p`, `--pattern` | no | `*` (everything) | Glob matched against filenames without their extension, searched recursively under `-s` |
| `-n`, `--no-upload` | no | off | Convert to local `.docx` only; skip the Drive upload step entirely |
| `-u`, `--upload-only` | no | off | Skip Markdown conversion; upload the existing `.docx` tree at `-s` as-is |
| `-h`, `--help` | no | — | Show usage |

`-n` and `-u` are opposites and can't be combined. `-u` is for uploading `.docx` files you
already have (from a previous run, or from anywhere else) without re-converting anything:

```bash
tools/md2word/convert.sh -s ~/Documents/md2word/docs -g <drive_folder_id> -u
```

`-p/--pattern` narrows down which files get touched, without having to move anything into a
separate directory first. **Always quote it** so your shell doesn't expand the glob itself
before the script sees it:

```bash
# Only files starting with "CUSTOM" (matches CUSTOM_LICENSE.md, CUSTOMER_HOWTO.md, etc.)
tools/md2word/convert.sh -s ~/dev/edge-licensing/docs -g <drive_folder_id> -p "CUSTOM*"
tools/md2word/convert.sh -s ~/Documents/md2word/docs -g <drive_folder_id> -u -p "CUSTOM*"
```

Both `-c`/`-k` also read from `MD2WORD_CLIENT_SECRET` / `MD2WORD_TOKEN_CACHE` env vars if the
flags aren't given.

## Re-running against the same files

Re-running against a file you've already uploaded **overwrites** the existing Google Doc's
content in place (matched by filename within its Drive folder) rather than creating a
duplicate. If more than one file with that name already exists in the target Drive folder
(Drive allows duplicate names, unlike a filesystem), the most-recently-modified one is
overwritten and a warning is printed naming the duplicate count — you may want to clean up
the stray copies in Drive yourself.

### What happens to comments on an overwrite

Overwriting a Doc's content wipes any comments stakeholders left on it — not just their
highlighted anchor, the comment threads themselves. To avoid losing feedback, every
overwrite automatically:

1. Fetches the existing Doc's comments (and their replies) **before** the content is
   replaced.
2. Reposts each one **after** the overwrite, as a new comment on the same Doc, prefixed
   with who originally wrote it and when — e.g. `[Originally by Jane Reviewer,
   2026-09-17] I hope this comment survives`.

This is a best-effort repost, not a true restoration — two real limitations, both hard API
constraints rather than a choice made here:

- **No anchor.** The restored comment is a general, whole-document comment. It won't
  highlight the specific sentence the original comment was attached to.
- **No real authorship.** Drive attributes every newly-created comment to whoever is
  authenticated when the script runs (you), with today's date — there's no way to make the
  API repost it as if the original reviewer wrote it. The original author/date is preserved
  as text inside the comment instead (see the prefix above), not as real comment metadata.

If fetching the existing comments fails for any reason (e.g. a permissions issue), the tool
warns and still completes the overwrite — comment restoration is a bonus on top of the
upload, never a reason to block it.

## Diagrams

Mermaid code blocks are rendered via the same `mermaid-filter` used by `tools/md2html`. Word
document rendering of embedded images can differ from HTML in sizing — if a diagram looks
wrong in the resulting Doc, that's a known conversion risk, not a bug you need to chase; open
an issue for yourself to investigate a fallback (pre-rendering with `mmdc` into a fixed-size
PNG) if it comes up in practice.

## Where secrets live

`client_secret.json` and the token cache both default to `$HOME/.config/md2word/`, entirely
outside this repository — never commit either. If you ever point `MD2WORD_CLIENT_SECRET` or
`MD2WORD_TOKEN_CACHE` at a path inside this repo, add that path to `.gitignore` first.

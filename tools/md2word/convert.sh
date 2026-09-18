#!/usr/bin/env bash
set -euo pipefail

# Converts a Markdown source tree to .docx, mirroring the source folder structure
# locally (same idiom as tools/md2html/convert.sh), then uploads each .docx to a
# Google Drive folder as a native Google Doc. Does not touch tools/md2html/convert.sh.

# mermaid-filter lives under the npm global bin path, not on the default PATH
# (same reason tools/md2html/convert.sh does this).
export PATH="$HOME/.npm-global/bin:$PATH"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "[$(date +"%H:%M:%S")] [${GREEN}INFO${NC}] $*"
}

warn() {
    echo -e "[$(date +"%H:%M:%S")] [${YELLOW}WARN${NC}] $*"
}

error() {
    echo -e "[$(date +"%H:%M:%S")] [${RED}ERROR${NC}] $*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR=""
TARGET_DIR="$HOME/Documents/md2word"
DRIVE_FOLDER=""
CLIENT_SECRET="${MD2WORD_CLIENT_SECRET:-$HOME/.config/md2word/client_secret.json}"
TOKEN_CACHE="${MD2WORD_TOKEN_CACHE:-$HOME/.config/md2word/token.json}"
NO_UPLOAD=false
UPLOAD_ONLY=false
PATTERN="*"

usage() {
    echo "Usage: $(basename "$0") -s <source_dir> -g <drive_folder_id> [-t <target_dir>] [-c <client_secret>] [-k <token_cache>] [-p <pattern>] [-n|-u]"
    echo "  -s, --source          Source directory (required) - .md files to convert, or an"
    echo "                        existing .docx tree if -u/--upload-only is given"
    echo "  -g, --drive-folder    Destination Google Drive folder ID (required unless -n/--no-upload)"
    echo "  -t, --target          Local directory to stage generated .docx files in (default: ~/Documents/md2word; ignored with -u)"
    echo "  -c, --client-secret   OAuth client secret JSON path (default: \$MD2WORD_CLIENT_SECRET or ~/.config/md2word/client_secret.json)"
    echo "  -k, --token-cache     Cached OAuth token path (default: \$MD2WORD_TOKEN_CACHE or ~/.config/md2word/token.json)"
    echo "  -p, --pattern         Glob matched against filenames (without extension), searched"
    echo "                        recursively under -s (default: *, i.e. everything). Quote it"
    echo "                        so your shell doesn't expand it, e.g. -p \"CUSTOM*\""
    echo "  -n, --no-upload       Convert to local .docx only; skip the Drive upload step"
    echo "  -u, --upload-only     Skip Markdown conversion; upload the existing .docx tree at -s as-is"
    echo "  -h, --help            Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -s|--source) SOURCE_DIR="$2"; shift 2 ;;
        -t|--target) TARGET_DIR="$2"; shift 2 ;;
        -g|--drive-folder) DRIVE_FOLDER="$2"; shift 2 ;;
        -c|--client-secret) CLIENT_SECRET="$2"; shift 2 ;;
        -k|--token-cache) TOKEN_CACHE="$2"; shift 2 ;;
        -p|--pattern) PATTERN="$2"; shift 2 ;;
        -n|--no-upload) NO_UPLOAD=true; shift ;;
        -u|--upload-only) UPLOAD_ONLY=true; shift ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$SOURCE_DIR" ]]; then
    error "Source directory (-s/--source) is required."
    usage
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    error "Source directory '${SOURCE_DIR}' does not exist."
    exit 1
fi

if [[ "$UPLOAD_ONLY" == true && "$NO_UPLOAD" == true ]]; then
    error "-u/--upload-only and -n/--no-upload together do nothing - pick one."
    exit 1
fi

# -g is only meaningless when -n/--no-upload skips Drive entirely - required otherwise,
# per the PRD's "no hidden default folder" requirement.
if [[ -z "$DRIVE_FOLDER" && "$NO_UPLOAD" != true ]]; then
    error "Destination Drive folder (-g/--drive-folder) is required unless -n/--no-upload is given."
    usage
    exit 1
fi

# Resolve to an absolute path, same reasoning as tools/md2html/convert.sh.
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

UPLOAD_LOG=""
trap 'rm -f .puppeteer.json; [[ -n "$UPLOAD_LOG" ]] && rm -f "$UPLOAD_LOG"' EXIT

if [[ "$UPLOAD_ONLY" == true ]]; then
    # Nothing to convert - upload the existing .docx tree at SOURCE_DIR directly, with no
    # extra staging step. TARGET_DIR/SOURCE_BASENAME nesting doesn't apply here since we're
    # not writing anything locally.
    OUTPUT_ROOT="$SOURCE_DIR"
    log "Skipping conversion (-u/--upload-only given). Uploading existing .docx tree from: ${OUTPUT_ROOT} (pattern: ${PATTERN}.docx)"
else
    mkdir -p "$TARGET_DIR"

    mapfile -d '' files < <(find "$SOURCE_DIR" -type f -name "${PATTERN}.md" -print0 | sort -z)
    if [[ ${#files[@]} -eq 0 ]]; then
        log "No .md files matching '${PATTERN}.md' found under ${SOURCE_DIR}"
        exit 0
    fi

    # Create a local puppeteer config file to bypass Chrome sandbox restrictions on Ubuntu
    # (same reason tools/md2html/convert.sh does this - mermaid-filter's mmdc launches
    # Chromium via Puppeteer, which otherwise fails with "No usable sandbox!").
    cat << 'EOF' > .puppeteer.json
{
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
}
EOF

    SOURCE_BASENAME="$(basename "$SOURCE_DIR")"
    OUTPUT_ROOT="${TARGET_DIR}/${SOURCE_BASENAME}"

    log "Processing Markdown files from: ${SOURCE_DIR}"
    log "Saving .docx output to:        ${OUTPUT_ROOT}"

    for file in "${files[@]}"; do
        rel_path="${file#"$SOURCE_DIR"/}"
        rel_dir="$(dirname "$rel_path")"
        filename="$(basename "$rel_path")"
        basename="${filename%.md}"

        out_dir="$OUTPUT_ROOT"
        [[ "$rel_dir" != "." ]] && out_dir="${OUTPUT_ROOT}/${rel_dir}"
        mkdir -p "$out_dir"
        output_path="${out_dir}/${basename}.docx"

        log "Converting: ${rel_path} -> ${output_path#"$TARGET_DIR"/}"

        pandoc "$file" \
            --from=gfm \
            --toc \
            --toc-depth=3 \
            --filter mermaid-filter \
            --metadata title="$basename" \
            -o "$output_path"
    done

    log "Done! All .docx files are available in: ${OUTPUT_ROOT}"
fi

if [[ "$NO_UPLOAD" == true ]]; then
    log "Skipping Drive upload (-n/--no-upload given)."
    exit 0
fi

log "Uploading to Google Drive folder ${DRIVE_FOLDER}..."

UPLOAD_LOG="$(mktemp)"

set +e
python3 "${SCRIPT_DIR}/drive_upload.py" \
    --local-root "$OUTPUT_ROOT" \
    --drive-folder-id "$DRIVE_FOLDER" \
    --client-secret "$CLIENT_SECRET" \
    --token-cache "$TOKEN_CACHE" \
    --pattern "$PATTERN" \
    2>&1 | tee "$UPLOAD_LOG"
UPLOAD_EXIT="${PIPESTATUS[0]}"
set -e

if [[ "$UPLOAD_EXIT" -ne 0 ]]; then
    error "Drive upload step failed to start (see output above)."
    exit 1
fi

UPLOADED_COUNT="$(grep -c '^UPLOADED ' "$UPLOAD_LOG" || true)"
UPDATED_COUNT="$(grep -c '^UPDATED ' "$UPLOAD_LOG" || true)"
WARN_COUNT="$(grep -c '^WARN ' "$UPLOAD_LOG" || true)"
FAILED_COUNT="$(grep -c '^FAILED ' "$UPLOAD_LOG" || true)"

log "Drive upload summary: ${UPLOADED_COUNT} uploaded, ${UPDATED_COUNT} updated, ${WARN_COUNT} warnings, ${FAILED_COUNT} failed."

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    warn "${FAILED_COUNT} file(s) failed to upload - see FAILED lines above for details."
fi

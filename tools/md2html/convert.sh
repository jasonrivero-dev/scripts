#!/usr/bin/env bash
set -euo pipefail

# Ensure custom npm global bin path is included in PATH for Pandoc subshells
export PATH="$HOME/.npm-global/bin:$PATH"

# Script asset paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSS_FILE="${SCRIPT_DIR}/novarc.css"
HEADER_FILE="${SCRIPT_DIR}/header.html"

# Default settings
TARGET_DIR="$HOME/Documents"
SOURCE_DIR=""
OPEN_IN_BROWSER=false
BROWSER_CMD="xdg-open" # Uses system default browser on Linux

usage() {
  echo "Usage: $0 -s <source_dir> [-t <target_dir>] [-o] [-b <browser_cmd>]"
  echo "  -s    Source directory containing .md files (required)"
  echo "  -t    Target directory for output .html files (default: ~/Documents)"
  echo "  -o    Open generated HTML file(s) in browser upon completion"
  echo "  -b    Custom browser command (default: xdg-open, e.g., -b google-chrome)"
  exit 1
}

# Parse options (added 'o' and 'b:')
while getopts ":s:t:ob:h" opt; do
  case ${opt} in
    s) SOURCE_DIR="${OPTARG}" ;;
    t) TARGET_DIR="${OPTARG}" ;;
    o) OPEN_IN_BROWSER=true ;;
    b) BROWSER_CMD="${OPTARG}" ;;
    h|\?) usage ;;
  esac
done

if [[ -z "${SOURCE_DIR}" ]]; then
  echo "Error: Source directory (-s) is required."
  usage
fi

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "Error: Source directory '${SOURCE_DIR}' does not exist."
  exit 1
fi

# Resolve to an absolute path: makes the basename meaningful for inputs like
# "-s ." or "-s ../notes", and makes the prefix-stripping below reliable
# regardless of how the path was originally given.
SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"

mkdir -p "${TARGET_DIR}"

mapfile -d '' files < <(find "${SOURCE_DIR}" -type f -name '*.md' -print0 | sort -z)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .md files found under ${SOURCE_DIR}"
  exit 0
fi

# Mirror the source tree under a subfolder named after the source directory
# itself, so different source trees (or repeated runs) don't collide or mix
# together flat in the same target directory.
SOURCE_BASENAME="$(basename "${SOURCE_DIR}")"
OUTPUT_ROOT="${TARGET_DIR}/${SOURCE_BASENAME}"

# Create a local puppeteer config file to bypass Chrome sandbox restrictions on Ubuntu
cat << 'EOF' > .puppeteer.json
{
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
}
EOF

trap 'rm -f .puppeteer.json' EXIT

echo "Processing Markdown files from: ${SOURCE_DIR}"
echo "Saving HTML output to:         ${OUTPUT_ROOT}"
echo "--------------------------------------------------"

generated_files=()

for file in "${files[@]}"; do
  rel_path="${file#"${SOURCE_DIR}"/}"
  rel_dir="$(dirname "${rel_path}")"
  filename="$(basename "${rel_path}")"
  basename="${filename%.md}"

  out_dir="${OUTPUT_ROOT}"
  [[ "${rel_dir}" != "." ]] && out_dir="${OUTPUT_ROOT}/${rel_dir}"
  mkdir -p "${out_dir}"
  output_path="${out_dir}/${basename}.html"

  echo "Converting: ${rel_path} -> ${output_path#"${TARGET_DIR}"/}"

  pandoc "$file" \
    --from=gfm \
    --standalone \
    --toc \
    --toc-depth=3 \
    --embed-resources \
    --css="${CSS_FILE}" \
    --include-before-body="${HEADER_FILE}" \
    --filter mermaid-filter \
    --metadata title="${basename}" \
    -o "${output_path}"

  generated_files+=("${output_path}")
done

echo "--------------------------------------------------"
echo "Done! All HTML files are available in: ${OUTPUT_ROOT}"

# Open files if -o flag was passed
if [[ "${OPEN_IN_BROWSER}" == true ]]; then
  echo "Opening generated HTML file(s)..."
  for html_file in "${generated_files[@]}"; do
    # Disown process and suppress Snap/GTK stderr warnings completely
    ("${BROWSER_CMD}" "${html_file}" >/dev/null 2>&1 &)
  done
fi
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

mkdir -p "${TARGET_DIR}"

shopt -s nullglob
files=("${SOURCE_DIR}"/*.md)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .md files found in ${SOURCE_DIR}"
  exit 0
fi

# Create a local puppeteer config file to bypass Chrome sandbox restrictions on Ubuntu
cat << 'EOF' > .puppeteer.json
{
  "args": ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"]
}
EOF

trap 'rm -f .puppeteer.json' EXIT

echo "Processing Markdown files from: ${SOURCE_DIR}"
echo "Saving HTML output to:         ${TARGET_DIR}"
echo "--------------------------------------------------"

generated_files=()

for file in "${files[@]}"; do
  filename=$(basename "$file")
  basename="${filename%.md}"
  output_path="${TARGET_DIR}/${basename}.html"

  echo "Converting: ${filename} -> ${basename}.html"

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
echo "Done! All HTML files are available in: ${TARGET_DIR}"

# Open files if -o flag was passed
if [[ "${OPEN_IN_BROWSER}" == true ]]; then
  echo "Opening generated HTML file(s)..."
  for html_file in "${generated_files[@]}"; do
    # Disown process and suppress Snap/GTK stderr warnings completely
    ("${BROWSER_CMD}" "${html_file}" >/dev/null 2>&1 &)
  done
fi
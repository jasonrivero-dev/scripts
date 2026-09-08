#!/usr/bin/env bash
set -euo pipefail

# Ensure custom npm global bin path is included in PATH for Pandoc subshells
export PATH="$HOME/.npm-global/bin:$PATH"

# Script asset paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSS_FILE="${SCRIPT_DIR}/novarc.css"
HEADER_FILE="${SCRIPT_DIR}/header.html"

# Default target directory
TARGET_DIR="$HOME/Documents"
SOURCE_DIR=""

usage() {
  echo "Usage: $0 -s <source_dir> [-t <target_dir>]"
  echo "  -s    Source directory containing .md files (required)"
  echo "  -t    Target directory for output .html files (default: ~/Documents)"
  exit 1
}

while getopts ":s:t:h" opt; do
  case ${opt} in
    s) SOURCE_DIR="${OPTARG}" ;;
    t) TARGET_DIR="${OPTARG}" ;;
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
done

echo "--------------------------------------------------"
echo "Done! All HTML files are available in: ${TARGET_DIR}"
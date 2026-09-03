#!/usr/bin/env bash
set -euo pipefail

# Ensure custom npm global bin path is included in PATH for Pandoc subshells
export PATH="$HOME/.npm-global/bin:$PATH"

# Default target directory
TARGET_DIR="$HOME/Documents"
SOURCE_DIR=""

# Usage help function
usage() {
  echo "Usage: $0 -s <source_dir> [-t <target_dir>]"
  echo "  -s    Source directory containing .md files (required)"
  echo "  -t    Target directory for output .html files (default: ~/Documents)"
  exit 1
}

# Parse command-line options
while getopts ":s:t:h" opt; do
  case ${opt} in
    s)
      SOURCE_DIR="${OPTARG}"
      ;;
    t)
      TARGET_DIR="${OPTARG}"
      ;;
    h|\?)
      usage
      ;;
  esac
done

# Validate required source parameter
if [[ -z "${SOURCE_DIR}" ]]; then
  echo "Error: Source directory (-s) is required."
  usage
fi

# Ensure source directory exists
if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "Error: Source directory '${SOURCE_DIR}' does not exist."
  exit 1
fi

# Ensure target directory exists, or create it
mkdir -p "${TARGET_DIR}"

# Check for .md files in the source directory
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

# Ensure cleanup of .puppeteer.json on exit
trap 'rm -f .puppeteer.json' EXIT

echo "Processing Markdown files from: ${SOURCE_DIR}"
echo "Saving HTML output to:         ${TARGET_DIR}"
echo "--------------------------------------------------"

# Convert each Markdown file
for file in "${files[@]}"; do
  filename=$(basename "$file")
  basename="${filename%.md}"
  output_path="${TARGET_DIR}/${basename}.html"

  echo "Converting: ${filename} -> ${basename}.html"

  pandoc "$file" \
    --from=gfm \
    --standalone \
    --filter mermaid-filter \
    --metadata title="${basename}" \
    -o "${output_path}"
done

echo "--------------------------------------------------"
echo "Done! All HTML files are available in: ${TARGET_DIR}"
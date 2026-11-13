#!/usr/bin/env bash
# Commits whatever is currently staged. The agent stages files and hands this script to the
# owner to run — it never runs `git commit` itself.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 \"<commit message>\"" >&2
  exit 1
fi

if git diff --cached --quiet; then
  echo "Nothing staged to commit." >&2
  exit 1
fi

git commit -m "$1"

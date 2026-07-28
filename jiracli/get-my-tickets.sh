#!/usr/bin/env bash

# Safely load token
TOKEN_FILE="$HOME/dev/scripts/jiracli/token"
if [[ -f "$TOKEN_FILE" ]]; then
  export JIRA_API_TOKEN=$(cat "$TOKEN_FILE")
else
  echo "Error: Token file not found at $TOKEN_FILE" >&2
  exit 1
fi

STATUS=""
LIMIT=50
PLAIN=""

# Parse options
while getopts "s:l:ph" opt; do
  case $opt in
    s) STATUS="$OPTARG" ;;
    l) LIMIT="$OPTARG" ;;
    p) PLAIN="--plain" ;;
    h)
      echo "Usage: $(basename "$0") [-s status] [-l limit] [-p]"
      echo "  -s STATUS  Filter by status (e.g. 'In Progress', 'To Do')"
      echo "  -l LIMIT   Max results to return (default: 50)"
      echo "  -p         Output as plain text instead of interactive TUI"
      exit 0
      ;;
    \?)
      exit 1
      ;;
  esac
done

# Base command for current user's tickets
CMD=("jira" "issue" "list" "-a$(jira me)" "--paginate" "$LIMIT")

# Filter out Done tickets by default unless status is specified
if [[ -n "$STATUS" ]]; then
  CMD+=("-s" "$STATUS")
else
  CMD+=("-s~Done")
fi

if [[ -n "$PLAIN" ]]; then
  CMD+=("$PLAIN")
fi

"${CMD[@]}"

#!/usr/bin/env bash

# Safely load token
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TOKEN_FILE="$SCRIPT_DIR/token"
if [[ -f "$TOKEN_FILE" ]]; then
  export JIRA_API_TOKEN=$(cat "$TOKEN_FILE")
else
  echo "Error: Token file not found at $TOKEN_FILE" >&2
  exit 1
fi

STATUS=""
LIMIT=50
PLAIN=""
EPIC=""
TEXT=""

usage() {
  echo "Usage: $(basename "$0") [-s status] [-e epic_key] [-t title_pattern] [-l limit] [-p]"
  echo "  -e EPIC    Filter by Epic / Parent key (e.g., SW-3373)"
  echo "  -t TEXT    Filter by title/summary pattern (e.g., SWR-LIC)"
  echo "  -s STATUS  Filter by status (e.g., 'In Progress', 'To Do')"
  echo "  -l LIMIT   Max results to return (default: 50)"
  echo "  -p         Output as plain text instead of interactive TUI"
  exit 0
}

# Parse options
while getopts "e:t:s:l:ph" opt; do
  case $opt in
    e) EPIC="$OPTARG" ;;
    t) TEXT="$OPTARG" ;;
    s) STATUS="$OPTARG" ;;
    l) LIMIT="$OPTARG" ;;
    p) PLAIN="--plain" ;;
    h) usage ;;
    \?) exit 1 ;;
  esac
done

# Base command
CMD=("jira" "issue" "list")

# Pass positional text query if requested
if [[ -n "$TEXT" ]]; then
  CMD+=("$TEXT")
fi

# Filter for current user and pagination limit
CMD+=("-a$(jira me)" "--paginate" "$LIMIT")

# Status handling: default to excluding Done unless status or epic is explicitly queried
if [[ -n "$STATUS" ]]; then
  CMD+=("-s" "$STATUS")
elif [[ -z "$EPIC" && -z "$TEXT" ]]; then
  CMD+=("-s~Done")
fi

# Epic / Parent filter flag
if [[ -n "$EPIC" ]]; then
  CMD+=("-P" "$EPIC")
fi

# Plain mode
if [[ -n "$PLAIN" ]]; then
  CMD+=("$PLAIN")
fi

"${CMD[@]}"

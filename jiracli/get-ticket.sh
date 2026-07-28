#!/usr/bin/env bash

# Safely load token
TOKEN_FILE="$HOME/dev/scripts/jiracli/token"
if [[ -f "$TOKEN_FILE" ]]; then
  export JIRA_API_TOKEN=$(cat "$TOKEN_FILE")
else
  echo "Error: Token file not found at $TOKEN_FILE" >&2
  exit 1
fi

PLAIN=""
COMMENTS=3

usage() {
  echo "Usage: $(basename "$0") [-p] [-c comments_count] <ISSUE-KEY>"
  echo "  -p         Output plain text to stdout (ideal for grep/piping)"
  echo "  -c NUM     Number of comments to fetch (default: 3)"
  exit 1
}

# Parse options
while getopts "pc:h" opt; do
  case $opt in
    p) PLAIN="--plain" ;;
    c) COMMENTS="$OPTARG" ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $((OPTIND -1))

ISSUE_KEY="$1"

if [[ -z "$ISSUE_KEY" ]]; then
  usage
fi

CMD=("jira" "issue" "view" "$ISSUE_KEY" "--comments" "$COMMENTS")

if [[ -n "$PLAIN" ]]; then
  CMD+=("$PLAIN")
fi

"${CMD[@]}"

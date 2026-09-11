#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TOKEN_FILE="$SCRIPT_DIR/token"
if [[ -f "$TOKEN_FILE" ]]; then
  export JIRA_API_TOKEN=$(cat "$TOKEN_FILE")
else
  echo "Error: Token file not found at $TOKEN_FILE" >&2
  exit 1
fi

PLAIN=""
COMMENTS=3

usage() {
  echo "Usage: $(basename "$0") [-p] [-c comments_count] <ISSUE-KEY> [ISSUE-KEY...]"
  echo "  -p         Output plain text to stdout"
  echo "  -c NUM     Number of comments to fetch (default: 3)"
  exit 1
}

while getopts "pc:h" opt; do
  case $opt in
    p) PLAIN="--plain" ;;
    c) COMMENTS="$OPTARG" ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $((OPTIND -1))

if [[ $# -eq 0 ]]; then
  usage
fi

TOTAL_TICKETS=$#

for ISSUE_KEY in "$@"; do
  if [[ $TOTAL_TICKETS -gt 1 ]]; then
    echo "================================================================================"
    echo "ISSUE: $ISSUE_KEY"
    echo "================================================================================"
  fi

  CMD=("jira" "issue" "view" "$ISSUE_KEY" "--comments" "$COMMENTS")

  if [[ -n "$PLAIN" ]]; then
    CMD+=("$PLAIN")
  fi

  "${CMD[@]}"
  echo ""
done

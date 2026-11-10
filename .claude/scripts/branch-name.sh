#!/usr/bin/env bash
# Prints a branch name built from .ai-template/config branch_template (see projects/git-safety/TRD.md).
# It only prints the name. Creating the branch is left to `git switch -c`, which git-guard gates.
#
# Usage: branch-name.sh --type <feat|fix|refactor|test|docs|chore|spike> --name "<feature name>" [--ticket <id>]...
# GIT_BRANCH_NAME, if set, is printed as-is (after the length check).

. "$(dirname "${BASH_SOURCE[0]}")/git-safety-lib.sh"
export LC_ALL=C

MAX_BYTES=244
STOP_WORDS=" a an the and or for to of in on with "

usage() {
  echo "usage: branch-name.sh --type <feat|fix|refactor|test|docs|chore|spike> --name \"<feature name>\" [--ticket <id>]..." >&2
  exit 1
}

slugify() { # lowercase, runs of anything but [a-z0-9] become "-", trimmed
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
  printf '%s' "$s"
}

if [ -n "${GIT_BRANCH_NAME:-}" ]; then
  if [ "${#GIT_BRANCH_NAME}" -gt "$MAX_BYTES" ]; then
    echo "branch-name: GIT_BRANCH_NAME exceeds $MAX_BYTES bytes" >&2
    exit 1
  fi
  printf '%s\n' "$GIT_BRANCH_NAME"
  exit 0
fi

type= name=
tickets=()
while [ $# -gt 0 ]; do
  case $1 in
    --type) type=${2:-}; shift 2 ;;
    --name) name=${2:-}; shift 2 ;;
    --ticket) tickets+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done
case $type in feat|fix|refactor|test|docs|chore|spike) ;; *) usage ;; esac

words=()
for w in $(slugify "$name" | tr '-' ' '); do
  case $STOP_WORDS in *" $w "*) continue ;; esac
  words+=("$w")
  [ "${#words[@]}" -eq 4 ] && break
done
if [ "${#words[@]}" -eq 0 ]; then
  echo "branch-name: --name produces an empty slug" >&2
  exit 1
fi

ticket=
if [ "${#tickets[@]}" -eq 1 ]; then
  ticket=$(printf '%s' "${tickets[0]}" | tr -cd 'A-Za-z0-9._-')
fi
author=$(slugify "$(git config user.name 2>/dev/null)")
template=$(read_config branch_template '{type}/{ticket}-{slug}')

# Empty tokens become a marker that is removed together with one adjacent separator.
render() { # slug
  local out=$template value token
  for token in type ticket slug author; do
    case $token in
      type) value=$type ;;
      ticket) value=$ticket ;;
      slug) value=$1 ;;
      author) value=$author ;;
    esac
    out=${out//\{$token\}/${value:-$'\001'}}
  done
  out=$(printf '%s' "$out" | sed "s#$(printf '\001')[-/]##g; s#[-/]$(printf '\001')##g; s#$(printf '\001')##g")
  out=$(printf '%s' "$out" | sed 's#-\{2,\}#-#g; s#/\{2,\}#/#g; s#/-#/#g; s#-/#/#g; s#^[-/]*##; s#[-/]*$##')
  printf '%s' "$out"
}

slug=$(IFS=-; printf '%s' "${words[*]}")
branch=$(render "$slug")
# Too long: shorten only the slug, dropping whole words first, then characters.
while [ "${#branch}" -gt "$MAX_BYTES" ]; do
  if [ "${#words[@]}" -gt 1 ]; then
    unset 'words[${#words[@]}-1]'
    slug=$(IFS=-; printf '%s' "${words[*]}")
  else
    slug=${slug:0:$(( ${#slug} - (${#branch} - MAX_BYTES) ))}
    slug=${slug%-}
  fi
  branch=$(render "$slug")
done

printf '%s\n' "$branch"

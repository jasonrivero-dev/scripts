# Shared helpers for the git-safety hook and scripts (see projects/git-safety/TRD.md).
# Source this file; do not execute it. No dependencies beyond bash and git.

GS_ROOT=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
GS_ROOT=${GS_ROOT//\\//}

# Prints the value of <key> from a key=value file, or <default> when the key is missing or empty.
gs_kv() {
  local file=$1 key=$2 default=$3 line
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      case $line in
        "$key="*)
          line=${line#*=}
          [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
          break
          ;;
      esac
    done <"$file"
  fi
  printf '%s\n' "$default"
}

read_config() { gs_kv "$GS_ROOT/.ai-template/config" "$1" "$2"; }
read_grant() { gs_kv "$GS_ROOT/.ai-template/grants.local" "$1" "$2"; }

is_git_repo() { git -C "${1:-.}" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# main and master are always protected, whatever the config says.
protected_branches() {
  printf 'main\nmaster\n'
  read_config protected_branches "" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

is_protected() {
  local b list
  case $1 in main|master) return 0 ;; esac
  list=$(read_config protected_branches "")
  IFS=',' read -ra list <<<"$list"
  for b in "${list[@]}"; do
    b=${b#"${b%%[![:space:]]*}"}
    b=${b%"${b##*[![:space:]]}"}
    [ "$b" = "$1" ] && return 0
  done
  return 1
}

# Config base_branch, else origin/HEAD, else whichever of main/master exists.
base_branch() {
  local dir=${1:-.} b
  b=$(read_config base_branch "")
  if [ -z "$b" ]; then
    b=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
    b=${b#origin/}
  fi
  if [ -z "$b" ]; then
    if git -C "$dir" show-ref --verify -q refs/heads/main; then
      b=main
    elif git -C "$dir" show-ref --verify -q refs/heads/master; then
      b=master
    else
      b=main
    fi
  fi
  printf '%s\n' "$b"
}

#!/usr/bin/env bash
# PreToolUse hook: gates history-changing git commands (see projects/git-safety/TRD.md).
# Deny = reason on stderr + exit 2. Ask = JSON on stdout. No output = no opinion.
# Never prints the command text itself: it may contain secrets.

input=$(cat)
input=${input#$'\xEF\xBB\xBF'}

# Fast path: this hook runs on every tool call, and most never mention git or a guarded file.
case $input in *git*|*ai-template*|*hooks*|*scripts*|*settings*) ;; *) exit 0 ;; esac

emit() {
  local reason=${2//[\"\\]/}
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
  exit 0
}

# Sets <var> to the unescaped value of the first "key":"..." string in the hook input.
json_field() { # key var
  local re='"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"' m
  [[ $input =~ $re ]] || return 1
  m=${BASH_REMATCH[1]}
  printf -v "$2" '%b' "${m//\\\"/\"}"
}

json_field tool_name tool
json_field command cmd || cmd=
json_field file_path fpath || json_field notebook_path fpath || fpath=

# Commands allowed to mention guarded files: the exact grant reset, the branch-name script, git
# itself (classified below), and single read-only commands. No separators or redirection allowed.
guard_exempt() {
  case $cmd in
    "rm -f .ai-template/grants.local"|"Remove-Item .ai-template/grants.local -ErrorAction SilentlyContinue") return 0 ;;
    *[\;\&\|\>\<\`$'\n']*|*'$('*) return 1 ;;
    "bash .claude/scripts/branch-name.sh "*|"git -c 'alias.bn=!bash .claude/scripts/branch-name.sh' bn "*) return 0 ;;
  esac
  case ${cmd%% *} in
    git|cat|head|tail|grep|ls|type|Get-Content|Get-ChildItem|Select-String) return 0 ;;
  esac
  return 1
}

# Claude must never weaken its own guardrails (hook, settings, config, grants) without approval.
# This is a guardrail against accidental self-escalation, not a boundary against obfuscation.
target="$cmd $fpath"
target=${target//\\//}
case $target in
  *.ai-template*|*grants.local*|*.claude/hooks*|*.claude/scripts*|*.claude/settings*)
    case $tool in
      Bash|PowerShell) guard_exempt || emit ask "git-guard: changing git-safety files (.claude/hooks, .claude/scripts, .claude/settings, .ai-template) needs your approval." ;;
      *) emit ask "git-guard: changing git-safety files (.claude/hooks, .claude/scripts, .claude/settings, .ai-template) needs your approval." ;;
    esac
    ;;
esac

case $tool in Bash|PowerShell) ;; *) exit 0 ;; esac
case $cmd in *git*) ;; *) exit 0 ;; esac

if ! . "$(dirname "${BASH_SOURCE[0]}")/../scripts/git-safety-lib.sh" 2>/dev/null; then
  emit ask "git-guard: helper library missing; approval required."
fi

json_field cwd cwd
cwd=${cwd//\\//}
[ -d "$cwd" ] || cwd=$GS_ROOT

verdict=none
level=0
reason=
raise() {
  local n
  case $1 in deny) n=3 ;; ask) n=2 ;; allow) n=1 ;; *) n=0 ;; esac
  if [ "$n" -gt "$level" ]; then
    verdict=$1
    level=$n
    reason=$2
  fi
}
# A feature-scoped grant (D2) turns an ask into an allow. It never lifts a deny.
grant_allow=
if [ -f "$GS_ROOT/.ai-template/grants.local" ]; then
  grant_allow=$(read_grant allow "")
  grant_allow=${grant_allow// /}
  grant_feature=$(read_grant feature unknown)
fi
ask_for() {
  case ",$grant_allow," in
    *",$1,"*) raise allow "git-guard: '$1' allowed by feature grant '$grant_feature'." ;;
    *) raise ask "git-guard: '$1' changes git history and needs your approval." ;;
  esac
}

resolve_dir() {
  case $1 in
    /*|[A-Za-z]:*) printf '%s' "${1//\\//}" ;;
    *) printf '%s/%s' "$cwd" "$1" ;;
  esac
}

branch_exists() {
  git -C "$1" show-ref --verify -q "refs/heads/$2" || git -C "$1" show-ref --verify -q "refs/remotes/origin/$2"
}

check_push() {
  local dir=$1 current=$2 a r target
  local positional=() targets=()
  for a in "${args[@]}"; do
    case $a in -*) ;; *) positional+=("$a") ;; esac
  done
  if [ "${#positional[@]}" -le 1 ]; then
    # No refspec: git pushes to @{push}, which can differ from the branch name (push.default=upstream).
    targets=("$current")
    r=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null) && targets+=("${r#*/}")
  else
    for r in "${positional[@]:1}"; do
      r=${r#+}
      target=${r##*:}
      target=${target#refs/heads/}
      [ "$target" = HEAD ] && target=$current
      targets+=("$target")
    done
  fi
  for target in "${targets[@]}"; do
    if [ -n "$target" ] && is_protected "$target"; then
      raise deny "git-guard: 'push' to protected branch '$target' is blocked. Create a feature branch with /branch."
      return
    fi
  done
  ask_for push
}

check_checkout() {
  local dir=$1 a after_dashdash=0
  local positional=()
  for a in "${args[@]}"; do
    if [ "$after_dashdash" = 1 ]; then break; fi
    case $a in
      --) after_dashdash=1 ;;
      -b|-B|--orphan|-f|--force) ask_for checkout; return ;;
      .) ask_for checkout; return ;;
      -) positional+=("-") ;;
      -*) ;;
      *) positional+=("$a") ;;
    esac
  done
  if [ "$after_dashdash" = 1 ] || [ "${#positional[@]}" -gt 1 ]; then
    ask_for checkout
  elif [ "${#positional[@]}" = 1 ] && [ "${positional[0]}" != "-" ] && ! branch_exists "$dir" "${positional[0]}"; then
    ask_for checkout
  fi
}

is_known() {
  case $1 in
    commit|push|merge|cherry-pick|revert|am|rebase|pull|fetch|reset|rm|restore|clean|update-ref|filter-branch|replace) ;;
    switch|checkout|branch|stash|tag|remote|reflog|notes) ;;
    status|diff|log|show|add|rev-parse|symbolic-ref|merge-base|cat-file|show-ref|ls-files|ls-remote|ls-tree) ;;
    blame|grep|config|describe|shortlog|version|help|check-ignore|check-attr|for-each-ref|rev-list|init|clone) ;;
    *) return 1 ;;
  esac
}

classify() {
  local j=$(( $1 + 1 )) dir=$cwd sub first current a value inline=()
  local -a expansion
  while [ "$j" -lt "${#w[@]}" ]; do
    case ${w[j]} in
      -C) dir=$(resolve_dir "${w[j+1]:-.}"); j=$((j + 2)) ;;
      -c) inline+=("${w[j+1]:-}"); j=$((j + 2)) ;;
      --git-dir|--work-tree|--namespace) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  sub=${w[j]:-}
  [ -n "$sub" ] || return
  # One git call: exit 0 = on a branch, 1 = detached HEAD, other = not a git repo.
  current=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)
  case $? in 0|1) ;; *) return ;; esac
  args=("${w[@]:j+1}")

  # Aliases (inline -c alias.X=... or configured) are expanded one level and classified as what
  # they run. Shell aliases (!...), nested aliases, and unknown commands such as extensions ask.
  if ! is_known "$sub"; then
    value=
    for a in "${inline[@]}"; do
      case $a in "alias.$sub="*) value=${a#*=} ;; esac
    done
    [ -n "$value" ] || value=$(git -C "$dir" config --get "alias.$sub" 2>/dev/null)
    case $value in ''|'!'*) ask_for "$sub"; return ;; esac
    read -ra expansion <<<"$value"
    sub=${expansion[0]}
    args=("${expansion[@]:1}" "${args[@]}")
    is_known "$sub" || { ask_for "$sub"; return; }
  fi
  first=${args[0]:-}

  case $sub in
    commit)
      if [ -n "$current" ] && is_protected "$current"; then
        raise deny "git-guard: 'commit' on protected branch '$current' is blocked. Create a feature branch with /branch."
      else
        ask_for commit
      fi
      ;;
    push) check_push "$dir" "$current" ;;
    merge|cherry-pick|revert|am|rebase|pull|fetch|reset|rm|restore|clean|update-ref|filter-branch|replace)
      ask_for "$sub"
      ;;
    switch)
      for a in "${args[@]}"; do
        case $a in -c|-C|--create*|--force-create*|--orphan*|-f|--force|--discard-changes) ask_for switch; return ;; esac
      done
      ;;
    checkout) check_checkout "$dir" ;;
    branch)
      case $first in
        ""|--show-current|--list|-l|-a|--all|-r|--remotes|-v|-vv|--verbose|--contains*|--no-contains*|--merged*|--no-merged*|--points-at*|--sort*|--format*|--column*|--no-column) ;;
        -d|-D|--delete|-m|-M|--move|-c|-C|--copy|-f|--force|-u|--set-upstream-to*|--unset-upstream|--edit-description) ask_for branch ;;
        -*) ;;
        *) ask_for branch ;;
      esac
      ;;
    stash) case $first in drop|clear) ask_for stash ;; esac ;;
    tag)
      case $first in
        ""|-l|--list|-n*|-v|--verify|--contains*|--no-contains*|--points-at*|--merged*|--no-merged*|--sort*|--format*) ;;
        *) ask_for tag ;;
      esac
      ;;
    remote) case $first in add|remove|rm|rename|set-url|set-head|set-branches|prune|update) ask_for remote ;; esac ;;
    reflog) case $first in expire|delete) ask_for reflog ;; esac ;;
    notes) case $first in add|append|copy|edit|merge|remove|prune) ask_for notes ;; esac ;;
    config)
      # Reads take one key. Writes (values, --unset, set/unset subcommands, ...) can add aliases
      # or rewrite .ai-template/config, so they ask.
      local positional=0
      for a in "${args[@]}"; do
        case $a in
          --unset*|--add|--replace-all|--rename-section|--remove-section|-e|--edit) ask_for config; return ;;
          -*) ;;
          *) positional=$((positional + 1)) ;;
        esac
      done
      case $first in set|unset|rename-section|remove-section|edit) ask_for config; return ;; esac
      [ "$positional" -ge 2 ] && ask_for config
      ;;
  esac
}

# Split on shell separators and drop quotes so `bash -c "git commit"` and `a && git push` are seen.
text=${cmd//[\"\'\`]/ }
text=${text//\$\(/$'\n'}
text=${text//[;&|()\{\}$'\r']/$'\n'}

while IFS= read -r line; do
  read -ra w <<<"$line"
  for ((i = 0; i < ${#w[@]}; i++)); do
    case ${w[i]} in
      git|*/git|*\\git|git.exe|*/git.exe|*\\git.exe) classify "$i" ;;
    esac
  done
done <<<"$text"

case $verdict in
  deny) printf '%s\n' "$reason" >&2; exit 2 ;;
  ask|allow) emit "$verdict" "$reason" ;;
esac
exit 0

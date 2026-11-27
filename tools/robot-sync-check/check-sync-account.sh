#!/usr/bin/env bash
# Read-only check that the sync agents' account can collect bundle data on a robot.

set -euo pipefail

SSH_USER="novarc"
SSH_CONNECT_TIMEOUT_S=10
HOST_PATTERN='^[A-Za-z0-9][A-Za-z0-9._:-]*$'

usage() {
  cat <<EOF
Usage: $(basename "$0") <robot-host>
       $(basename "$0") -h | --help

Connects once over SSH as user ${SSH_USER} (interactive password prompt from ssh;
the script never reads or stores it) and runs read-only checks:

  1. dpkg-query of novarc-* packages works as ${SSH_USER}
  2. the same command works under a minimal cron-like environment
  3. installed novarc-* count, novarc-bundle-* versions and component counts,
     installed packages that are in no bundle's Depends (names and counts only)
  4. /etc/cron.d/novarc-ghost exists and runs as ${SSH_USER}
  5. /var/opt/novarc/configure has SWR_ID, SWR_API_URL, SWR_API_KEY
     (prints SWR_ID, the URL scheme only, and set/missing for the key)

Each check prints PASS or FAIL with the reason. Exit status is non-zero if any
check fails or the SSH session fails. Nothing is written on the robot.

Example:
  $(basename "$0") robot-dev-01.example.net
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac
if [ "$#" -ne 1 ] || ! [[ "$1" =~ $HOST_PATTERN ]]; then
  echo "FAIL: expected exactly one valid robot host" >&2
  usage >&2
  exit 2
fi
HOST="$1"

read -r -d '' REMOTE_SCRIPT <<'REMOTE' || true
DPKG=/usr/bin/dpkg-query
DPKG_FORMAT='${db:Status-Abbrev}\t${Package}\t${Version}\t${Depends}\n'
PKG_GLOB='novarc-*'
BUNDLE_PREFIX='novarc-bundle-'
INSTALLED_STATUS='ii'
CRON_FILE=/etc/cron.d/novarc-ghost
EXPECTED_CRON_USER=novarc
CONFIGURE_FILE=/var/opt/novarc/configure
CRON_PATH=/usr/bin:/bin

fails=0
pass() { echo "PASS [$1] $2"; }
fail() { echo "FAIL [$1] $2"; fails=$((fails + 1)); }

out1=$("$DPKG" -W -f="$DPKG_FORMAT" "$PKG_GLOB" 2>&1) && rc1=0 || rc1=$?
if [ "$rc1" -eq 0 ]; then
  pass 1 "dpkg-query as $(id -un) exit 0"
else
  fail 1 "dpkg-query as $(id -un) exit $rc1: $(printf '%s' "$out1" | head -n 1)"
fi

out2=$(env -i PATH="$CRON_PATH" "$DPKG" -W -f="$DPKG_FORMAT" "$PKG_GLOB" 2>&1) && rc2=0 || rc2=$?
if [ "$rc2" -eq 0 ] && [ "$out2" = "$out1" ]; then
  pass 2 "dpkg-query under env -i PATH=$CRON_PATH exit 0, same output"
elif [ "$rc2" -eq 0 ]; then
  fail 2 "exit 0 under env -i but output differs from the login-user run"
else
  fail 2 "exit $rc2 under env -i: $(printf '%s' "$out2" | head -n 1)"
fi

if [ "$rc1" -eq 0 ]; then
  installed=$(printf '%s\n' "$out1" | awk -F'\t' -v s="$INSTALLED_STATUS" '$1 ~ "^" s "[ ]*$" {print $2}' | sort -u)
  n_installed=$(printf '%s\n' "$installed" | sed '/^$/d' | wc -l)
  bundles=$(printf '%s\n' "$out1" | awk -F'\t' -v s="$INSTALLED_STATUS" -v p="$BUNDLE_PREFIX" \
    '$1 ~ "^" s "[ ]*$" && index($2, p) == 1 {print $2 "\t" $3 "\t" $4}')
  bundled=$(printf '%s\n' "$bundles" | awk -F'\t' '{
      n = split($3, d, /,[ ]*/)
      for (i = 1; i <= n; i++) if (match(d[i], /^[^ ]+ \(= [^)]+\)/)) { split(d[i], a, " "); print a[1] }
    }' | sort -u)
  echo "INFO [3] installed (status $INSTALLED_STATUS) $PKG_GLOB packages: $n_installed"
  n_bundles=0
  while IFS=$'\t' read -r name ver deps; do
    [ -n "$name" ] || continue
    n_bundles=$((n_bundles + 1))
    comps=$(printf '%s\n' "$deps" | awk '{n = split($0, d, /,[ ]*/); c = 0
      for (i = 1; i <= n; i++) if (d[i] ~ /^[^ ]+ \(= [^)]+\)/) c++; print c}')
    echo "INFO [3] bundle $name version $ver components $comps"
  done <<<"$bundles"
  unbundled=$(comm -23 <(printf '%s\n' "$installed" | sed '/^$/d') <(printf '%s\n%s\n' "$bundled" "$(printf '%s\n' "$bundles" | cut -f1)" | sed '/^$/d' | sort -u))
  n_unbundled=$(printf '%s\n' "$unbundled" | sed '/^$/d' | wc -l)
  echo "INFO [3] unbundled (installed, not a bundle, in no bundle Depends): $n_unbundled"
  printf '%s\n' "$unbundled" | sed '/^$/d; s/^/INFO [3]   unbundled: /'
  if [ "$n_installed" -gt 0 ] && [ "$n_bundles" -gt 0 ]; then
    pass 3 "$n_installed installed, $n_bundles bundle(s), $n_unbundled unbundled"
  elif [ "$n_installed" -eq 0 ]; then
    fail 3 "no installed $PKG_GLOB packages"
  else
    fail 3 "no installed $BUNDLE_PREFIX* package"
  fi
else
  fail 3 "skipped: check 1 failed"
fi

if [ ! -e "$CRON_FILE" ]; then
  fail 4 "$CRON_FILE does not exist"
elif [ ! -r "$CRON_FILE" ]; then
  fail 4 "$CRON_FILE not readable by $(id -un)"
else
  cron_users=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {next} NF >= 7 {print $6}' "$CRON_FILE" | sort -u)
  if [ -z "$cron_users" ]; then
    fail 4 "no job lines found in $CRON_FILE"
  elif [ "$cron_users" = "$EXPECTED_CRON_USER" ]; then
    pass 4 "$CRON_FILE runs as user $cron_users"
  else
    fail 4 "$CRON_FILE runs as user(s): $(printf '%s' "$cron_users" | tr '\n' ' ')"
  fi
fi

cfg_get() {
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=(.*)$/\2/p" "$CONFIGURE_FILE" | tail -n 1 | sed -E "s/^[\"']//; s/[\"']$//"
}
if [ ! -r "$CONFIGURE_FILE" ]; then
  fail 5 "$CONFIGURE_FILE missing or not readable by $(id -un)"
else
  swr_id=$(cfg_get SWR_ID)
  swr_url=$(cfg_get SWR_API_URL)
  swr_key=$(cfg_get SWR_API_KEY)
  problems=""
  [ -n "$swr_id" ] || problems="$problems SWR_ID-missing"
  case "$swr_url" in
    *://*) scheme=${swr_url%%://*} ;;
    "") scheme=""; problems="$problems SWR_API_URL-missing" ;;
    *) scheme=""; problems="$problems SWR_API_URL-has-no-scheme" ;;
  esac
  if [ -n "$swr_key" ]; then key_state=set; else key_state=missing; problems="$problems SWR_API_KEY-missing"; fi
  echo "INFO [5] SWR_ID=${swr_id:-<missing>} SWR_API_URL scheme=${scheme:-<none>} SWR_API_KEY=$key_state"
  if [ -z "$problems" ]; then pass 5 "SWR_ID, SWR_API_URL, SWR_API_KEY present"; else fail 5 "problems:$problems"; fi
fi

echo "SUMMARY failures=$fails"
REMOTE

if ! output=$(printf '%s\n' "$REMOTE_SCRIPT" | ssh -T -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "${SSH_USER}@${HOST}" bash -s); then
  printf '%s\n' "${output:-}"
  echo "FAIL: ssh session to ${SSH_USER}@${HOST} failed" >&2
  exit 1
fi
printf '%s\n' "$output"

failures=$(printf '%s\n' "$output" | sed -n 's/^SUMMARY failures=\([0-9][0-9]*\)$/\1/p' | tail -n 1)
if [ -z "$failures" ]; then
  echo "FAIL: no summary received from the robot" >&2
  exit 1
fi
[ "$failures" -eq 0 ]

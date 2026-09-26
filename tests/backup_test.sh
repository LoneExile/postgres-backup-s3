#!/usr/bin/env bash
# Hermetic test for backup.sh's data-safety guarantees:
#   - a failing dump never deletes existing backups (the retention prune is
#     skipped for the whole run), and
#   - a failing dump never leaves an empty or partial object behind.
#
# pg_dump, psql, mc and curl are replaced by stubs on PATH that record every
# invocation. The mc stub keeps its "bucket" in a temp dir, and its retention
# prune really deletes seeded objects older than --older-than, so the test sees
# what a run leaves in the store. No network, database, or credentials needed.
#
#   tests/backup_test.sh                                # tests ./backup.sh
#   BACKUP_SH=/path/to/other/backup.sh tests/backup_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SH="${BACKUP_SH:-$here/../backup.sh}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

# --- stubs -------------------------------------------------------------------
# pg_dump: fails (after emitting a partial dump) for any db in STUB_FAIL_DBS.
cat >"$bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG/pg_dump"
db=""
while [ $# -gt 0 ]; do
  case "$1" in -d) db="$2"; shift 2 ;; *) shift ;; esac
done
echo "-- PostgreSQL database dump of $db"
for f in ${STUB_FAIL_DBS:-}; do
  if [ "$f" = "$db" ]; then
    echo "pg_dump: error: dumping database \"$db\" failed" >&2
    exit 1
  fi
done
echo "SELECT 1;"
EOF

# psql: answers the auto-discovery query with STUB_DBS.
cat >"$bin/psql" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG/psql"
printf '%s\n' $STUB_DBS
EOF

# mc: alias "store" maps to the directory STUB_STORE.
cat >"$bin/mc" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG/mc"
path() { echo "$STUB_STORE/${1#store/}"; }
last="${!#}"
case "$1" in
  alias | mb) ;;
  pipe)
    mkdir -p "$(dirname "$(path "$last")")"
    cat >"$(path "$last")"
    ;;
  stat)
    [ -f "$(path "$last")" ] || exit 1
    printf '{"status":"success","size":%s}\n' "$(wc -c <"$(path "$last")" | tr -d ' ')"
    ;;
  rm)
    if [ -n "${STUB_MC_RM_FAIL:-}" ]; then
      echo "mc: <ERROR> simulated rm failure" >&2
      exit 1
    fi
    recursive="" days=""
    while [ $# -gt 1 ]; do
      case "$1" in
        --recursive) recursive=1 ;;
        --older-than) days="${2%d}"; shift ;;
      esac
      shift
    done
    if [ -n "$recursive" ]; then
      find "$(path "$last")" -type f -mtime "+$days" -delete
    else
      [ -f "$(path "$last")" ] || { echo "mc: <ERROR> object does not exist" >&2; exit 1; }
      rm -f "$(path "$last")"
    fi
    ;;
  *)
    echo "mc stub: unexpected command: $*" >&2
    exit 2
    ;;
esac
EOF

# curl: records the Pushgateway request and its body.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG/curl"
cat >>"$STUB_LOG/push"
EOF

chmod +x "$bin"/*

# --- harness -----------------------------------------------------------------
failures=0
case_failed=0
check() { # check <description> <command...>
  local desc="$1"
  shift
  if "$@"; then
    echo "  ok    $desc"
  else
    echo "  FAIL  $desc"
    failures=$((failures + 1))
    case_failed=1
  fi
}

# run_case <name> <dbs> <failing dbs> [extra env...]
# Seeds one 30-day-old backup per db, runs backup.sh once, and leaves the
# results in $dir (stdout, stderr, log/<tool>, store/) and $rc.
run_case() {
  local name="$1" dbs="$2" fail_dbs="$3" db
  shift 3
  dir="$tmp/$name"
  mkdir -p "$dir/log" "$dir/store"
  touch "$dir/log/mc" "$dir/log/push"
  for db in $dbs; do
    mkdir -p "$dir/store/bkt/pfx/$db"
    echo "old good dump" >"$dir/store/bkt/pfx/$db/$db-20200101T000000Z.sql.gz"
    touch -t 202001010000 "$dir/store/bkt/pfx/$db/$db-20200101T000000Z.sql.gz"
  done
  echo "== $name"
  case_failed=0
  set +e
  env -i PATH="$bin:$PATH" \
    STUB_LOG="$dir/log" STUB_STORE="$dir/store" STUB_DBS="$dbs" STUB_FAIL_DBS="$fail_dbs" "$@" \
    PGHOST=db.test PGUSER=backup PGPASSWORD=pw \
    S3_ENDPOINT=http://s3.test S3_BUCKET=bkt S3_ACCESS_KEY=ak S3_SECRET_KEY=sk \
    S3_PREFIX=pfx KEEP_DAYS=7 PUSHGATEWAY_URL=http://pushgateway.test:9091 \
    bash "$BACKUP_SH" >"$dir/stdout" 2>"$dir/stderr"
  rc=$?
  set -e
}

show_case_on_failure() {
  [ "$case_failed" -eq 0 ] && return
  local f
  for f in stdout stderr log/mc log/push; do
    echo "  --- $f"
    sed 's/^/  | /' "$dir/$f"
  done
}

exit_code_is() { [ "$rc" -eq "$1" ]; }
out_has() { grep -qF -- "$1" "$dir/stdout" "$dir/stderr"; }
stderr_has() { grep -qxF -- "$1" "$dir/stderr"; }
not() { ! "$@"; }
each() { # each <predicate> <arg>...: predicate holds for every arg
  local f="$1" x
  shift
  for x in "$@"; do "$f" "$x" || return 1; done
}
none() { # none <predicate> <arg>...: predicate holds for no arg
  local f="$1" x
  shift
  for x in "$@"; do ! "$f" "$x" || return 1; done
}
prune_calls_are() { [ "$(grep -c -- '^rm --recursive --force --older-than 7d store/bkt/pfx/$' "$dir/log/mc")" -eq "$1" ]; }
rm_calls() { grep -- '^rm ' "$dir/log/mc" || true; }
no_object_rm() { ! rm_calls | grep -qv -- --recursive; }
pushed() { grep -q "^$1\$" "$dir/log/push"; }
new_key() { grep -o -- "^pipe store/bkt/pfx/$1/$1-.*" "$dir/log/mc" | cut -d' ' -f2; }
old_backup_kept() { [ -f "$dir/store/bkt/pfx/$1/$1-20200101T000000Z.sql.gz" ]; }
new_backup_stored() {
  local key
  key="$(new_key "$1")"
  [ -n "$key" ] && [ -s "$dir/store/${key#store/}" ]
}
no_new_object() {
  local key
  key="$(new_key "$1")"
  [ -n "$key" ] && [ ! -e "$dir/store/${key#store/}" ]
}
only_rm_is_object() { # exactly one rm call: a non-recursive rm of this run's object for $1
  local calls key
  calls="$(rm_calls)"
  key="$(new_key "$1")"
  [ -n "$key" ] && [ "$(printf '%s\n' "$calls" | grep -c .)" -eq 1 ] &&
    [ "${calls##* }" = "$key" ] && [[ "$calls" != *--recursive* ]]
}

# --- cases -------------------------------------------------------------------
run_case all-succeed "app analytics" ""
check "exit 0" exit_code_is 0
check "new dumps stored" each new_backup_stored app analytics
check "retention prune invoked once" prune_calls_are 1
check "backups older than KEEP_DAYS pruned" none old_backup_kept app analytics
check "no other rm" no_object_rm
check "pg_backup_success 1 pushed" pushed "pg_backup_success 1"
check "last_success timestamp pushed" pushed "pg_backup_last_success_timestamp_seconds [0-9]*"
check "no FAILED / skip lines" none out_has FAILED "skipping prune"
show_case_on_failure

run_case one-of-two-fails "app bad" "bad"
check "exit 1" exit_code_is 1
check "FAILED line on stderr" stderr_has "[pg-backup] FAILED dumping bad"
check "only rm is the failed db's own object" only_rm_is_object bad
check "no partial object left for the failed db" no_new_object bad
check "healthy db's dump stored" new_backup_stored app
check "retention prune NOT invoked" prune_calls_are 0
check "existing backups kept" each old_backup_kept app bad
check "prune skip logged" out_has "skipping prune"
check "pg_backup_success 0 pushed" pushed "pg_backup_success 0"
check "last_success timestamp NOT pushed" not pushed "pg_backup_last_success_timestamp_seconds [0-9]*"
show_case_on_failure

run_case all-fail "app bad" "app bad"
check "exit 1" exit_code_is 1
check "FAILED line per db" each stderr_has "[pg-backup] FAILED dumping app" "[pg-backup] FAILED dumping bad"
check "no partial objects left" each no_new_object app bad
check "retention prune NOT invoked" prune_calls_are 0
check "existing backups kept" each old_backup_kept app bad
check "prune skip logged" out_has "skipping prune"
check "pg_backup_success 0 pushed" pushed "pg_backup_success 0"
check "last_success timestamp NOT pushed" not pushed "pg_backup_last_success_timestamp_seconds [0-9]*"
show_case_on_failure

run_case cleanup-rm-fails "bad" "bad" STUB_MC_RM_FAIL=1
check "exit 1" exit_code_is 1
check "FAILED line on stderr" stderr_has "[pg-backup] FAILED dumping bad"
check "retention prune NOT invoked" prune_calls_are 0
check "existing backup kept" old_backup_kept bad
check "metrics still pushed: pg_backup_success 0" pushed "pg_backup_success 0"
check "last_success timestamp NOT pushed" not pushed "pg_backup_last_success_timestamp_seconds [0-9]*"
show_case_on_failure

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "PASSED"

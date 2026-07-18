#!/usr/bin/env bash
# postgres-backup-s3 — logical pg_dump of one or more databases on a single
# PostgreSQL server, gzipped and STREAMED to any S3-compatible store (AWS S3,
# MinIO, RustFS, Cloudflare R2, Backblaze B2, Ceph RGW, ...), then prune backups
# older than KEEP_DAYS. Optionally publishes per-db dump size + last-success
# metrics to a Prometheus Pushgateway.
#
# It runs ONCE and exits — bring your own scheduler (Kubernetes CronJob, systemd
# timer, host cron, ofelia, ...). See the README for examples.
#
# Env (required unless a default is shown):
#   PGHOST                       source PostgreSQL host
#   PGPORT=5432                  source port
#   PGUSER                       source user (needs pg_dump rights on the DBs)
#   PGPASSWORD                   source password
#   PGDATABASE=postgres          db to connect to for discovery
#   DATABASES=""                 space-separated db list; if EMPTY, auto-discover
#                                every non-template, connectable db (excl. 'postgres')
#   S3_ENDPOINT                  e.g. https://s3.amazonaws.com or http://minio:9000
#   S3_BUCKET                    target bucket (created if missing)
#   S3_ACCESS_KEY / S3_SECRET_KEY
#   S3_PREFIX=postgres           key prefix + Pushgateway instance label
#   KEEP_DAYS=7                  retention window (older objects pruned each run)
#   PUSHGATEWAY_URL=""           optional; if set, push size/success metrics
#   PASSPHRASE=""                optional; if set, encrypt dumps with gpg AES-256
set -euo pipefail

: "${PGHOST:?}" "${PGUSER:?}" "${PGPASSWORD:?}"
: "${S3_ENDPOINT:?}" "${S3_BUCKET:?}" "${S3_ACCESS_KEY:?}" "${S3_SECRET_KEY:?}"
export PGPASSWORD
PGPORT="${PGPORT:-5432}"
S3_PREFIX="${S3_PREFIX:-postgres}"
KEEP_DAYS="${KEEP_DAYS:-7}"

# Auto-discover databases when DATABASES is empty — drift-proof (a hardcoded list
# silently misses newly-created / renamed DBs).
if [ -z "${DATABASES:-}" ]; then
  DATABASES="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "${PGDATABASE:-postgres}" -tAqc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY datname")"
  echo "[pg-backup] discovered databases: $(echo $DATABASES | tr '\n' ' ')"
fi
: "${DATABASES:?no databases to back up}"

mc alias set store "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null
mc mb --ignore-existing "store/$S3_BUCKET" >/dev/null

# Optional symmetric encryption (AES-256) when PASSPHRASE is set — the object
# then gets a .gpg suffix. Decrypt on restore with the same passphrase.
maybe_encrypt() {
  if [ -n "${PASSPHRASE:-}" ]; then
    gpg --symmetric --batch --yes --cipher-algo AES256 --pinentry-mode loopback \
        --passphrase-fd 3 -o - 3<<<"$PASSPHRASE"
  else
    cat
  fi
}

ts="$(date -u +%Y%m%dT%H%M%SZ)"
rc=0
metrics=""
for db in $DATABASES; do
  key="$S3_PREFIX/$db/$db-$ts.sql.gz${PASSPHRASE:+.gpg}"
  echo "[pg-backup] dumping $PGHOST/$db -> s3://$S3_BUCKET/$key"
  if pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$db" --no-owner --no-privileges --clean --if-exists \
      | gzip -c \
      | maybe_encrypt \
      | mc pipe "store/$S3_BUCKET/$key"; then
    sz="$(mc stat --json "store/$S3_BUCKET/$key" 2>/dev/null | grep -o '"size":[0-9]*' | head -1 | cut -d: -f2)"
    echo "[pg-backup] OK $db (${sz:-0} bytes)"
    metrics="${metrics}pg_backup_size_bytes{db=\"${db}\"} ${sz:-0}
"
  else
    echo "[pg-backup] FAILED dumping $db" >&2
    rc=1
  fi
done

# Retention: delete objects older than KEEP_DAYS under this server's prefix.
echo "[pg-backup] pruning store/$S3_BUCKET/$S3_PREFIX/ older than ${KEEP_DAYS}d"
mc rm --recursive --force --older-than "${KEEP_DAYS}d" "store/$S3_BUCKET/$S3_PREFIX/" 2>/dev/null || true

# Publish metrics to a Prometheus Pushgateway (grouped by job=pg_backup,
# instance=<prefix>). Non-fatal: a Pushgateway outage never fails the backup.
if [ -n "${PUSHGATEWAY_URL:-}" ]; then
  {
    echo "# TYPE pg_backup_success gauge"
    echo "pg_backup_success $([ $rc -eq 0 ] && echo 1 || echo 0)"
    if [ $rc -eq 0 ]; then
      echo "# TYPE pg_backup_last_success_timestamp_seconds gauge"
      echo "pg_backup_last_success_timestamp_seconds $(date +%s)"
    fi
    echo "# TYPE pg_backup_size_bytes gauge"
    printf '%s' "$metrics"
  } | curl -sf --max-time 15 --data-binary @- \
      "${PUSHGATEWAY_URL}/metrics/job/pg_backup/instance/${S3_PREFIX}" \
    && echo "[pg-backup] metrics pushed" \
    || echo "[pg-backup] WARN: pushgateway push failed (non-fatal)"
fi

exit $rc

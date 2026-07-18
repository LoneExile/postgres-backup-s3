# postgres-backup-s3

Tiny, scheduler-agnostic PostgreSQL → S3 backup container. It takes a logical
`pg_dump` of one or more databases, gzips it, **streams** it straight to any
S3-compatible object store, prunes old backups, and (optionally) reports metrics
to a Prometheus Pushgateway. One run, then it exits — you bring the scheduler.

Works with **AWS S3, MinIO, RustFS, Cloudflare R2, Backblaze B2, Ceph RGW**, or
anything else that speaks the S3 API. Multi-arch image (`linux/amd64` +
`linux/arm64`), runs as a non-root user.

```
ghcr.io/loneexile/postgres-backup-s3:latest
```

## Why another one?

The venerable [`eeshugerman/postgres-backup-s3`](https://github.com/eeshugerman/postgres-backup-s3)
(itself a fork of `schickling/postgres-backup-s3`) is archived. This is an
independent, from-scratch take with a few deliberate differences:

| | this project | schickling / eeshugerman |
| --- | --- | --- |
| Scheduling | **none — use k8s CronJob, systemd timer, cron, ofelia** | built-in `go-cron` (`SCHEDULE`) |
| Databases per run | **auto-discovers every DB on the server** (or an explicit list) | single `POSTGRES_DATABASE` (or `pg_dumpall`) |
| Upload | **streamed** `pg_dump \| gzip \| mc pipe` (no temp file) | dump to disk, then upload |
| S3 client | `mc` (MinIO client) | `aws-cli` |
| Observability | **optional Prometheus Pushgateway metrics** | — |
| Retention | `KEEP_DAYS` (server-side prune) | `BACKUP_KEEP_DAYS` |

Being scheduler-agnostic is the point: in Kubernetes you almost always want a
`CronJob` (native retries, history, RBAC, per-namespace secrets) rather than a
long-lived container running its own cron loop.

Optional **gpg AES-256 at-rest encryption** (`PASSPHRASE`) is supported too, so
the only real trade-off versus the older tools is the lack of a built-in cron.

## Configuration

All configuration is via environment variables.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `PGHOST` | ✅ | | Source PostgreSQL host |
| `PGPORT` | | `5432` | Source port |
| `PGUSER` | ✅ | | Source user (needs `pg_dump` rights) |
| `PGPASSWORD` | ✅ | | Source password |
| `PGDATABASE` | | `postgres` | DB to connect to for auto-discovery |
| `DATABASES` | | *(empty → auto-discover)* | Space-separated DB list; empty = every non-template, connectable DB except `postgres` |
| `S3_ENDPOINT` | ✅ | | e.g. `https://s3.amazonaws.com`, `http://minio:9000` |
| `S3_BUCKET` | ✅ | | Target bucket (created if missing) |
| `S3_ACCESS_KEY` | ✅ | | |
| `S3_SECRET_KEY` | ✅ | | |
| `S3_PREFIX` | | `postgres` | Key prefix + Pushgateway instance label |
| `KEEP_DAYS` | | `7` | Retention window; older objects pruned each run |
| `PUSHGATEWAY_URL` | | *(off)* | If set, push `pg_backup_*` metrics here |
| `PASSPHRASE` | | *(off)* | If set, encrypt each dump with gpg AES-256 (object gets a `.gpg` suffix) |

Objects are written to:

```
s3://<S3_BUCKET>/<S3_PREFIX>/<db>/<db>-<UTC-timestamp>.sql.gz
```

Dumps use `--no-owner --no-privileges --clean --if-exists`, so a restore drops
and recreates objects and doesn't depend on matching role names — and being
*logical* dumps, they restore across PostgreSQL major versions.

## Usage

### One-shot (Docker)

```sh
docker run --rm \
  -e PGHOST=db.example.com -e PGUSER=postgres -e PGPASSWORD=secret \
  -e S3_ENDPOINT=https://s3.amazonaws.com -e S3_BUCKET=my-pg-backups \
  -e S3_ACCESS_KEY=AKIA... -e S3_SECRET_KEY=... \
  -e S3_PREFIX=prod -e KEEP_DAYS=14 \
  ghcr.io/loneexile/postgres-backup-s3:latest
```

### Scheduling

The container runs once and exits. Pick a scheduler:

- **Host cron:** `0 3 * * * docker run --rm ... postgres-backup-s3:latest`
- **systemd timer:** a `oneshot` service + `.timer`.
- **Docker + [ofelia](https://github.com/mcuadros/ofelia):** see `examples/docker-compose.yml`.
- **Kubernetes CronJob:** see `examples/kubernetes-cronjob.yaml` (recommended).

### Kubernetes

`examples/kubernetes-cronjob.yaml` is a complete daily-backup `CronJob` + `Secret`.
The auto-discovery + streaming design pairs well with
[CloudNativePG](https://cloudnative-pg.io/): point `PGHOST` at the `<cluster>-rw`
service and read `PGUSER`/`PGPASSWORD` from the generated `<cluster>-app` secret.

## Restore

```sh
mc alias set store "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
mc ls --recursive store/my-pg-backups/prod/mydb/
# The dump was made with --clean --if-exists, so it drops+recreates objects:
mc cat store/my-pg-backups/prod/mydb/mydb-20260101T030000Z.sql.gz \
  | gunzip | psql -h db.example.com -U postgres -d mydb

# If PASSPHRASE was set, objects end in .sql.gz.gpg — decrypt first:
mc cat store/my-pg-backups/prod/mydb/mydb-20260101T030000Z.sql.gz.gpg \
  | gpg --batch --quiet --decrypt --pinentry-mode loopback --passphrase-fd 3 3<<<"$PASSPHRASE" \
  | gunzip | psql -h db.example.com -U postgres -d mydb
```

In Kubernetes, pipe into `kubectl exec -i <pg-pod> -- psql ...` and scale the
consuming app to 0 during a full restore.

## Metrics

When `PUSHGATEWAY_URL` is set, each run pushes to a Prometheus Pushgateway
(`job=pg_backup`, `instance=<S3_PREFIX>`):

- `pg_backup_success` — `1`/`0` for the run
- `pg_backup_last_success_timestamp_seconds`
- `pg_backup_size_bytes{db="..."}` — compressed size per database

For "missed backup" alerting in Kubernetes, prefer
`kube_cronjob_status_last_successful_time` (from kube-state-metrics) over these —
it survives a Pushgateway restart and won't false-alert.

## Building

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t postgres-backup-s3 .
```

The image pins the `mc` release and installs `postgresql17-client`. To back up a
server older than the client you can dump with a newer client, but if you need an
exact match, change `postgresql17-client` in the `Dockerfile`.

## License

MIT — see [LICENSE](LICENSE).

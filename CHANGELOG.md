# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-09-26

### Fixed
- **A failing dump no longer destroys existing backups.** The `KEEP_DAYS` prune
  used to run even when a dump failed, and the streamed upload had already
  created an empty (20-byte) object for the failed database, so a server whose
  dump failed `KEEP_DAYS` nights in a row was left with nothing but empty
  objects. Now the failed dump's object is removed, and the prune is skipped for
  any run in which a dump failed: a failing backup never deletes existing
  backups and never leaves an empty object. The `FAILED dumping <db>` log line,
  exit code `1`, and metrics of a failed run are unchanged, as is everything
  about a fully successful run.
- **Image build:** `dl.min.io` now returns `410 Gone` (MinIO archived `mc`), so
  the pinned `mc` release (`RELEASE.2025-08-13T08-35-41Z`, same binary) is now
  fetched from its GitHub release assets and verified against hard-coded
  per-arch sha256 checksums at build time.

### Added
- `tests/backup_test.sh`: hermetic test of the failure-path guarantees (stubbed
  `pg_dump`, `psql`, `mc`, `curl`); CI runs it and `shellcheck` before building.

## [0.1.0] - 2026-07-18

First public release.

### Added
- Logical `pg_dump` of one or more databases, gzipped and **streamed** directly
  to any S3-compatible store (AWS S3, MinIO, RustFS, Cloudflare R2, Backblaze B2,
  Ceph RGW) — no temp files on disk.
- **Multi-database auto-discovery**: with `DATABASES` empty, every non-template,
  connectable database (except `postgres`) is backed up.
- Day-based retention via `KEEP_DAYS` (older objects pruned each run).
- Optional **gpg AES-256 at-rest encryption** via `PASSPHRASE` (passphrase passed
  by file descriptor, never on the command line); encrypted objects get a `.gpg`
  suffix.
- Optional **Prometheus Pushgateway** metrics (`pg_backup_success`,
  `pg_backup_last_success_timestamp_seconds`, `pg_backup_size_bytes{db}`).
- Multi-arch image (`linux/amd64` + `linux/arm64`), runs as a non-root user.
- Docker Compose (ofelia) and Kubernetes CronJob examples.
- GitHub Actions workflow publishing a clean multi-arch image to GHCR.
- Renovate config tracking the Alpine base digest, the pinned `mc` release, and
  the GitHub Actions.

[Unreleased]: https://github.com/LoneExile/postgres-backup-s3/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/LoneExile/postgres-backup-s3/compare/v0.1.2...v0.1.3
[0.1.0]: https://github.com/LoneExile/postgres-backup-s3/releases/tag/v0.1.0

# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/LoneExile/postgres-backup-s3/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LoneExile/postgres-backup-s3/releases/tag/v0.1.0

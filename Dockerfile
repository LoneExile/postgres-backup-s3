# syntax=docker/dockerfile:1
# postgres-backup-s3 — logical pg_dump backups streamed to any S3-compatible
# store. Multi-arch (linux/amd64 + linux/arm64). Build with `docker buildx`.
FROM alpine:3.21

# postgresql17-client — pg_dump must be >= the server's major version. Bump this
# (e.g. postgresql16-client) if you back up an older server; a newer client can
# always dump an older server, but not vice-versa.
RUN apk add --no-cache postgresql17-client ca-certificates bash coreutils gzip tzdata curl

# MinIO client (mc) for S3 I/O — pinned release, baked at build time (never
# fetched at runtime; a floating fetch inside a backup job risks silent failure).
# TARGETARCH is set by buildx (amd64 / arm64) and matches MinIO's release paths.
ARG TARGETARCH
ADD https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.RELEASE.2025-08-13T08-35-41Z /usr/local/bin/mc
RUN chmod +x /usr/local/bin/mc && adduser -D -u 10001 backup

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

USER backup
ENTRYPOINT ["/usr/local/bin/backup.sh"]

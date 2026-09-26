# syntax=docker/dockerfile:1
# postgres-backup-s3 — logical pg_dump backups streamed to any S3-compatible
# store. Multi-arch (linux/amd64 + linux/arm64). Build with `docker buildx`.
# Digest pins the multi-arch index (Renovate/Dependabot keep it current).
# postgresql18-client only exists in alpine 3.23+ (3.21/3.22 lack it); the
# pg_dump major must be >= the server's major. A newer client can always dump
# an older server, but not vice-versa (harbor-db is PG18, the rest PG17).
FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
RUN apk add --no-cache postgresql18-client ca-certificates bash coreutils gzip tzdata curl gnupg

# MinIO client (mc) for S3 I/O — pinned release, baked at build time (never
# fetched at runtime; a floating fetch inside a backup job risks silent failure).
# Fetched from the minio/mc GitHub release assets: dl.min.io returns 410 Gone
# since MinIO archived mc. TARGETARCH is set by buildx (amd64 / arm64) and
# matches the asset names. The per-arch sha256 values are hard-coded (checked
# against the release's published .sha256sum assets) and verified here, so
# bump them together with the release.
ARG TARGETARCH
ADD https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-${TARGETARCH}.RELEASE.2025-08-13T08-35-41Z /usr/local/bin/mc
RUN case "$TARGETARCH" in \
      amd64) sum=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891 ;; \
      arm64) sum=14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c ;; \
      *) echo "no pinned mc sha256 for TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac \
 && echo "$sum  /usr/local/bin/mc" | sha256sum -c - \
 && chmod +x /usr/local/bin/mc && adduser -D -u 10001 backup

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

USER backup
ENTRYPOINT ["/usr/local/bin/backup.sh"]

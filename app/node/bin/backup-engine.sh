#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CLOUDDB_NODE_ENV:-$APP_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

BACKUP_DIR="${BACKUP_DIR:-$APP_ROOT/storage/backups}"
MYSQL_CNF="${BACKUP_DB_CNF:-$APP_ROOT/storage/backup-mysql.cnf}"
LOG_FILE="${BACKUP_LOG:-$APP_ROOT/storage/backup.log}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
SYNC_TARGET="${BACKUP_SYNC_TARGET:-remote:backup}"
BACKUP_KEY_VALUE="${BACKUP_KEY:-}"
STAMP="${BACKUP_STAMP:-$(date +%F-%H%M%S)}"
OUT_FILE="${BACKUP_FILE:-$BACKUP_DIR/auto-$STAMP.sql.gz.enc}"

umask 077
mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump || true)"
touch "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

if [[ -z "$DUMP_BIN" ]]; then
  echo "[$(date -Is)] CloudDB backup failed: no dump binary found"
  exit 1
fi
if [[ ! -r "$MYSQL_CNF" ]]; then
  echo "[$(date -Is)] CloudDB backup failed: MySQL credential file is not readable"
  exit 1
fi
if [[ -z "$BACKUP_KEY_VALUE" ]]; then
  echo "[$(date -Is)] CloudDB backup failed: BACKUP_KEY is not configured"
  exit 1
fi

echo "[$(date -Is)] CloudDB backup started -> $OUT_FILE"
if [[ "$#" -gt 0 ]]; then
  "$DUMP_BIN" --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --events --databases "$@" | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_KEY_VALUE" -out "$OUT_FILE"
else
  "$DUMP_BIN" --defaults-extra-file="$MYSQL_CNF" --all-databases --single-transaction --quick --routines --events | gzip | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_KEY_VALUE" -out "$OUT_FILE"
fi

if [[ -n "$SYNC_TARGET" ]] && [[ -f /root/.rclone.conf ]] && command -v rclone >/dev/null 2>&1; then
  rclone sync "$BACKUP_DIR" "$SYNC_TARGET" --config /root/.rclone.conf || true
fi

find "$BACKUP_DIR" -type f -name '*.enc' -mtime +"$RETENTION_DAYS" -delete
echo "[$(date -Is)] CloudDB backup finished -> $OUT_FILE"

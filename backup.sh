#!/usr/bin/env bash
# db-backuper — stack-agnostic database backups to any rclone remote.
# https://github.com/patrin/db-backuper
#
# Usage: db-backup [-c /path/to/backup.conf] [predeploy]
#   (default)  — hourly run: dump goes to <remote>/hourly/; the first successful
#                run of the day is also copied to <remote>/daily/
#   predeploy  — dump suffixed "-predeploy" goes to <remote>/predeploy/;
#                call it from your deploy chain and abort the deploy on non-zero exit
#
# Exit codes: 0 — success (or an hourly run skipped because another run holds
# the lock); 1 — any dump/verify/upload failure. Rotation errors never affect
# the exit code: the backup is already safe by then.
set -euo pipefail

CONFIG="/etc/db-backuper/backup.conf"
MODE="hourly"

usage() {
    echo "Usage: $0 [-c /path/to/backup.conf] [predeploy]" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c)
            if [[ -z "${2:-}" ]]; then usage; fi
            CONFIG="$2"
            shift 2
            ;;
        predeploy)
            MODE="predeploy"
            shift
            ;;
        *)
            usage
            ;;
    esac
done

LOG_FILE=""    # empty until the config provides LOCAL_DIR; log() prints to stdout only

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
    echo "$msg"
}

# Telegram may be unreachable directly (blocked networks) — try the configured
# proxy, then the fallback proxy, then a direct connection.
send_telegram_alert() {
    local text="$1"
    local proxies=()
    if [[ -n "${TG_HTTP_PROXY:-}" ]]; then proxies+=("$TG_HTTP_PROXY"); fi
    if [[ -n "${TG_HTTP_PROXY_FALLBACK:-}" ]]; then proxies+=("$TG_HTTP_PROXY_FALLBACK"); fi
    proxies+=("")
    local proxy
    for proxy in "${proxies[@]}"; do
        local curl_args=(-fsS -m 10)
        if [[ -n "$proxy" ]]; then curl_args+=(-x "$proxy"); fi
        if curl "${curl_args[@]}" "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            --data-urlencode text="$text" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

fail() {
    log "ERROR: $*"
    if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
        send_telegram_alert "${BACKUP_NAME:-db-backuper}: backup failed (${MODE}): $*" \
            || log "Telegram alert not delivered"
    fi
    exit 1
}

# From here on any unhandled failure (including a syntax error inside the
# sourced config) logs and alerts instead of dying silently.
trap 'fail "unexpected error (line $LINENO)"' ERR

if [[ ! -f "$CONFIG" ]]; then
    fail "config not found: $CONFIG"
fi
# shellcheck source=/dev/null
source "$CONFIG"

RETENTION_HOURLY="${RETENTION_HOURLY:-48h}"
RETENTION_DAILY="${RETENTION_DAILY:-30d}"
RETENTION_PREDEPLOY="${RETENTION_PREDEPLOY:-90d}"
LOCAL_RETENTION_MIN="${LOCAL_RETENTION_MIN:-2880}"
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-102400}"

missing=""
for var in BACKUP_NAME DB_ENGINE DB_VIA RCLONE_REMOTE LOCAL_DIR; do
    if [[ -z "${!var:-}" ]]; then missing="$missing $var"; fi
done
case "${DB_VIA:-}" in
    docker)
        for var in DB_COMPOSE_FILE DB_COMPOSE_SERVICE; do
            if [[ -z "${!var:-}" ]]; then missing="$missing $var"; fi
        done
        ;;
    direct)
        for var in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
            if [[ -z "${!var:-}" ]]; then missing="$missing $var"; fi
        done
        ;;
    *)
        fail "DB_VIA must be docker or direct (got: '${DB_VIA:-}')"
        ;;
esac
if [[ "$DB_ENGINE" != "postgres" && "$DB_ENGINE" != "mysql" ]]; then
    fail "DB_ENGINE must be postgres or mysql (got: '$DB_ENGINE')"
fi
if [[ -n "$missing" ]]; then
    fail "config incomplete, missing:$missing"
fi

mkdir -p "$LOCAL_DIR"
LOG_FILE="$LOCAL_DIR/backup.log"

# Cron ships a minimal PATH — search the usual locations explicitly.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
required_bins=(rclone flock gzip)
if [[ "$DB_VIA" == "docker" ]]; then
    required_bins+=(docker)
elif [[ "$DB_ENGINE" == "postgres" ]]; then
    required_bins+=(pg_dump)
else
    required_bins+=(mysqldump)
fi
for bin in "${required_bins[@]}"; do
    command -v "$bin" >/dev/null || fail "required binary not found: $bin"
done

# Guard against overlapping runs (hourly cron vs a long predeploy dump).
exec 9>"$LOCAL_DIR/.backup.lock"
if [[ "$MODE" == "predeploy" ]]; then
    flock -w 600 9 || fail "could not acquire lock within 600s (another backup is stuck?)"
elif ! flock -n 9; then
    log "Skipped: another backup is still running"
    exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ "$MODE" == "predeploy" ]]; then
    DUMP_FILE="$LOCAL_DIR/$BACKUP_NAME-$STAMP-predeploy.sql.gz"
    REMOTE_DIR="$RCLONE_REMOTE/predeploy"
else
    DUMP_FILE="$LOCAL_DIR/$BACKUP_NAME-$STAMP.sql.gz"
    REMOTE_DIR="$RCLONE_REMOTE/hourly"
fi

dump_database() {
    case "$DB_ENGINE/$DB_VIA" in
        postgres/docker)
            docker compose -f "$DB_COMPOSE_FILE" exec -T "$DB_COMPOSE_SERVICE" \
                sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
            ;;
        mysql/docker)
            docker compose -f "$DB_COMPOSE_FILE" exec -T "$DB_COMPOSE_SERVICE" \
                sh -c 'mysqldump --single-transaction -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'
            ;;
        postgres/direct)
            PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
            ;;
        mysql/direct)
            MYSQL_PWD="$DB_PASSWORD" mysqldump --single-transaction -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME"
            ;;
    esac
}

log "Start ($MODE): $DUMP_FILE"

if ! dump_database | gzip > "$DUMP_FILE"; then
    rm -f "$DUMP_FILE"
    fail "database dump failed"
fi

gzip -t "$DUMP_FILE" || fail "dump is corrupted (gzip -t)"

DUMP_SIZE=$(wc -c < "$DUMP_FILE")
if (( DUMP_SIZE < MIN_SIZE_BYTES )); then
    fail "dump is suspiciously small: $DUMP_SIZE bytes (threshold $MIN_SIZE_BYTES)"
fi

rclone copyto "$DUMP_FILE" "$REMOTE_DIR/$(basename "$DUMP_FILE")" \
    || fail "upload to $REMOTE_DIR failed"
log "Uploaded: $REMOTE_DIR/$(basename "$DUMP_FILE") ($DUMP_SIZE bytes)"

# Daily tier: the first successful hourly dump of the day is copied to daily/.
if [[ "$MODE" == "hourly" ]]; then
    TODAY="$(date +%Y%m%d)"
    if ! rclone lsf "$RCLONE_REMOTE/daily" 2>/dev/null | grep -q "$BACKUP_NAME-$TODAY"; then
        if rclone copyto "$DUMP_FILE" "$RCLONE_REMOTE/daily/$(basename "$DUMP_FILE")"; then
            log "Uploaded daily tier: $RCLONE_REMOTE/daily/$(basename "$DUMP_FILE")"
        else
            log "ERROR (non-fatal): daily tier upload failed"
        fi
    fi
fi

# Rotation — only after a successful upload; failures are logged but never
# affect the exit code. rclone exits 3 when the tier directory does not exist
# yet (e.g. no predeploy dump was ever made) — nothing to rotate, not an error.
rotate_tier() {
    local tier="$1" retention="$2" rc=0
    rclone delete --min-age "$retention" "$RCLONE_REMOTE/$tier" 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
        log "$tier rotation failed"
    fi
}
rotate_tier hourly "$RETENTION_HOURLY"
rotate_tier daily "$RETENTION_DAILY"
rotate_tier predeploy "$RETENTION_PREDEPLOY"
find "$LOCAL_DIR" -name "$BACKUP_NAME-*.sql.gz" -mmin +"$LOCAL_RETENTION_MIN" -delete || log "local rotation failed"

log "Done ($MODE)"

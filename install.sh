#!/usr/bin/env bash
# db-backuper installer/updater. Run as root:
#   curl -fsSL https://raw.githubusercontent.com/patrin/db-backuper/main/install.sh | bash
# Re-running is safe: updates the script, keeps the config, rewrites cron.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/patrin/db-backuper/main"
BIN_PATH="/usr/local/bin/db-backup"
CONF_DIR="/etc/db-backuper"
CONF_PATH="$CONF_DIR/backup.conf"

if [[ "$(id -u)" != "0" ]]; then
    echo "Run as root: needs $BIN_PATH and /etc/cron.d." >&2
    exit 1
fi

# 1. rclone
if ! command -v rclone >/dev/null; then
    echo "rclone not found — installing via rclone.org/install.sh ..."
    curl -fsSL https://rclone.org/install.sh | bash
fi

# 2. backup.sh -> /usr/local/bin/db-backup (local copy when run from a clone,
#    otherwise fetched from GitHub)
SRC_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "$(dirname "${BASH_SOURCE[0]}")/backup.sh" ]]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -n "$SRC_DIR" ]]; then
    install -m 755 "$SRC_DIR/backup.sh" "$BIN_PATH"
else
    curl -fsSL "$REPO_RAW/backup.sh" -o "$BIN_PATH"
    chmod 755 "$BIN_PATH"
fi
echo "Installed: $BIN_PATH"

# 3. config from template (never overwrite an existing one)
mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF_PATH" ]]; then
    if [[ -n "$SRC_DIR" && -f "$SRC_DIR/backup.conf.example" ]]; then
        install -m 600 "$SRC_DIR/backup.conf.example" "$CONF_PATH"
    else
        curl -fsSL "$REPO_RAW/backup.conf.example" -o "$CONF_PATH"
        chmod 600 "$CONF_PATH"
    fi
    echo "Created $CONF_PATH from the template."
    echo "Edit it (database, rclone remote, schedule), then re-run this installer to set up cron."
    exit 0
fi

# 4. cron — only when the config has the essentials
# shellcheck source=/dev/null
source "$CONF_PATH"
if [[ -z "${BACKUP_NAME:-}" || -z "${SCHEDULE:-}" || -z "${LOCAL_DIR:-}" ]]; then
    echo "Config $CONF_PATH lacks BACKUP_NAME/SCHEDULE/LOCAL_DIR — edit it and re-run." >&2
    exit 1
fi
CRON_FILE="/etc/cron.d/db-backuper-$BACKUP_NAME"
{
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "$SCHEDULE root $BIN_PATH -c $CONF_PATH >/dev/null 2>>$LOCAL_DIR/backup.log"
    if [[ -n "${FILES_DIRS:-}" ]]; then
        echo "${FILES_SCHEDULE:-30 3 * * *} root $BIN_PATH -c $CONF_PATH files >/dev/null 2>>$LOCAL_DIR/backup.log"
    fi
} > "$CRON_FILE"
chmod 644 "$CRON_FILE"
echo "Cron installed: $CRON_FILE ($SCHEDULE)"
if [[ -n "${FILES_DIRS:-}" ]]; then
    echo "Files backup cron: ${FILES_SCHEDULE:-30 3 * * *}"
fi

cat <<'EOF'

Next steps:
  1. Configure the rclone remote used in RCLONE_REMOTE (for a headless server:
     run `rclone authorize "yandex"` on your desktop, then
     `rclone config create <name> yandex token '<paste>'` on the server).
  2. Test run: db-backup -c /etc/db-backuper/backup.conf
  3. Pre-deploy hook: add `db-backup -c /etc/db-backuper/backup.conf predeploy`
     as the FIRST command of your deploy chain — non-zero exit aborts the deploy.
EOF

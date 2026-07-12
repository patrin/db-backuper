# db-backuper

Stack-agnostic database backups to any [rclone](https://rclone.org) remote
(Yandex Disk, S3, Google Drive, …). One bash script, one config file, cron.

**Features**

- PostgreSQL and MySQL/MariaDB; dump via `docker compose exec` or a direct connection
- Tiered retention: `hourly/` (48h), `daily/` (30d), `predeploy/` (90d) — all configurable
- Pre-deploy mode for "no backup — no deploy" pipelines (non-zero exit aborts your deploy)
- File backups: mirror project directories with `rclone sync`; deleted/overwritten files are kept in a trash tier (90 days by default)
- Rotation runs only after a successful upload; never affects the exit code
- Dump sanity checks (`gzip -t` + size threshold), `flock` guard against overlapping runs
- Optional Telegram alerts on failure, with HTTP-proxy fallback chain

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/patrin/db-backuper/main/install.sh | sudo bash
sudo nano /etc/db-backuper/backup.conf     # fill in your project
curl -fsSL https://raw.githubusercontent.com/patrin/db-backuper/main/install.sh | sudo bash   # re-run: installs cron
```

Re-running the installer updates the script and rewrites cron; the config is never overwritten.

## Configure

See [backup.conf.example](backup.conf.example) — every variable is documented there.
The essentials:

| Variable | Meaning |
|---|---|
| `BACKUP_NAME` | Dump filename prefix and cron file name |
| `DB_ENGINE` / `DB_VIA` | `postgres`\|`mysql` / `docker`\|`direct` |
| `RCLONE_REMOTE` | e.g. `yadisk:backups/myproject` |
| `LOCAL_DIR` | local folder for dumps, log and lock |
| `SCHEDULE` | cron expression, default `0 * * * *` |

### rclone remote on a headless server (Yandex Disk example)

```bash
# on your desktop (opens a browser):
rclone authorize "yandex"
# on the server, paste the printed token:
rclone config create yadisk yandex token '<TOKEN_JSON>'
```

## Pre-deploy backup

Make the backup the first command of your deploy chain:

```make
deploy:
	db-backup -c /etc/db-backuper/backup.conf predeploy
	git pull --ff-only
	...
```

If the dump or upload fails, `db-backup` exits 1 and the deploy stops.

## File backups

Mirror project directories (uploads, covers, attachments) to the same remote:

```bash
# in backup.conf:
FILES_DIRS="/opt/myproject/storage/uploads"
# re-run the installer to add a daily cron line, or test by hand:
db-backup -c /etc/db-backuper/backup.conf files
```

Each directory is synced to `<remote>/files/<basename>/` — an exact mirror,
uploading only changes. Accidental deletions are recoverable: deleted and
overwritten files move to `<remote>/files-trash/<timestamp>/…` and are kept
for `RETENTION_TRASH` (90 days by default).

Restore by copying back from `files/` (current version) or
`files-trash/<timestamp>/` (deleted/previous versions).

## Multiple projects on one server

One config per project + one installer-written cron each:

```bash
sudo cp /etc/db-backuper/backup.conf /etc/db-backuper/other.conf   # edit it
sudo db-backup -c /etc/db-backuper/other.conf                      # test run
```

(Write the second cron file yourself or re-run the installer pointing `CONF_PATH`.)

## Restore

Dumps are plain `pg_dump`/`mysqldump` output, gzipped:

```bash
zcat myproject-20260706-120000.sql.gz | psql -U user dbname      # postgres
zcat myproject-20260706-120000.sql.gz | mysql -u user dbname     # mysql
```

## Uninstall

```bash
sudo rm /usr/local/bin/db-backup /etc/cron.d/db-backuper-* && sudo rm -r /etc/db-backuper
```

## License

MIT

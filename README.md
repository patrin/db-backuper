# db-backuper

Stack-agnostic database backups to any [rclone](https://rclone.org) remote
(Yandex Disk, S3, Google Drive, …). One bash script, one config file, cron.

**Features**

- PostgreSQL and MySQL/MariaDB; dump via `docker compose exec` or a direct connection
- Tiered retention: `hourly/` (48h), `daily/` (30d), `predeploy/` (90d) — all configurable
- Pre-deploy mode for "no backup — no deploy" pipelines (non-zero exit aborts your deploy)
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

---
extends: _core._layouts.documentation
section: content
title: Backup
description: Backup
---

# backup commands

Run with `sudo /root/simai-env/simai-admin.sh backup <command> [options]` or via menu.

These commands work with config-only archives:
- no secrets
- no SSL private keys
- no project `.env`

They are intended for safe site configuration export/import. For the site
database and files use the `data` commands below.

## data
Back up one site's database (`mysqldump --single-transaction`), project files
and managed config into `/var/backups/simai/<domain>/<timestamp>/`
(root-only, `SHA256SUMS` included). Caches, logs, `node_modules` and Bitrix
`bitrix/backup` are excluded. Older backups beyond `--keep` are removed.

```bash
sudo /root/simai-env/simai-admin.sh backup data --domain example.com
sudo /root/simai-env/simai-admin.sh backup data --domain example.com --keep 14 \
  --offsite backup@storage.example.net:/srv/backups --encrypt-to age1...
```

Options:
- `--dest` (default `/var/backups/simai`, never inside the web root)
- `--keep` 1–365 (default 7)
- `--db yes|no`, `--files yes|no`
- `--offsite user@host:/path` copies the domain directory with rsync over SSH
  (key-based, host key must already be in `/root/.ssh/known_hosts`). The
  default can be set as `SIMAI_BACKUP_OFFSITE` in `/etc/simai-env.conf`.
- `--encrypt-to age1...` encrypts every artifact with `age` before checksums
  and off-site copy (`apt-get install age`; keep the private key off the
  server). Default: `SIMAI_BACKUP_AGE_RECIPIENT`.

A failed dump, archive or encryption removes the partial backup and exits
non-zero. A failed off-site copy keeps the local backup and exits non-zero.

## data-verify
```bash
sudo /root/simai-env/simai-admin.sh backup data-verify --path /var/backups/simai/example.com/20260921-033000 --restore-test yes
```
Checks checksums and archive integrity. `--restore-test yes` imports the dump
into a temporary database and drops it afterwards. Run it regularly: an
untested backup is not a backup.

## data-schedule
```bash
sudo /root/simai-env/simai-admin.sh backup data-schedule --domain example.com --time 03:30 --keep 7
sudo /root/simai-env/simai-admin.sh backup data-schedule --domain example.com --enabled no
```
Writes `/etc/cron.d/simai-backup-<slug>`; output goes to
`/var/log/simai-backup.log`.

## data-restore
```bash
sudo /root/simai-env/simai-admin.sh backup data-restore --domain example.com --path <backup-dir>
sudo /root/simai-env/simai-admin.sh backup data-restore --domain example.com --path <backup-dir> --confirm yes
```
Without `--confirm yes` it only prints the plan. With it, the backup is
verified, the current database is dumped next to the backups
(`pre-restore-<timestamp>.sql.gz`), and the dump is imported. Files are
extracted to `<project>.restore-<timestamp>` for review; swap directories
yourself during a maintenance window. Encrypted backups must be decrypted
with `age -d` first.

## export
Export one site's managed config into a tar.gz archive.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh backup export --domain example.com
sudo /root/simai-env/simai-admin.sh backup export --domain example.com --out /root/simai-backups/example.tar.gz
```

What is included:
- nginx config
- PHP-FPM pool config (if the site has PHP)
- managed `cron.d` file (when applicable)
- managed queue unit (when applicable)
- `manifest.json`
- `NOTES.txt`

## inspect
Inspect an archive without changing the server.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh backup inspect --file example.tar.gz
```

What it does:
- prints manifest details
- verifies file checksums inside the archive
- does not change system state
- rejects unsafe tar entries such as absolute paths, traversal, symlinks,
  hardlinks, devices, and unexpected top-level directories
- rejects platform pre-update archives such as `simai-env-preupdate-*.tar.gz`, because they are not site settings bundles and do not contain `manifest.json`

## import
Import a config archive.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh backup import --file example.tar.gz --apply no
sudo /root/simai-env/simai-admin.sh backup import --file example.tar.gz --apply yes --enable yes --reload yes
```

Options:
- `--file` (required)
- `--apply yes|no` (default `no`)
- `--enable yes|no`
- `--reload yes|no`

Behavior:
- default is plan-only (`--apply no`)
- the plan checks profile compatibility on the current server
- `--apply yes` writes files with timestamped `.bak` backups of replaced files
- apply is blocked if the profile in the archive is missing or disabled locally
- `--enable yes` creates the nginx `sites-enabled` symlink
- `--reload yes` runs validation/reload for nginx and php-fpm; if that fails, managed files are rolled back

Import rules:
- cron is restored only for matching managed simai cron files
- queue unit is restored only for profiles that support queue workers and only
  when the unit name matches `laravel-queue-<slug>.service`
- archive extraction is allowlisted to config-bundle paths and rejects
  symlinks, hardlinks, devices, absolute paths, and path traversal
- SSL keys and project `.env` are never imported from this archive type

## Notes
- Use `backup inspect` before `backup import --apply yes`.
- This flow is designed for safe config migration, not for full-content site restoration.
- In the menu, `Review archive` and `Preview import` now show only compatible site settings archives by default; platform pre-update backups are excluded from the chooser.

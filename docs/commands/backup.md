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
(root-only, `SHA256SUMS` included). Caches, logs, `node_modules`, Bitrix
`bitrix/backup` and `<site root>/restore-archive/` (the already compressed
backup that `bitrix finalize` moves out of the docroot after a restore) are
excluded. Older backups beyond `--keep` are removed.

The heavy work (database dump and its compression, file archiving,
encryption, checksums, and the checks of `data-verify`) runs at low priority:
`nice -n 10` and, when `ionice` (util-linux) is available, the idle I/O class
`ionice -c3`. This applies to manual, scheduled and panel backups alike, so
sites and the panel stay responsive on small servers. Set
`SIMAI_BACKUP_NICE=0..19` in `/etc/simai-env.conf` to change the CPU niceness
(`0` keeps normal CPU priority). The database server's own work is not
reniced, and `data-restore` imports run at normal priority.

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

- `--storage NAME|none` uploads to that backup storage instead of the
  default one, or not at all (see `storage-add`).

A failed dump, archive or encryption removes the partial backup and exits
non-zero. A failed off-site copy keeps the local backup and exits non-zero.
A failed upload to a backup storage keeps the local backup, exits zero,
records the result and opens a `backup_offsite_failed` alert.

## Backup storages (S3)

Data backups can be uploaded to S3 or any S3-compatible object storage
(AWS S3, Yandex Object Storage, Selectel, VK Cloud, Cloudflare R2, Backblaze
B2, MinIO). After every successful `backup data` (manual or scheduled) the
backup directory is uploaded to the default storage as
`<bucket>/<prefix>/<domain>/<timestamp>/`, and the storage keeps the newest
`--keep` backups of each site; local retention is separate. Transfers use
`rclone` (installed on first use) configured through the environment only,
so the keys never appear in process arguments. Use `--encrypt-to` on the
backup when the storage must not see the data.

```bash
sudo /root/simai-env/simai-admin.sh backup storage-add --name s3 --bucket my-backups \
  --endpoint https://storage.yandexcloud.net --region ru-central1 --prefix web1 \
  --access-key-file /root/ak --secret-key-file /root/sk --keep 30 --confirm yes
sudo /root/simai-env/simai-admin.sh backup storage-list
sudo /root/simai-env/simai-admin.sh backup storage-test --name s3 --confirm yes
sudo /root/simai-env/simai-admin.sh backup storage-copies --name s3 --domain example.com
sudo /root/simai-env/simai-admin.sh backup storage-fetch --name s3 --domain example.com --backup 20261106-033000 --confirm yes
sudo /root/simai-env/simai-admin.sh backup data-restore --domain example.com --backup 20261106-033000 --confirm yes
sudo /root/simai-env/simai-admin.sh backup storage-remove --name s3 --confirm yes
```

- `storage-add`: `--endpoint` empty means AWS; `--prefix` keeps several
  servers apart in one bucket; `--keep` 1-365 (default 30); `--default
  yes|no` (the first storage becomes the default). The keys are read from
  files (one line each) and checked by writing, reading and deleting a small
  object before anything is saved; a refused key or bucket saves nothing.
  Settings live in `/etc/simai-env/backup-storages/<name>.env` (root,
  0600). Replacing a storage keeps the old settings if the new ones fail.
- `storage-list` (`simai-backup-storages/1`): `storages [{name, type,
  bucket, endpoint, region, prefix, keep, default, access_key_hint,
  last_test {at, ok, error}}]`; never the keys.
- `storage-test`: the same write check; the result shows in `storage-list`.
- `storage-copies` (`simai-backup-copies/1`): `copies [{domain, backup,
  created_at}]`, newest first; without `--domain` every site in the storage.
- `storage-fetch`: downloads a copy into `/var/backups/simai/<domain>/<backup>`
  (or `--dest`), checks `SHA256SUMS` and keeps it only when they match; then
  `data-verify` and `data-restore` work as with a local backup. On a new
  server: install simai-env, add the site and the same storage, fetch, restore.
- `storage-remove`: removes the settings and keys; copies stay in the bucket.

The result of the last upload of each site is kept in
`/var/lib/simai-env/backup-offsite/<domain>.json` and shows as
`last_offsite {at, ok, storage, backup, error}` in `site describe` (and in
its `backups`).

## data-verify
```bash
sudo /root/simai-env/simai-admin.sh backup data-verify --path /var/backups/simai/example.com/20260921-033000 --restore-test yes
```
Checks checksums and archive integrity; `--domain D --backup NAME|latest`
finds the backup by name. `--restore-test yes` imports the dump
into a temporary database and drops it afterwards. Run it regularly: an
untested backup is not a backup.

## data-schedule
```bash
sudo /root/simai-env/simai-admin.sh backup data-schedule --domain example.com --time 03:30 --keep 7
sudo /root/simai-env/simai-admin.sh backup data-schedule --domain example.com --enabled no
```
Writes `/etc/cron.d/simai-backup-<slug>`; output goes to
`/var/log/simai-backup.log`. `--verify yes` checks the newest copy after each
successful scheduled backup (`data-verify --backup latest --restore-test
auto`: with a restore test when the copy has a plain dump). The result of a
check by name is kept in `/var/lib/simai-env/backup-verify/<domain>.json` and
shows as `last_verify {at, ok, backup, restore_test}` in `self describe` and
`site describe`. New sites get a schedule by default (`site add --backup`).

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

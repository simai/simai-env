# backup commands

Run with `sudo /root/simai-env/simai-admin.sh backup <command> [options]` or via menu.

These commands work with config-only archives:
- no secrets
- no SSL private keys
- no project `.env`

They are intended for safe site configuration export/import, not for full application backups.

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
- queue unit is restored only for profiles that support queue workers
- SSL keys and project `.env` are never imported from this archive type

## Notes
- Use `backup inspect` before `backup import --apply yes`.
- This flow is designed for safe config migration, not for full-content site restoration.
- In the menu, `Review archive` and `Preview import` now show only compatible site settings archives by default; platform pre-update backups are excluded from the chooser.

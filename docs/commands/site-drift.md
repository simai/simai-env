# site drift

Check metadata/cron drift and optionally apply safe fixes.

Usage:
- Plan: `simai-admin.sh site drift --domain <domain>`
- Apply safe fixes: `simai-admin.sh site drift --domain <domain> --fix yes`

What it checks:
- Nginx metadata header (`# simai-*`) presence/version.
- Cron location drift: `/etc/cron.d/<slug>` vs legacy crontab blocks (simai-managed only).

Fix behavior (`--fix yes`):
- Migrates simai-managed legacy cron blocks to `/etc/cron.d/<slug>` only when safe BEGIN/END markers are present; removes just that block.
- Leaves any unmarked/potential legacy cron lines untouched and warns for manual cleanup.
- Does not auto-fix metadata/DB/files/SSL; skips uncertain cases with WARN.

# cron commands

Run with `sudo /root/simai-env/simai-admin.sh cron <command> [options]` or via menu.

Scheduler entries are written to `/etc/cron.d/<slug>` using site metadata (`simai-slug` in nginx config). `cron` service must be installed and running (`systemctl enable --now cron`).

## add
Create/refresh the Laravel scheduler entry for an existing site (laravel profile only).
- `--domain <fqdn>` (required)
- `--user` (optional, default `simai`)

Behavior:
- Reads nginx site metadata (`# simai-*`); requires slug/profile/root/php to be present.
- Refuses to guess slug/root/php; fix metadata first if missing (site doctor/repair).
- Fails for unsupported profiles (static/generic/alias) or missing metadata.

Example:
`simai-admin.sh cron add --domain example.com`

## remove
Remove the scheduler entry for a site.
- `--domain <fqdn>` (required)

Example:
`simai-admin.sh cron remove --domain example.com`

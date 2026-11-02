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

## list / job-add / job-remove / job-enable / job-disable / job-runs
A site's own cron jobs: any command of the site, on a five-field schedule,
run as the site user (never root) in the site directory (`current/` for
sites with releases).

Usage:
- `simai-admin.sh cron list --domain <domain> [--output json]` (`simai-cron-jobs/1`)
- `simai-admin.sh cron job-add --domain <domain> --schedule '*/5 * * * *' --command 'php artisan app:sync' --confirm yes`
- `simai-admin.sh cron job-remove|job-enable|job-disable --id <id> --confirm yes`
- `simai-admin.sh cron job-runs --id <id> [--limit 20] [--output json]` (`simai-cron-runs/1`)

Behavior:
- The schedule is five fields (minute, hour, day, month, weekday) with
  numbers, ranges, lists and steps; `@daily` and the like are refused.
- The command is one line of printable text (up to 1000 characters) run by
  bash. It is kept root-only in `/etc/simai-env/cron-jobs/<domain>/` and
  never written into the cron line, so `%` and quotes need no escaping.
- `/etc/cron.d/simai-jobs-<slug>` calls `/usr/local/lib/simai-env/cron-job-run`,
  which records each run (start, end, exit code, last 50 output lines; the
  last 50 runs) in `/var/lib/simai-env/cron-runs/<domain>/`. A run that is
  still going when the next one is due makes the next one skip.
- A site has at most 50 jobs. `site remove` takes the jobs and their
  records along; `site isolate` moves them to the new user.
- This is separate from `cron add` (the Laravel scheduler entry).

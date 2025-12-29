# cron commands

Run with `sudo /root/simai-env/simai-admin.sh cron <command> [options]` or via menu.

Scheduler entries are written to `/etc/cron.d/<project>` and require the `cron` service to be installed and running (`systemctl enable --now cron`).

## add
Create/refresh the Laravel scheduler entry.
- `--project-path` (required)
- `--php` (optional, default `8.2`)
- `--user` (optional, default `simai`)
- `--project-name` (optional; defaults to basename of project-path)

Example:
`simai-admin.sh cron add --project-path /home/simai/www/app --php 8.3`

## remove
Remove the scheduler entry.
- Either `--project-name <name>` or `--project-path <path>` (from which the name is derived)
- `--user` is accepted but not needed for removal.

Examples:
- By name: `simai-admin.sh cron remove --project-name app`
- By path: `simai-admin.sh cron remove --project-path /home/simai/www/app`

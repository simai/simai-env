# Site cron management

Simai-managed site cron uses `/etc/cron.d/<slug>` as the single supported location.

Cron.d header (required):
- `# simai-managed: yes`
- `# simai-domain: <domain>`
- `# simai-slug: <slug>`
- `# simai-profile: <profile>`

Guidelines:
- Each cron line must include an explicit user (usually `simai`), e.g. `* * * * * simai cd /home/simai/www/example.com && php artisan schedule:run >> /dev/null 2>&1`.
- Static/alias profiles typically do not create cron; Laravel scheduler cron lives here when enabled.
- Legacy crontab-based entries should be migrated to cron.d; only simai-managed blocks are touched during migration.
- Source of truth for `<slug>` is the site metadata (`# simai-slug` in nginx config); tooling uses it to locate `/etc/cron.d/<slug>`.

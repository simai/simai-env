# Site cron management

Use this document when you need the supported cron location and header contract for simai-managed sites.

Why it matters:

- cron entries are part of managed site state,
- drift and migration logic depends on these conventions,
- Laravel and product-specific scheduler flows rely on the same slug-based location.

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

Related docs:

- [commands/cron.md](../commands/cron.md)
- [commands/site-drift.md](../commands/site-drift.md)
- [architecture/site-metadata.md](./site-metadata.md)

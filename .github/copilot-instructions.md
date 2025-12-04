# simai-env Copilot Instructions

## Project scope
- Ubuntu-only installer and admin CLI for PHP sites (generic by default, Laravel optional, alias profile for extra domains).
- Supported OS: Ubuntu 20.04/22.04/24.04 only.
- Default user: `simai`; projects live under `/home/simai/www/<project>/`.
- Services: nginx, PHP-FPM (8.1/8.2/8.3 via `ppa:ondrej/php`), MySQL/Percona, Redis, Node.js, Composer.

## Key scripts
- `simai-env.sh`: main installer (install/clean), creates stack, project, env, nginx/PHP-FPM, cron, queue.
- `simai-admin.sh`: admin CLI with registry/menu in `admin/`; commands for site/nginx/php-fpm/ssl/db (some stubs).
- `install.sh` / `update.sh`: fetch/copy repo to `/root/simai-env` and mark scripts executable.

## Admin CLI behaviors
- Menu runs with numeric selections; stays inside section after commands.
- `site add`:
  - Profiles: `generic` (root `/home/.../public`, placeholder page), `laravel` (requires `artisan`), `alias` (points domain to existing site and reuses its PHP-FPM pool/root).
  - Auto project slug from domain if `--project-name` missing.
  - Select PHP version from installed `/etc/php/*` when not provided.
  - Optional DB creation (`create-db=yes`); defaults `db-name`/`db-user` from project slug, generates password; writes `.env` for generic profile; shows summary with credentials (not logged).
  - Copies `templates/healthcheck.php` to `public/healthcheck.php` (non-alias).
- `site remove`: choose domain from list if missing; yes/no prompts for removing files/DB/user; removes nginx/site configs, php-fpm pools, optional files/db/user; stays in menu on errors (alias removal only drops nginx).
- `site list`: prints table with domain, profile, PHP version, root/alias target (uses metadata comments in nginx configs).
- `site set-php`: choose site/PHP version (stubbed for now).
- `php list`/`php reload`: list installed PHP versions, reload FPM; menu selection when needed.
- `ssl` commands: select domain from existing sites when not provided (handlers are stubs).
- Menu uses `select_from_list` for choices; prints separators before/after commands; respects `SIMAI_ADMIN_MENU` flag for reload after self-update.

## Templates
- `templates/nginx-laravel.conf`: root `{{PROJECT_ROOT}}/public`, PHP-FPM socket per project (`{{PHP_SOCKET_PROJECT}}` allows aliasing to an existing pool).
- `templates/nginx-generic.conf`: root `{{PROJECT_ROOT}}/public`, same socket placeholder.
- `templates/healthcheck.php`: JSON health check, loads `.env` (simple parser), checks extensions, FS writability, DB connectivity; deployed to `public/healthcheck.php`.
- `systemd/laravel-queue.service`: queue worker template.

## Conventions
- Repository text/files in English; chat/support may be in Russian.
- Avoid non-ASCII in code; keep output concise; log to `/var/log/simai-env.log` or `/var/log/simai-admin.log`.
- Do not remove user changes; do not hardcode destructive commands.

## Pending/known gaps
- Some admin commands are stubs (ssl, db, queue, cron beyond schedule:run, site set-php logic).
- Healthcheck relies on `.env` for DB; generic profile now writes it when DB is created.
- Queue/cron cleanup not fully implemented in site remove.

## Docs
- `docs/admin.md`: admin CLI overview, profiles, menu behavior.
- `docs/commands/site.md`: site add/remove/list/set-php options/behavior.
- `docs/commands/php.md`: php list/reload usage.

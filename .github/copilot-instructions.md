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
- `VERSION`: semantic version marker copied on install/update; bump on user-visible changes (at least patch).

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
- `site set-php`: choose site (aliases filtered out), switch PHP version by recreating pool and nginx upstream; optional `keep-old-pool` flag (default no).
- `php list`/`php reload`: list installed PHP versions, reload FPM; menu selection when needed.
- `ssl` commands: select domain from existing sites when not provided (handlers are stubs).
- Menu uses `select_from_list` for choices; prints separators before/after commands; respects `SIMAI_ADMIN_MENU` flag for reload after self-update.
  - Prompt rule: when a parameter has a finite set of values, always show a numbered list, a title `Select <param>`, and an `Enter choice [<default>]:` line. Accept either a number or an exact value; empty input picks the default. For binary questions use `yes`/`no` (still numbered).
- Table rule: when showing existing entities (sites, SSL certs, PHP versions/pools, cron jobs, queues, DBs/users), render a bordered table (`+---+` separators, header row, closing border) with only the key columns for quick diagnostics. Example columns: sites → domain/profile/PHP/root-or-alias; SSL → domain/status/notBefore/notAfter/issuer; PHP → version/status/pool count; cron → project/schedule/command; queues → project/unit/status; DB → name/owner/host/encoding.
- Color rule: colors only in interactive output. Define ANSI codes as `GREEN=$'\e[32m'`, etc. First pad text to fixed width, then wrap with color to keep table alignment. Use `%s` (not `%b`) when printing colored strings. Do not color logs. If needed, disable colors when stdout is not a TTY (`[[ -t 1 ]]`).

## Templates
- `templates/nginx-laravel.conf`: root `{{PROJECT_ROOT}}/public`, PHP-FPM socket per project (`{{PHP_SOCKET_PROJECT}}` allows aliasing to an existing pool).
- `templates/nginx-generic.conf`: root `{{PROJECT_ROOT}}/public`, same socket placeholder.
- `templates/healthcheck.php`: JSON health check, loads `.env` (simple parser), checks extensions, FS writability, DB connectivity; deployed to `public/healthcheck.php`.
- `systemd/laravel-queue.service`: queue worker template.

## Conventions
- Repository text/files in English; chat/support may be in Russian.
- Avoid non-ASCII in code; keep output concise; log to `/var/log/simai-env.log` or `/var/log/simai-admin.log`.
- Do not remove user changes; do not hardcode destructive commands.

## Security defaults
- Least privilege: run sites as `simai`, separate PHP-FPM pool per project, sockets/logs owned by `simai`:www-data, no root for web/PHP.
- Secrets never logged: show creds once to user, do not write passwords/keys to logs; keep `.env` at 640.
- Nginx safety: always keep catch-all `default_server` returning 444; disable distro default site; do not expose internal endpoints (PHP status/healthcheck) publicly.
- PHP-FPM: per-project sockets, sensible timeouts, no exec-like features in templates.
- DB: one DB user per site, generated password by default; avoid shared root accounts; host `%` only when explicitly needed.
- Input validation: sanitize domains/paths (no `..`, only a-z0-9.-_), reject unexpected values; build shell commands without user interpolation.
- SSL: issue/renew only for domains from configs; do not overwrite unrelated vhosts.
- Cleanup/update: site removal deletes nginx/pools first, files/DB/user only on explicit confirmation; updater may delete deprecated scripts but must not touch user data.

## Pending/known gaps
- Some admin commands are stubs (ssl, db, queue, cron beyond schedule:run, site set-php logic).
- Healthcheck relies on `.env` for DB; generic profile now writes it when DB is created.
- Queue/cron cleanup not fully implemented in site remove.

## Docs
- `docs/admin.md`: admin CLI overview, profiles, menu behavior.
- `docs/commands/site.md`: site add/remove/list/set-php options/behavior.
- `docs/commands/php.md`: php list/reload usage.

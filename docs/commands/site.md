# site commands

Run with `sudo /root/simai-env/simai-admin.sh site <command> [options]` or via menu.

## add
Create nginx vhost and project root for an existing path.

Options:
- `--domain` (required)
- `--project-name` (optional; derived from domain if missing)
 - `--path` (optional; default uses path style under `/home/simai/www/`)
 - `--path-style` (`slug`|`domain`) controls default path when `--path` is not set. Default is `domain` (e.g., `/home/simai/www/example.com`). Use `--path-style slug` to restore legacy slug paths or set `/etc/simai-env.conf` with `SIMAI_DEFAULT_PATH_STYLE=domain|slug`.
- `--profile` (`generic`|`laravel`|`static`|`alias`, default `generic`)
- `--php` (optional; choose from installed if omitted)
- DB (optional): `--create-db=yes|no`, `--db-name`, `--db-user`, `--db-pass` (defaults from project; password generated)

Behavior:
- Generic uses placeholder and `public` root; Laravel requires `artisan`. Static is nginx-only (no PHP/DB) with `public/index.html` placeholder and `/healthcheck` (localhost-only). Alias points the domain to an existing site (reuses its root, no DB/pool creation).
- Creates PHP-FPM pool and nginx vhost for non-static profiles; installs `public/healthcheck.php` (non-alias, non-static).
- If `create-db=yes`, creates DB/user, writes `.env` for generic profile, prints summary with credentials (not logged).
 - For static profile, `--php` and DB flags are ignored (with warnings); no PHP-FPM pool or cron is created.
 - Project ID (slug) is still used for pools/cron/queue/sockets/logs even if the path style uses the domain.
 - If an existing slug/domain directory is found, the tool reuses it to avoid duplicates and warns accordingly.
- `/healthcheck.php` is localhost-only by default; test with `curl -i -H "Host: <domain>" http://127.0.0.1/healthcheck.php`.

## remove
Remove site resources.

Prompts (when not provided): select domain, yes/no for removing files, dropping DB/user.

Options:
- `--domain`
- `--project-name`
- `--path`
- `--remove-files` (`yes|no`)
- `--drop-db` (`yes|no`, default DB name from project)
- `--drop-db-user` (`yes|no`, default user from project)
- `--db-name`, `--db-user`

Removes nginx config, PHP-FPM pools (all versions), cron file (`/etc/cron.d/<project>`), and queue systemd unit (`laravel-queue-<project>.service`). Files/DB/user are removed only when confirmed/flagged. Alias profile removes only nginx/service stubs (no files/DB/pools).

### Destructive operations and `--confirm`
In non-menu mode, `--confirm yes` is required only when any destructive flags are set:
- `--remove-files yes`
- `--drop-db yes`
- `--drop-db-user yes`

Examples:
- Safe remove (no confirm needed):
  `simai-admin.sh site remove --domain <domain> --remove-files no --drop-db no --drop-db-user no`
- Destructive remove (confirm required):
  `simai-admin.sh site remove --domain <domain> --remove-files yes --confirm yes`

## list
List domains from nginx sites-available with profile, PHP version, root/alias target, and brief SSL status (off/LE:YYYY-MM-DD/custom).

## set-php
Switch site to a different PHP version.

Options:
- `--domain` (required; aliases are not allowed)
- `--php` (target version, must be installed)
- `--keep-old-pool` (`yes|no`, default `no`; if `no`, removes old PHP-FPM pool)
- `--project-name` (optional; inferred from domain)

Behavior:
- Recreates PHP-FPM pool for the target version, patches nginx upstream sockets in-place (preserves SSL/custom edits), updates metadata, and reloads services after backing up nginx config.
- Laravel profile also refreshes `/etc/cron.d/<project>` and updates/restarts the queue unit if present.
- Refuses to run for alias or static profiles (change PHP on the target site instead).

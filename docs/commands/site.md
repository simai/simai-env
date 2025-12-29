# site commands

Run with `sudo /root/simai-env/simai-admin.sh site <command> [options]` or via menu.

## add
Create nginx vhost and PHP-FPM pool for an existing project path.

Options:
- `--domain` (required)
- `--project-name` (optional; derived from domain if missing)
- `--path` (optional; default `/home/simai/www/<project>`)
- `--profile` (`generic`|`laravel`|`alias`, default `generic`)
- `--php` (optional; choose from installed if omitted)
- DB (optional): `--create-db=yes|no`, `--db-name`, `--db-user`, `--db-pass` (defaults from project; password generated)

Behavior:
- Generic uses placeholder and `public` root; Laravel requires `artisan`. Alias points the domain to an existing site (reuses its PHP-FPM pool/root, no DB/pool creation).
- Creates PHP-FPM pool and nginx vhost; installs `public/healthcheck.php` (non-alias).
- If `create-db=yes`, creates DB/user, writes `.env` for generic profile, prints summary with credentials (not logged).
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
  `simai-admin.sh site remove --domain example.com --remove-files no --drop-db no --drop-db-user no`
- Destructive remove (confirm required):
  `simai-admin.sh site remove --domain example.com --remove-files yes --confirm yes`

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
- Recreates PHP-FPM pool for the target version, updates nginx upstream and metadata, reloads services.
- Refuses to run for alias profile (change PHP on the target site instead).

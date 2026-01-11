# Site Lifecycle

## Creation (site add)
- Validate domain/path and profile from registry (`profiles/*.profile.sh`).
- Ensure user `simai` and project root under `/home/simai/www/<domain>/`.
- Bootstrap placeholders:
  - generic/static: placeholder index in `public/`
  - laravel: expects `artisan`/`bootstrap/app.php`
- Configure PHP-FPM pool (except static/alias) using project slug for pool/socket/cron/unit names.
- Generate nginx vhost from template, embed `# simai-*` metadata, lock down catch-all.
- Install healthcheck (if profile enables it) to `public/healthcheck.php`.
- For laravel: create cron in `/etc/cron.d/<project-slug>`; optional queue unit.
- Optional DB/user creation when requested.

## Removal (site remove)
- Reads profile from nginx metadata and validates domain/path/slug (fallback slug for derived names).
- Always removes nginx vhost/symlink (nginx -t before reload; restores backup if test fails).
- Removes PHP-FPM pool/cron/queue only when the profile requires them (static/alias skip automatically).
- Optional: remove files, drop DB/user when explicitly confirmed; DB prompts only when the profile requires/optionally supports DB.

## Update/maintenance
- set-php recreates pool and patches nginx upstream in-place, respecting profile rules (`PROFILE_REQUIRES_PHP`, `PROFILE_ALLOW_PHP_SWITCH`, allowed versions).
- ssl commands manage LE/custom certs and nginx TLS config.
- Admin menu and commands audited to `/var/log/simai-audit.log`.

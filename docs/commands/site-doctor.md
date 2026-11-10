# site doctor

Diagnose a site against its profile contract (read-only; no fixes).

Usage:
- `simai-admin.sh site doctor --domain <domain> [--strict yes|no] [--include-target yes|no]`

What it checks (non-destructive):
- Profile validity and metadata presence.
- Filesystem: root/docroot, required markers, bootstrap files, writable paths,
  `.env` permissions, and world-writable files/directories under the project
  root.
- nginx: config/symlink presence, healthcheck policy vs profile, `nginx -t`.
- PHP: installed version, php-fpm service/pool/socket, required/recommended extensions, INI expectations.
  INI values are read as PHP-FPM of the site's version applies them: the pool
  (`php_admin_value`/`php_admin_flag`) first, then the FPM `php.ini` and
  `conf.d` (not the CLI ones). OPcache memory keys
  (`opcache.memory_consumption`, `opcache.interned_strings_buffer`,
  `opcache.max_accelerated_files`) are always read from the FPM master, since
  a pool value does not change them; for Bitrix they come from the host
  baseline (`bitrix php-baseline-sync`).
- Cron: `/etc/cron.d/<slug>` when profile enables cron.
- SSL: cert files presence when metadata says ssl=on.
- DB: mysql service presence when profile requires DB, MySQL public listener
  exposure on `3306/33060`, and `.env` presence for required DB profiles.
- Alias: when `--include-target=yes`, performs a prefixed partial check of the target site (non-recursive).

Notes:
- No changes are applied; use `site drift` for metadata/cron drift planning/fixes.
- `--strict yes` makes the command exit non-zero on FAIL results.
- World-writable project files are reported as `FAIL`; do not use `chmod 777`
  as a workaround for application writes.
- Public MySQL listeners are reported as `WARN` because external DB access can
  be intentional, but the default local-site posture is localhost-only MySQL
  plus firewall protection.

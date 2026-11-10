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

Profile rules with a one-click fix (1.55.0):
- Each rule has a stable key; a failing rule names its fix:
  `simai-admin.sh site check-fix --domain <d> --id <key> --confirm yes`
  (without `--confirm` a plan; refused when the rule holds or does not apply).
  `site check-state --domain <d> --id <key>` shows one rule.
- Bitrix: `bitrix.docroot-leftovers` (FAIL: backup volumes, restore.php or
  SQL dumps downloadable from the web root; moved to `<site>/restore-archive`),
  `bitrix.dot-default` (FAIL: nginx refuses `.default` folders),
  `bitrix.db-session-modes` (after_connect_d7.php without `sql_mode=''` and
  `innodb_strict_mode=0`), `bitrix.db-charset` (database default is not the
  profile charset), `bitrix.timezone` (PHP runs in another zone than the
  server and MySQL, and the site sets none), `bitrix.opcache` (host OPcache
  baseline not met).
- WordPress (1.56.0): `wordpress.leftovers` (FAIL: SQL dumps, `.tar`,
  `.tar.gz`, `.tgz`, `.zip`, `.wpress` files at the top of the web root or
  dumps in `wp-content`; moved to `<site>/restore-archive`, nothing deleted),
  `wordpress.config-perms` (FAIL: `wp-config.php` readable by other accounts
  or a symlink; the fix removes access for others, `chmod o-rwx`),
  `wordpress.debug-off` (`WP_DEBUG` or `WP_DEBUG_DISPLAY` true, or the site's
  `display_errors` override on; the fix sets both constants false and turns
  the override off), `wordpress.cron` (`DISABLE_WP_CRON` not true or no
  `wp-cron.php` entry in `/etc/cron.d/<slug>`; the fix sets the constant and
  rewrites the entry). `wp-config.php` is edited as its owner, never through
  a symlink. `wp finalize` runs the same fixes. PHP sites: `php.fpm-graceful-reload` (a reload kills
  busy requests). Keyed rules without a fix: `bitrix.upload-limit`,
  `bitrix.sef-fallback`, `bitrix.static-gzip`, `bitrix.static-cache`,
  `bitrix.ownership`.
- `--output json`: such items carry `key`, `fix`, `since` (first time the
  rule failed, kept in `/var/lib/simai-env/site-checks/<domain>.json`; null
  while it passes) and `detail`; the answer names the `profile`.

Notes:
- No changes are applied; use `site drift` for metadata/cron drift planning/fixes.
- `--strict yes` makes the command exit non-zero on FAIL results.
- World-writable project files are reported as `FAIL`; do not use `chmod 777`
  as a workaround for application writes.
- Public MySQL listeners are reported as `WARN` because external DB access can
  be intentional, but the default local-site posture is localhost-only MySQL
  plus firewall protection.

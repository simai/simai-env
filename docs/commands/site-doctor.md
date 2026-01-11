# site doctor

Diagnose a site against its profile contract (read-only; no fixes).

Usage:
- `simai-admin.sh site doctor --domain <domain> [--strict yes|no] [--include-target yes|no]`

What it checks (non-destructive):
- Profile validity and metadata presence.
- Filesystem: root/docroot, required markers, bootstrap files, writable paths, .env permissions.
- nginx: config/symlink presence, healthcheck policy vs profile, `nginx -t`.
- PHP: installed version, php-fpm service/pool/socket, required/recommended extensions, INI expectations.
- Cron: `/etc/cron.d/<slug>` when profile enables cron.
- SSL: cert files presence when metadata says ssl=on.
- DB: mysql service presence when profile requires DB; `.env` presence for required DB profiles.
- Alias: when `--include-target=yes`, performs a prefixed partial check of the target site (non-recursive).

Notes:
- No changes are applied; use `site drift` for metadata/cron drift planning/fixes.
- `--strict yes` makes the command exit non-zero on FAIL results.

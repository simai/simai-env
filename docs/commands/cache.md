# cache commands

Laravel-only cache maintenance powered by artisan. Commands are non-interactive and respect the site's configured PHP version and owner.

## clear
Clear framework caches for a Laravel site.

Usage: `simai-admin.sh cache clear --domain <domain>`

Behavior:
- Validates domain and profile (laravel-only); non-Laravel sites get a clear error with guidance.
- Requires `artisan` in the site root; otherwise fails with a hint to run `site doctor`.
- Runs, as the site owner, the following in order with progress: `cache:clear`, `config:clear`, `route:clear`, `view:clear` using the site's PHP version (requires php<version> to be installed; install via `simai-admin.sh php install --version <ver>`).
- Alias: `cache run` invokes the same behavior.

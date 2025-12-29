# Changelog
All notable changes to this project will be documented in this file.

## [0.7.17] - 2025-12-29
### Added
- Static site profile (nginx-only) with placeholder index and local healthcheck; appears first in profile menu, skips PHP/DB prompts, and aliases inherit static template when targeting static sites.

### Fixed
- SSL apply respects static template selection; set-php refuses static sites.

## [0.7.16] - 2025-12-29
### Changed
- Default site directory naming now uses the domain (`/home/simai/www/<domain>`); slug paths remain available via `--path-style slug` and slug stays the ID for pools/cron/queue/socket names.
- Safeguard reuses existing slug/domain directories (with warnings) to avoid duplicate paths when switching styles.

## [0.7.15] - 2025-12-29
### Added
- Site add supports domain-based default path style via `--path-style domain` or `SIMAI_DEFAULT_PATH_STYLE=domain` in `/etc/simai-env.conf`; slug remains default for IDs/pools/cron.

## [0.7.14] - 2025-12-29
### Fixed/Docs
- Removed misleading example.com/myapp install hints; usage/examples now use placeholders and note installer does not create sites.
- Added reserved-domain guard for example.com/.net/.org with explicit opt-in.

## [0.7.13] - 2025-12-29
### Added
- `backup export` command (config-only bundle) with optional nginx references and menu entry under Backup / Migrate.

### Fixed
- More reliable insertion of `# simai-php` metadata during nginx socket patching.
- `php list` table widened for longer FPM statuses.

## [0.7.12] - 2025-12-29
### Fixed
- Robust insertion of `# simai-php` metadata when patching nginx sockets during PHP switches.
- `php list` table accommodates longer FPM status values.

## [0.7.11] - 2025-12-29
### Fixed
- `php list` now shows a bordered table with FPM status and pool counts.
- `site set-php` preserves SSL/custom nginx config by patching sockets in-place, recreates pools, and refreshes cron/queue for Laravel.

## [0.7.10] - 2025-12-29
### Fixed
- Ensure cron is installed/started during simai-env installs and improve cron removal UX (project-name or path).
- Added cron command documentation and clearer cron service handling in admin helpers.

### Security
- Admin cron helpers warn when cron is missing/inactive to prevent silent scheduler failures.

## [0.7.9] - 2025-12-29
### Fixed
- Standardized Laravel scheduler to `/etc/cron.d/<project>` and implemented cron add/remove commands.

### Security/Docs
- Healthcheck output/docs now clarify `/healthcheck.php` is localhost-only by default.

## [0.7.8] - 2025-12-29
### Security
- Lock down `/healthcheck.php` to localhost-only access by default in nginx templates.

### Docs
- Clarify when `--confirm yes` is required for `site remove` and `ssl remove`, with examples.

## [0.7.7] - 2025-12-29
### Fixed
- Site removal now only requires confirmation when destructive flags are set, while safe removals proceed without extra prompts.
- SSL removal only asks for confirmation when certificates are being deleted (`delete-cert=yes`), avoiding unnecessary blocks.
- Nginx configs are backed up before regeneration across admin and simai-env with a consistent `.bak.<timestamp>` naming scheme.

### Security
- MySQL user creation no longer drops existing `@%` accounts automatically and continues to create local-only users by default.
- Confirmation gating now targets destructive actions only, reducing unintended stoppages while keeping dangerous operations explicit.

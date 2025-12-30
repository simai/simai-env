# Changelog
All notable changes to this project will be documented in this file.

## [0.8.3] - 2025-12-30
### Changed
- self bootstrap menu label now reads “Repair Environment …” to clarify it repairs/installs the base stack without touching sites.
### Fixed
- self update no longer drops the user to shell; menu restart is safe and stays open if restart fails.

## [0.8.2] - 2025-12-30
### Fixed
- Site list output is responsive to terminal width, truncates safely, and avoids wrapping on narrow displays.
- Site remove prompts now respect static profile (no DB prompts) and skip PHP/cron/queue removal for static/alias sites with summaries showing none/n/a.

## [0.8.1] - 2025-12-30
### Added/Changed
- Added OS compatibility preflight with clear TTY status output (Ubuntu 20.04/22.04/24.04 supported), shared via platform helpers and used before bootstrap/update/install.
### Improved
- Colored OS status goes only to TTY; logs remain clean of ANSI codes.

## [0.8.0] - 2025-12-30
### Added/Changed
- Admin CLI now has a unified spinner/timing `run_long` helper for long-running commands; SSL/certbot operations use it with progress steps.
- Copilot instructions enforce run_long + progress steps for long operations to avoid silent waits.
### Fixed
- Nginx SSL redirect/HSTS insertion now emits valid directives without stray escapes.

## [0.7.30] - 2025-12-30
### Fixed
- Fixed bootstrap/install failure where run_long could not execute commands prefixed with env assignments (e.g., DEBIAN_FRONTEND=noninteractive).

## [0.7.29] - 2025-12-30
### Improved
- Bootstrap and installer long-running steps now show a spinner with elapsed time on interactive terminals while logging to /var/log/simai-env.log, preventing “silent freeze” during apt installs.

## [0.7.28] - 2025-12-30
### Fixed
- Installer defaults now run bootstrap (packages/services) unless explicitly skipped; scripts-only no longer the default.
- Installer can auto-open the admin menu even when invoked via `curl | sudo bash` by using /dev/tty and avoids sudo inside bootstrap calls.

## [0.7.27] - 2025-12-30
### Added/Changed
- Installer now runs a full bootstrap (packages/services) by default and can launch the admin menu; opt out via SIMAI_INSTALL_MODE=scripts or SIMAI_INSTALL_NO_BOOTSTRAP=1.
- README quick start simplified; scripts-only install documented.
### Improved
- Bootstrap call is non-interactive with clear progress; no sites are created during install.

## [0.7.25] - 2025-12-30
### Added/Changed
- Bootstrap mode installs the base stack without creating sites; admin menu runs a preflight and can trigger bootstrap on fresh servers.
- README simplified to two commands (install + menu); advanced installer details moved to docs/advanced-installer.md.
### Improved
- User-facing examples avoid reserved RFC 2606 domains; help text references are generic.

## [0.7.24] - 2025-12-30
### Fixed
- SSL nginx patch now inserts directives in the server block (no more placement inside location blocks causing invalid configs).
- On nginx -t failures during SSL apply, a tail of the nginx error output is shown for easier diagnostics.
### Improved
- SSL nginx apply remains transactional: failed applies save the generated file for debugging, restore the prior config, and avoid nginx reload.

## [0.7.23] - 2025-12-30
### Fixed
- Robust SSL nginx config injection: safer perl patching with no shell expansion issues for certificate/key paths.
- ssl letsencrypt/install stop on nginx apply failures and no longer print success when apply fails.
### Improved
- Transactional nginx apply restores the previous config on failure to keep nginx valid.

## [0.7.22] - 2025-12-29
### Fixed
- ssl letsencrypt now reaches certbot for static sites; helpers return success explicitly to avoid false exits under `set -e`.
- read_site_metadata and ssl_site_context avoid non-zero returns on normal paths.
### Improved
- Added step-based progress output for SSL issue/install/renew flows to make long operations transparent.
- Menu/self-update stability: sandboxed handlers now signal menu reload via a dedicated return code without terminating the menu loop.

## [0.7.21] - 2025-12-29
### Fixed
- Menu no longer exits when handlers call exit; handlers are sandboxed and errors are reported with exit codes.
- require_args and create_nginx_site now return errors instead of exiting, preserving menu flow.
- SSL status/remove honor reserved-domain allow policy without re-blocking.

## [0.7.20] - 2025-12-29
### Fixed
- Site add menu no longer prompts for path style; default directory uses the domain with dots unless overridden via CLI/config.
- Menu now survives handler exits (handlers run in subshell); failures report exit codes instead of terminating the menu.
- SSL status/remove respect the reserved-domain allow policy.

## [0.7.19] - 2025-12-29
### Fixed
- Site add (menu) no longer prompts for path style; default directory uses the domain with dots when --path is not provided, while CLI path-style overrides remain available.

## [0.7.18] - 2025-12-29
### Fixed
- Reserved-domain guard now blocks creation unless ALLOW_RESERVED_DOMAIN=yes but allows cleanup/status operations without misleading prompts.

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

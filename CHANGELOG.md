# Changelog
All notable changes to this project will be documented in this file.

## [1.11.30] - 2026-03-19
### Fixed
- `site add` runtime now defines `SIMAI_HOME` consistently inside site utility helpers, avoiding `unbound variable` failures during user/home preparation on fresh site creation.

## [1.11.29] - 2026-03-19
### Fixed
- `site add` and bootstrap no longer reset ownership recursively on the entire SIMAI home directory, avoiding long hangs on servers with existing site data.

## [1.11.28] - 2026-03-19
### Changed
- Bitrix production docs now define a stricter post-install workflow: `site add` -> `installer-ready` -> web install -> `php-baseline-sync` -> `agents-sync` -> TLS -> final checker/perfmon acceptance.

## [1.11.27] - 2026-03-19
### Fixed
- SSL metadata checks now understand normalized site metadata values like `letsencrypt` and `custom`, avoiding false `Metadata drift` warnings in `site doctor`.

## [1.11.26] - 2026-03-19
### Fixed
- `site doctor` and `site fix` now evaluate PHP INI against the effective PHP-FPM pool config when available, avoiding false Bitrix runtime warnings caused by CLI `php.ini`.

## [1.11.25] - 2026-03-19
### Fixed
- Bitrix DB preseed now initializes MySQL connection collation more explicitly with `SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci`, preventing MySQL 8 `utf8mb4_0900_ai_ci` connection mismatch on fresh installs.

## [1.11.24] - 2026-03-19
### Fixed
- Bitrix DB/user creation now grants `SESSION_VARIABLES_ADMIN` (best effort) so MySQL 8 session compatibility settings can be applied on fresh installs.
- Bitrix DB preseed now also creates `bitrix/php_interface/after_connect_d7.php` with MySQL session compatibility commands:
  - `SET SESSION sql_mode=''`
  - `SET SESSION innodb_strict_mode=0`
  - `SET SESSION collation_connection='utf8mb4_unicode_ci'`

## [1.11.23] - 2026-03-19
### Changed
- Bitrix nginx template is now closer to default Bitrix `.htaccess` behavior on fresh installs:
  - `try_files ... /bitrix/urlrewrite.php?$args`
  - `error_page 404 /404.php`
  - `autoindex off`
  - 3-day cache headers for common static assets (`css`, `js`, `gif`, `png`, `jpg`, `jpeg`)
### Fixed
- Bitrix PHP locations now forward auth context more explicitly for checker and 1C integration compatibility:
  - `HTTP_AUTHORIZATION`
  - `REMOTE_USER`
  - `REDIRECT_REMOTE_USER`

## [1.11.22] - 2026-03-19
### Fixed
- Bitrix nginx template now explicitly forwards `Authorization` to PHP-FPM via `fastcgi_param HTTP_AUTHORIZATION $http_authorization`.
- This makes HTTP auth behavior deterministic for Bitrix/1C integrations on nginx+php-fpm instead of relying on distro-specific fastcgi defaults.

## [1.11.21] - 2026-03-19
### Fixed
- Bitrix DB preseed no longer writes `BX_CRONTAB_SUPPORT` into `dbconn.php` during initial install.
- Agents-over-cron mode is now enabled only via explicit `bitrix agents-sync --apply yes`, which keeps fresh installs compatible with Bitrix checker until cron mode is intentionally switched on.

## [1.11.20] - 2026-03-15
### Changed
- Bitrix cron baseline now uses `* * * * *` for `public/bitrix/modules/main/tools/cron_events.php`.
- Bitrix DB preseed now writes `BX_CRONTAB_SUPPORT` in guarded form (`if (!defined(...))`), matching cron-enable workflow safety.
### Fixed
- Bitrix DB preseed now sets MySQL session compatibility defaults in `.settings.php`:
  - `SET sql_mode=''`
  - `SET collation_connection='utf8mb4_unicode_ci'`
- Bootstrap now installs/enables local postfix (`Local only`) so PHP mail transport works out-of-the-box for checker mail tests.

## [1.11.19] - 2026-03-15
### Fixed
- Bitrix nginx template now sets `client_max_body_size 64m` to avoid `413 Request Entity Too Large` during site checker large upload test (`check_upload_big`).

## [1.11.18] - 2026-03-15
### Fixed
- Bitrix preseed no longer writes `BX_CRONTAB` into `dbconn.php` (web checker-compatible behavior).
- `bitrix agents-sync` now normalizes cron constants to web-safe mode:
  - removes `BX_CRONTAB` from `dbconn.php`
  - keeps `BX_CRONTAB_SUPPORT=true`
- Updated agents readiness logic to rely on cron markers + `BX_CRONTAB_SUPPORT`.

## [1.11.17] - 2026-03-15
### Fixed
- Bitrix DB preseed now also writes default file/dir permission constants in `dbconn.php`:
  - `BX_FILE_PERMISSIONS=0644`
  - `BX_DIR_PERMISSIONS=0755`
- This prevents `site_checker` runtime errors on cache/FS checks when these constants are missing.

## [1.11.16] - 2026-03-15
### Added
- Added `bitrix installer-ready` command to prepare installer flow in one step:
  - DB preseed generation (`.settings.php`, `dbconn.php`)
  - best-effort download of `bitrixsetup.php`
- Added `Bitrix installer ready` item in interactive menu (`Laravel` section).
### Changed
- `site add` for `bitrix` profile now also downloads `bitrixsetup.php` (best effort) after DB preseed generation.
- `bitrix status` now reports `bitrixsetup.php` presence/path.

## [1.11.15] - 2026-03-15
### Changed
- Bitrix profile now enables `SHORT_INSTALL` by default in generated DB preseed (`dbconn.php`) to simplify installer flow.
- `bitrix db-preseed` now supports `--short-install yes|no` and reports selected mode in output.
### Added
- `bitrix status` now shows `SHORT_INSTALL` state from `dbconn.php` (best effort).

## [1.11.14] - 2026-03-15
### Fixed
- Improved `bitrix php-baseline-sync` to enforce critical FPM runtime keys after `site fix`:
  - `memory_limit=512M`
  - `opcache.validate_timestamps=1`
  - `opcache.revalidate_freq=0`
- This ensures Bitrix installer/runtime checks are consistent even when CLI defaults differ from FPM pool values.

## [1.11.13] - 2026-03-15
### Added
- Added `bitrix php-baseline-sync` command:
  - single site: `--domain <domain>`
  - bulk mode: `--all yes --confirm yes`
- Added menu action `Bitrix PHP baseline sync (all)` in advanced mode.

## [1.11.12] - 2026-03-15
### Fixed
- Fixed PHP INI writer behavior for numeric values (`0`/`1`) in pool overrides:
  - `site fix` now writes numeric settings as `php_admin_value` (not `php_admin_flag`).
  - site-level INI overrides now keep numeric values as `php_admin_value`.
- This prevents incorrect flag rendering for keys like `opcache.revalidate_freq`.

## [1.11.11] - 2026-03-15
### Added
- Added `Bitrix DB preseed` action to interactive menu (`Laravel` section) for quick generation of Bitrix DB config files from `db.env`.
### Changed
- Updated Bitrix profile recommendation: `opcache.revalidate_freq=0`.
- New Bitrix PHP-FPM pools now include baseline overrides for installer/runtime compatibility:
  - `short_open_tag=on`
  - `memory_limit=512M`
  - `opcache.validate_timestamps=1`
  - `opcache.revalidate_freq=0`

## [1.11.10] - 2026-03-15
### Added
- Added `bitrix db-preseed --domain <domain> [--overwrite yes]` to generate valid Bitrix DB config files (`bitrix/.settings.php`, `bitrix/php_interface/dbconn.php`) from site `db.env`.
### Changed
- `site add` now auto-generates Bitrix DB preseed files for `bitrix` profile sites when `db.env` is available.
### Fixed
- Hardened Bitrix DB preseed generation with safe PHP string escaping and syntax validation before write.

## [1.11.9] - 2026-03-15
### Fixed
- Improved `site doctor` SSL checks to use actual nginx TLS directives/cert files in addition to metadata.
- Added SSL metadata drift warnings when nginx and metadata disagree (`ssl=on/off` mismatch).

## [1.11.8] - 2026-03-15
### Fixed
- Fixed `site doctor` INI comparison for values with uppercase size suffixes (`8M`, `4096K`) to avoid arithmetic parser warnings.
- Reduced cron refresh noise by using restart flow instead of reload for `cron` service updates.
- Bitrix profile PHP-FPM pool now enables `short_open_tag` by default, so `bitrixsetup.php` works out-of-the-box.

## [1.11.7] - 2026-03-15
### Changed
- Switched interactive menu to stable text backend by default (no auto whiptail).
- Simplified command result flow in menu: plain console result/status + explicit Enter pause.
- Kept `whiptail` as optional backend via explicit selection/env for users who prefer TUI.

## [1.11.6] - 2026-03-15
### Added
- Added dedicated WordPress production runbook with end-to-end flow:
  - provisioning
  - cron baseline
  - TLS go-live
  - daily checks
  - incident fast path
  (`docs/operations/wordpress-production-runbook.md`)
### Changed
- Linked WordPress production runbook from top-level docs entrypoints and profile matrix.

## [1.11.5] - 2026-03-15
### Changed
- Improved interactive menu UX:
  - command execution now opens a dedicated result screen (output + status) before returning to menu.
  - added keyboard usage hints for menu navigation (`Enter/Tab/Esc` for whiptail).
  - added runtime backend toggle in `System` section (`text` <-> `whiptail`).
- Added calmer default `whiptail` color theme to reduce overly bright background behavior.

## [1.11.4] - 2026-03-14
### Added
- Added dedicated WordPress production runbook with end-to-end flow:
  - provisioning
  - cron baseline
  - TLS go-live
  - daily checks
  - incident fast path
  (`docs/operations/wordpress-production-runbook.md`)
### Changed
- Linked WordPress production runbook from top-level docs entrypoints and profile matrix.

## [1.11.3] - 2026-03-14
### Added
- Added dedicated Bitrix production runbook with end-to-end flow:
  - provisioning
  - agents-over-cron baseline
  - TLS go-live
  - daily checks
  - incident fast path
  (`docs/operations/bitrix-production-runbook.md`)
### Changed
- Linked Bitrix production runbook from top-level docs entrypoints and profile matrix.

## [1.11.2] - 2026-03-14
### Fixed
- Fixed error-code propagation in `bitrix agents-status` and `bitrix agents-sync` (profile-mismatch now returns non-zero as expected).

## [1.11.1] - 2026-03-14
### Fixed
- Fixed Bitrix profile syntax for `PROFILE_PHP_INI_RECOMMENDED` to keep `profile validate` compatible (single-line declarative assignment).

## [1.11.0] - 2026-03-14
### Added
- Added Bitrix agents baseline commands:
  - `bitrix agents-status`
  - `bitrix agents-sync` (plan/apply)
- Wired Bitrix agents commands into interactive menu (`Laravel` section), including advanced apply action.
### Changed
- Updated Bitrix profile runtime policy:
  - allowed PHP versions are now `8.2/8.3/8.4` (removed `8.1`).
  - added recommended PHP INI baseline for Bitrix production workloads.
- Extended regression coverage with Bitrix agents checks (`core` + profile-mismatch negative).
- Expanded Bitrix command docs with agents-over-cron workflow and safeguards.

## [1.10.7] - 2026-03-14
### Added
- Added profile operations matrix for daily use (`docs/operations/profile-ops-matrix.md`) covering `generic`, `laravel`, `wordpress`, `bitrix`, `static`, and `alias`.
### Changed
- Linked the new profile matrix from `README.md`, `docs/README.md`, `docs/admin.md`, and daily quickstart.

## [1.10.6] - 2026-03-14
### Changed
- Added fast post-update smoke checks to `self update` (script executability + shell syntax sanity).
- Added strict mode for post-update smoke via `SIMAI_UPDATE_SMOKE_STRICT=yes`.
- Regression sync-update step now uses strict smoke mode to fail fast on broken updates.

## [1.10.5] - 2026-03-14
### Changed
- Improved WordPress and Bitrix status UX with richer daily diagnostics:
  - cron managed/domain/slug marker checks in `status` and `cron-status`.
  - WordPress status now reports CLI readiness and best-effort Home URL.
  - Bitrix status now reports `dbconn.php` presence and best-effort `BX_CRONTAB` mode.
### Fixed
- Added regression negatives for profile-mismatch guards (`wp status` on non-wordpress profile, `bitrix status` on non-bitrix profile).

## [1.10.4] - 2026-03-14
### Fixed
- Updated menu regression selector for `Sites -> Remove site` after menu key cleanup.

## [1.10.3] - 2026-03-14
### Changed
- Polished interactive menu UX by hiding unfinished actions and keeping only implemented daily-use paths in Sites/PHP/Database/Logs.
- Added compact operator quickstart for daily routines and release gating (`docs/operations/daily-ops-quickstart.md`).
- Linked quickstart from top-level documentation entrypoints.

## [1.10.2] - 2026-03-14
### Added
- Added mandatory release gate runner `testing/release-gate.sh` (shell syntax checks + `testing/run-regression.sh full`).
### Changed
- Hardened update channel handling:
  - `self version` and menu banner now resolve remote version by configured update ref (`SIMAI_UPDATE_REF`/`SIMAI_UPDATE_BRANCH`).
  - `update.sh` now supports update ref/branch from `/etc/simai-env.conf` and validates ref format.
- `testing/run-regression.sh` now syncs test host with `self update` before checks (`TEST_SYNC_UPDATE=yes` by default).
- Extended negative regression with backup import apply guards for profile incompatibility.
### Fixed
- Added best-effort pre-update backup creation in `update.sh` with explicit rollback hint.

## [1.10.1] - 2026-03-14
### Changed
- Polished `backup import` plan with profile-compatibility summary (known/enabled/requires PHP/supports cron/supports queue).
- Made backup apply profile-aware: cron and queue unit restore now respects local profile contract.
- Extended core regression flow with `backup inspect` and `backup import --apply no`.
### Fixed
- Prevented backup apply on incompatible profile state (unknown/disabled profile, or PHP-required profile with `php=none` in manifest).

## [1.10.0] - 2026-03-14
### Added
- Added Bitrix daily-ops command group `bitrix`:
  - `bitrix status`
  - `bitrix cron-status`
  - `bitrix cron-sync`
  - `bitrix cache-clear`
- Added Bitrix command reference: `docs/commands/bitrix.md`.
### Changed
- Wired Bitrix daily-ops commands into interactive menu for operational access.
- Extended core regression flow with disposable Bitrix profile lifecycle checks (`bitrix status/cron-status/cron-sync`).

## [1.9.0] - 2026-03-14
### Added
- Added WordPress daily-ops command group `wp`:
  - `wp status`
  - `wp cron-status`
  - `wp cron-sync`
  - `wp cache-clear`
- Added WordPress command reference: `docs/commands/wp.md`.
### Changed
- Wired WordPress daily-ops commands into interactive menu (Laravel section) for operational access.
- Extended core regression flow with disposable WordPress profile lifecycle checks (`wp status/cron-status/cron-sync`).

## [1.8.19] - 2026-03-14
### Fixed
- Fixed `site doctor` progress counter after adding profile-specific application checks (`11/11` instead of `11/10`).

## [1.8.18] - 2026-03-14
### Changed
- Extended `site doctor` with profile-aware application checks for WordPress/Bitrix (cron mode/config presence, core entrypoint checks with scaffold-safe SKIP behavior).
### Added
- Added broken manual certificate path check to `negative/full` regression scenarios.

## [1.8.17] - 2026-03-14
### Added
- Added operator runbook for daily operations and incident handling: `docs/operations/runbook.md`.
### Changed
- Documented non-interactive usage contract in `docs/admin.md` (exit codes, output channels, color control, menu backend switches).
- Updated documentation entrypoints to include the operations runbook.

## [1.8.16] - 2026-03-14
### Changed
- Unified lifecycle output blocks for `ssl letsencrypt/install/remove` and `backup export/inspect/import` using structured `Header -> Result/Plan -> Next steps` sections.
### Added
- Added `negative` regression mode for expected-failure scenarios (missing domain/file), and included it in `full` regression runs.

## [1.8.15] - 2026-03-14
### Changed
- Unified overview command UX for daily operations: `site info`, `ssl list`, `db status`, and `db list` now use structured `Header -> Result -> Next steps` output blocks.

## [1.8.14] - 2026-03-14
### Fixed
- Fixed `whiptail` backend activation in menu selections/prompts when values are captured via command substitution (switched TTY checks to `/dev/tty` availability).
### Added
- Added `backend` regression mode to probe `SIMAI_MENU_BACKEND=whiptail` activation and detect unintended text fallback.
### Changed
- Included backend probe in `testing/run-regression.sh full` and documented the new mode in testing guide.

## [1.8.13] - 2026-03-14
### Changed
- Polished interactive menu UX: invalid selections now use unified warning output and the menu header now shows active backend (`text`/`whiptail`).
### Added
- Extended automated menu regression checks with `backup inspect` cancel-flow coverage in `testing/run-regression.sh menu/full`.

## [1.8.12] - 2026-03-14
### Added
- Added dedicated `menu` and `full` modes to `testing/run-regression.sh` for automated interactive menu cancel-flow checks.
### Changed
- Updated test documentation with new regression modes and usage examples.
### Fixed
- Hardened menu regression matcher (`grep -Fq --`) to correctly validate expected lines that start with dashes.

## [1.8.11] - 2026-03-14
### Changed
- Migrated all remaining submenus (PHP/Database/Diagnostics/Logs/Backup/Laravel/Profiles/System) to the unified menu adapter.
- Standardized selection flow across text and optional `whiptail` backends while preserving existing command behavior and safety semantics.

## [1.8.10] - 2026-03-14
### Fixed
- Fixed text-menu regression in the new menu adapter: menu rendering now writes to stderr so captured menu choices remain valid.

## [1.8.9] - 2026-03-14
### Changed
- Added unified menu choice adapter in `admin/menu.sh` with automatic `whiptail` or text rendering.
- Migrated main menu, `Sites`, and `SSL` submenu selection flow to the new adapter while keeping command behavior unchanged.

## [1.8.8] - 2026-03-14
### Added
- Added reusable UI helper layer in `lib/ui.sh` (`ui_header`, `ui_section`, `ui_step`, `ui_kv`, `ui_info/success/warn/error`) for consistent CLI rendering.
### Changed
- Added optional `whiptail` backend support for interactive selections and prompts in menu mode, with automatic fallback to text backend.
- Updated `self status`, `self platform-status`, and `ssl status` to render structured header/result/next-steps blocks using the new UI helpers.

## [1.8.7] - 2026-03-14
### Fixed
- Polished SSL menu cancel flow (`ssl status/remove/install/letsencrypt`): cancelled domain selection now exits cleanly without fallback manual prompts.
- `site info` now treats an empty site list in menu mode as a non-error result (`No sites found`) to avoid false command-failed noise.

## [1.8.6] - 2026-03-14
### Changed
- Improved interactive required-argument UX in menu flows: `domain` is now selected from existing sites and backup `file` is selected from discovered archives.
### Fixed
- `site remove` now handles menu cancel paths safely (including empty site list and cancelled domain selection) without surfacing missing required-argument errors.

## [1.8.5] - 2026-03-14
### Changed
- Improved `site drift` cron checks to validate profile-specific cron entries (Laravel, WordPress, Bitrix).
- Updated release process to include executable regression gates (`testing/run-regression.sh smoke|core`).
### Fixed
- Reduced `site doctor` noise for WordPress and Bitrix profiles by tightening extension expectation defaults.

## [1.8.4] - 2026-03-14
### Added
- Added `wordpress` and `bitrix` profile MVPs with dedicated nginx templates for daily-use site lifecycle operations.
- Added executable regression runner (`testing/run-regression.sh`) and Q1 delivery roadmap (`docs/development/roadmap-2026-q1.md`).
### Changed
- Generalized nginx template id handling so new profile templates work without hardcoded template whitelists.
- Improved profile lifecycle setup by creating declared writable paths during `site add`.
- Made cron checks and cron rendering profile-aware for Laravel, WordPress, and Bitrix.
### Fixed
- Normalized PHP module detection in doctor checks to avoid false `opcache` missing reports.

## [1.8.3] - 2026-03-14
### Fixed
- Stopped exposing generated DB passwords in `site db-create` output.
- Silenced MySQL root detection probe noise in admin logs.

## [1.8.2] - 2026-03-14
### Fixed
- Hardened site lifecycle flows: alias targets can no longer be removed while dependent alias sites still exist.
- Polished status output and accuracy across `site info`, `ssl status`, `self platform-status`, `site doctor`, and `site drift`.
- Improved SSL cleanup behavior for custom certificates and restored proper CLI handling for `ssl status --domain`.
- Refined profile validation to avoid false PHP warnings for non-PHP profiles with empty declarative arrays.

## [1.8.1] - 2026-01-20
### Fixed
- SSL status output formatting and nginx-cert detection.
- Cancel is not treated as error in menu flows.
- Platform-status disk free shows /var/lib/mysql when available.

## [1.8.0] - 2026-01-20
### Added
- SSL status now shows SAN and nginx-config certificate paths (when available).
- Added diagnostics command `self platform-status` with disk/inodes/memory and nginx config test.
### Changed
- Diagnostics "Platform status" now uses `self platform-status`, while System "System status" remains `self status`.
### Fixed
- Improved robustness of SSL status output (best-effort, no crashes when data missing).

## [1.7.17] - 2026-01-20
### Changed
- Enhanced site info card with nginx healthcheck/logs/SSL flags and cron/worker status.
- SSL list now shows days remaining plus redirect and HSTS status.
- Self status includes component versions and certbot timer state; db status adds socket/port/datadir/disk info.

## [1.7.16] - 2026-01-19
### Changed
- Wired menu items to site info/ssl list/db status+list/drift apply/platform status.
- Let's Encrypt staging is now shown as LE-stg in site and SSL summaries.
### Added
- `site info`, `ssl list`, `db status`, `db list`, and `self status` commands.
### Test
- `sudo /root/simai-env/simai-admin.sh menu`
- Sites -> list (SSL shows LE-stg for staging)
- Sites -> info (select domain)
- SSL -> list
- SSL -> status (Issuer + Staging shown)
- Database -> MySQL status
- Database -> List databases
- Database -> Create DB + user / Rotate / Write creds
- Diagnostics -> Drift apply (ADV on)
- System -> System status

## [1.7.15] - 2026-01-19
### Changed
- Reworked simai-admin menu structure (Sites/SSL/PHP/Database/Diagnostics/Logs/Backup/Laravel/Profiles/System).
### Fixed
- Menu no longer exits to shell on command failures; required arguments are prompted interactively.
- Advanced toggle moved into System section.

## [1.7.14] - 2026-01-19
### Changed
- Let's Encrypt staging mode is now available only in Advanced mode.
### Fixed
- Prevented enabling HSTS with staging certificates (forced off) and added warnings to avoid browser trust confusion.

## [1.7.13] - 2026-01-19
### Fixed
- Fixed `ssl remove` in interactive menu: selected domain is now used correctly (no missing --domain error).

## [1.7.12] - 2026-01-19
### Fixed
- Interactive menu no longer exits on failed commands; required options are prompted in menu before execution.

## [1.7.11] - 2026-01-11
### Fixed
- Restored access to self update, cache, and php install commands in the new interactive menu via a dedicated Tools section.

## [1.7.10] - 2026-01-11
### Changed
- Reworked admin interactive menu structure for usability: separated Sites lifecycle, SSL, Diagnose, Maintenance, Logs, Backup/Migrate, Workers, Scheduler, Profiles, and Advanced Tools with an Advanced toggle in the main menu.

## [1.7.9] - 2026-01-11
### Fixed
- Self update no longer drops to shell: menu restart uses a fresh process with safe fallback and respects non-zero handler exits.
- run_command no longer leaks errexit state; the interactive menu stays alive on command errors.

## [1.7.8] - 2026-01-11
### Fixed
- Self update no longer drops users to shell: menu restarts via a fresh process with safe fallback and depth guard.

## [1.7.7] - 2026-01-11
### Fixed
- Fixed nginx config generation with simai metadata: ensured newline separation so `server {` cannot be commented out.
- `site add` now fails when nginx config test fails (no false success), preventing empty site lists after failed adds.
- Hardened admin menu input handling: menu switches to TTY when needed and empty section choice no longer exits unexpectedly (including after self update).

## [1.7.6] - 2026-01-11
### Improved
- Menu now hides advanced/legacy commands by default; a toggle shows advanced items. Legacy DB commands remain available via CLI but are hidden from the menu.

## [1.7.5] - 2026-01-11
### Fixed
- Prevented /etc/os-release from overwriting installer/update variables; installers now use REPO_BRANCH and read os-release in a subshell.

## [1.7.4] - 2026-01-11
### Fixed
- Fixed admin CLI crash under `set -u` when registering commands without optional args; installer now retains profile init/menu flow without set -u failures.

## [1.7.3] - 2026-01-11
### Fixed
- Fixed stdin installer failure caused by legacy platform-based OS checks overriding the self-contained /etc/os-release validation.

## [1.7.2] - 2026-01-11
### Fixed
- install.sh now works when run via stdin (`curl | bash`), performs self-contained OS checks, and no longer depends on local platform files before download.

## [1.7.1] - 2026-01-11
### Fixed
- Backup manifest is now valid JSON (enabled boolean) and import robustly handles empty `public_dir`.
- Hardened archive extraction against path traversal and improved rollback (including sites-enabled symlink) on reload failures.

## [1.7.0] - 2026-01-09
### Added
- Config-only backup/migrate commands: backup export/inspect/import for nginx/php-fpm/cron/queue configs with safe defaults and rollback.
### Security
- Backups exclude secrets (no SSL private keys, no .env contents); cron import only for SIMAI-managed files.

## [1.6.1] - 2026-01-09
### Fixed
- Removed direct systemctl usage from cron service checks by routing unit detection through the OS adapter.

## [1.6.0] - 2026-01-09
### Added
- OS adapter layer (Ubuntu implementation) for package manager and service manager actions.
### Changed
- simai-env.sh and admin commands now use OS adapter wrappers for apt and service operations (no behavior change).

## [1.5.3] - 2026-01-08
### Fixed
- Fully preserved empty `public_dir` semantics (""/"." -> project root) across metadata reading, SSL, alias, and doctor; removed implicit `public` fallbacks.
- Hardened public_dir/template validation in nginx generation and added CI guards against regressions.

## [1.5.2] - 2026-01-08
### Fixed
- Preserved empty public dir semantics (\"\"/\".\" -> docroot=project root) across nginx generation, SSL, and doctor; hardened template/public_dir validation.
- create_nginx_site now rejects unknown template ids/public_dir before writing configs.
### Added
- CI smoke checks for `{{DOC_ROOT}}` in nginx templates and metadata v2 marker.

## [1.5.1] - 2026-01-08
### Fixed
- Corrected create_nginx_site argument order so simai-nginx-template/public_dir are stored properly in metadata; SSL regenerate/remove now preserves public_dir.
- Split site drift checks from contract doctor to remove command collision (doctor = read-only profile diagnostics; drift = metadata/cron drift with optional fixes).

## [1.5.0] - 2026-01-08
### Added
- Profile-driven DOCROOT via `PROFILE_PUBLIC_DIR` (including empty/"." for project root) and new nginx placeholders `{{DOC_ROOT}}`/`{{ACME_ROOT}}`; nginx metadata now records `simai-public-dir` (meta v2).
### Fixed
- SSL certbot webroot and healthcheck placement now follow the profile docroot instead of assuming `/public`.
- Site doctor validates docroot using profile/metadata and reports mismatches safely.

## [1.4.6] - 2026-01-08
### Fixed
- Fixed `site_nginx_metadata_parse` to reliably populate associative array outputs, enabling strict metadata-based commands (e.g., cron add/remove) to work correctly.
- Improved cron command guidance when nginx site metadata is missing or incomplete (diagnostics + manual metadata restore).

## [1.4.5] - 2026-01-08
### Fixed
- Made `cron add/remove` strict: require complete nginx site metadata (slug/profile/root/php) and never guess values.
- Cron removal now verifies SIMAI-managed headers (slug/domain) before deleting `/etc/cron.d/<slug>`.

## [1.4.4] - 2026-01-07
### Fixed
- Made cron detection and migration use site metadata slug as the source of truth.
- Updated `cron add` to generate `/etc/cron.d/<slug>` via the canonical renderer with real domain headers; removed misleading project-as-domain headers.

## [1.4.3] - 2026-01-07
### Fixed
- Fixed legacy crontab marker detection by using POSIX whitespace classes in regex, ensuring marked blocks are found reliably.
- Made doctor cron migration safer by requiring complete metadata before creating cron.d or removing legacy entries (no fallback guessing).

## [1.4.2] - 2026-01-07
### Fixed
- Made legacy crontab cleanup safe: only removes clearly delimited SIMAI-managed BEGIN/END blocks and never deletes unrelated entries.
- Unified legacy cron detect/remove helpers reused by doctor and site removal; unmarked legacy lines now warn without changes.
- Aligned doctor documentation with actual safe behavior; installer cron cleanup now targets the correct `/etc/cron.d/<slug>` file.

## [1.4.1] - 2026-01-06
### Fixed
- Fixed runtime errors in cron helpers and nginx metadata rendering used by installer/admin.
- Unified site cron management to `/etc/cron.d` and removed conflicting legacy cron updates.
- Stabilized alias metadata and SSL regeneration to use correct templates/socket projects.
- Made site doctor metadata repairs safe (no guessing) by relying only on reliable config extraction.

## [1.4.0] - 2026-01-06
### Added
- Standardized Nginx site metadata (`# simai-*`) as the single source of truth; doctor can upsert when missing.
- Unified site cron management via `/etc/cron.d/<slug>` with doctor planning/migration from legacy crontab blocks.
### Changed
- Site lifecycle (add/set-php/ssl/install/remove) now writes canonical metadata headers and manages cron via cron.d; doctor reports/fixes metadata/cron drift safely.

## [1.3.5] - 2026-01-06
### Changed
- Renamed menu item “Self bootstrap” to “Repair Environment …” for clarity.
### Fixed
- Self update no longer drops the user into a shell; menu reload is now safe with fallback on failure.

## [1.3.4] - 2026-01-06
### Fixed
- Ensured install/update scripts refuse to run on unsupported OS (including Ubuntu 20.04) before any changes are made.
- Updated repository documentation and instructions to reflect supported OS: Ubuntu 22.04/24.04.

## [1.3.3] - 2026-01-06
### Changed
- Dropped Ubuntu 20.04 support. Supported OS: Ubuntu 22.04/24.04. Installation and maintenance commands now refuse to run on Ubuntu 20.04.

## [1.3.2] - 2026-01-06
### Fixed
- Resolved ShellCheck warnings across scripts (quoting, safe expansions, robust helpers) without altering runtime behavior.
- Made ShellCheck warning-level checks blocking in CI to prevent regressions.

## [1.3.1] - 2026-01-06
### Fixed
- Unified Laravel queue systemd unit naming/paths across site and queue commands (use shared helpers).
- Made `cache clear` use strict php-cli resolution to prevent running artisan with an unexpected PHP version.

## [1.3.0] - 2026-01-05
### Added
- Implemented queue management commands (status/restart) for Laravel sites via systemd units.
- Implemented cache command for Laravel sites (artisan-based), with safe profile checks and clear guidance for non-Laravel profiles.
### Fixed
- Replaced queue/cache stubs with functional implementations and improved operator UX.

## [1.2.1] - 2026-01-05
### Fixed
- Backup import is now strictly non-interactive: blocks PHP-required sites if PHP version is missing in backup metadata.
- Backup inspect/import now report SSL presence from backup metadata (manual setup required).
- Backup import plan notes now distinguish DB required vs optional; profile enabling is deduplicated.

## [1.2.0] - 2026-01-05
### Added
- Backup import/inspect commands: plan/apply config-only bundles without touching DB/secrets/SSL; import skips existing sites, auto-enables needed profiles, and respects alias/target order.
### Changed
- `site add`: alias target can be set non-interactively with `--target-domain`; required markers are rechecked after bootstrap for new/empty dirs; required-DB profiles can be created without DB only via `--skip-db-required yes` (for migrations).

## [1.1.6] - 2026-01-05
### Fixed
- Prevented MySQL root password exposure via process argv by removing mysql `-p<pass>` usage; root credentials are now supplied via safe environment during detection and execution.

## [1.1.5] - 2026-01-04
### Fixed
- Eliminated mysql `-e` usage with credentials in `simai-env.sh` by piping SQL via stdin to avoid password exposure in argv.
- `site remove` DB teardown now handles drop-db/drop-user independently, and `site_db_apply_drop` skips empty names and drops localhost/127.0.0.1 (and legacy `%`) variants safely.
- Shared DB drop helper hardened to avoid partial drops when inputs are missing.

## [1.1.4] - 2026-01-04
### Fixed
- Prevented DB password exposure by switching all MySQL calls to stdin execution and unifying DB lifecycle via db.env for site add/remove.
- `site add`/`remove` now use db.env for create/drop and export creds idempotently to project `.env` when requested.
- Doctor and docs updated to reflect db.env source of truth and safe exports.

## [1.1.3] - 2026-01-03
### Fixed
- DB env helpers moved to shared libs (no cross-command sourcing dependency).
- Clarified sites config directory helper (no longer overloaded as "php ini dir").
- Legacy `db` commands no longer expose passwords via process arguments.

## [1.1.2] - 2026-01-03
### Added
- `site db-export`: safely writes DB credentials from `/etc/simai-env/sites/<domain>/db.env` into project `.env` (idempotent, no password logging).

## [1.1.1] - 2026-01-03
### Fixed
- `site db-create`: uses profile privilege variable `PROFILE_DB_REQUIRED_PRIVILEGES` (profile-aware privileges now work).
- DB operations now check MySQL command results and rollback on failures to avoid partial states.
- DB user passwords are no longer exposed in process arguments (SQL sent via stdin, not mysql -e).

## [1.1.0] - 2026-01-03
### Added
- Per-site database management: `site db status/create/drop/rotate`, with dry-run, safe credential storage, and profile-aware defaults (charset/collation/privileges).

## [1.0.3] - 2026-01-03
### Fixed
- Per-site PHP ini apply: validates and deduplicates overrides read from `/etc/simai-env/sites/<domain>/php.ini` and avoids unnecessary pool rewrites/reloads when no changes are required.

## [1.0.2] - 2026-01-03
### Fixed
- Per-site PHP ini apply: `simai-site-ini-*` block now writes real newlines (not literal '\n'), allowing php-fpm config tests to pass.
- `site php-ini-*` menu: selected domain is properly stored in parsed args to avoid false "Missing required options".

## [1.0.1] - 2026-01-03
### Added
- Per-site PHP ini overrides: stored in `/etc/simai-env/sites/<domain>/php.ini` and applied to pools via managed `simai-site-ini-*` blocks (profile block remains higher priority).
### Changed
- `site set-php` reapplies stored per-site PHP ini overrides when creating a new pool.

## [1.0.0] - 2026-01-03
### Milestone
- Stable profile-driven environment and admin CLI: site lifecycle (`site add/remove/set-php/doctor/fix`), safe removals (`site remove --dry-run`), PHP management (`php install`), and profile activation controls (enable/disable/init, allowlist defaults on fresh install/repair).

## [0.9.9] - 2026-01-03
### Changed
- Core profiles reduced to `static`, `generic`, `alias` (Laravel is no longer enabled/protected by default; enable it explicitly when needed).

## [0.9.8] - 2026-01-03
### Added
- Interactive PHP selection in `site add` / `site set-php` now offers supported versions (8.1–8.4) and can install missing versions on-the-fly in menu mode with user confirmation.
### Documentation
- Updated site/php command docs to reflect interactive install prompts.

## [0.9.7] - 2026-01-03
### Added
- Fresh install/repair now initializes profile activation allowlist with core profiles only when no simai-managed sites exist.
### Fixed
- No behavior change on updates: if allowlist exists or sites exist, activation remains unchanged.

## [0.9.6] - 2026-01-03
### Fixed
- Profile commands: corrected required/optional option registration so interactive menu prompts for needed parameters.
- `site add` menu: default profile selection now always chooses an enabled profile (no fallback to disabled generic).

## [0.9.5] - 2026-01-03
### Added
- Profile activation management: list/enable/disable/init/used-by, with a safe allowlist at `/etc/simai-env/profiles.enabled`.
- `site add` now shows only enabled profiles (legacy mode: all profiles enabled if no allowlist exists).

## [0.9.4] - 2026-01-03
### Fixed
- Fixed a bash syntax error in `admin/lib/profile_apply.sh` that prevented `simai-admin.sh` from running.

## [0.9.3] - 2026-01-03
### Fixed
- `profile validate`: correctly reads and validates `PROFILE_PUBLIC_DIR`.
- `validate_profile_file`: allows `<`/`>` inside quoted values while still blocking redirections and command separators outside quotes.

## [0.9.2] - 2026-01-03
### Fixed
- `profile validate`: hardened safety (no executable constructs), correct nginx template resolution under `templates/`, and alias template exception.
### Documentation
- Aligned profile how-to with template filename contract.

## [0.9.1] - 2026-01-03
### Added
- `profile validate` command to lint and verify profile files (required fields, allowed values, template presence).
### Documentation
- Added a step-by-step guide for creating profiles.

## [0.9.0] - 2026-01-03
### Milestone
- Profile-driven site lifecycle is now stable: `site add/remove/set-php/doctor/fix`, plus safe `site remove --dry-run` and `php install`.

## [0.8.24] - 2026-01-02
### Fixed
- `php install` no longer adds ondrej/php repo or runs apt operations in CLI without `--confirm yes` when installation is needed.
- `php install` skips repo ensuring when no packages are missing (already installed path).
- CHANGELOG restored to reverse chronological order.

## [0.8.23] - 2026-01-02
### Fixed
- `php install` now always runs php-fpm<ver> -t using the real binary path and fails when php-fpm is missing.
- `php install` no longer hides systemctl start failures and supports partial installs by adding missing packages.

## [0.8.22] - 2026-01-02
### Added
- `php install` command to install a PHP version (FPM/CLI + base extensions) with safe confirmation and post-install checks.
### Documentation
- Added `docs/commands/php.md` describing PHP management commands.

## [0.8.21] - 2026-01-02
### Added
- `site remove --dry-run yes` to preview removal actions without making changes (plan-only).
### Changed
- Menu removal flow now defaults to showing a plan first and then asks whether to proceed.

## [0.8.20] - 2026-01-02
### Fixed
- `site fix` no longer hides apt/php-fpm reload failures; long operations show progress and failures abort correctly.
- PHP-FPM pool ini block updates are now atomic and restore on test failure.
### Improved
- Added a consistent `site fix` summary (plan vs apply results).

## [0.8.19] - 2026-01-02
### Added
- `site fix` command (plan-by-default) to install missing PHP extensions and apply profile-required PHP INI overrides via a managed pool block.
### Changed
- Documentation extended with `site fix` and profile fields usage for fixer.

## [0.8.18] - 2026-01-02
### Fixed
- `site set-php` now correctly refreshes cron and updates queue unit for profiles that support them (supports flags loaded after profile load).
- CHANGELOG restored to reverse chronological order.
### Improved
- `site remove` summary reports files as skipped for alias profiles.

## [0.8.17] - 2026-01-02
### Fixed
- `site remove` no longer allows file/DB destructive operations for alias profiles (prevents accidental target deletion).
- `site set-php` refreshes cron (and updates queue unit when present) for profiles that support them.
### Improved
- Removed duplicate progress step counters in CLI output.
- Synced command option lists with actual handlers.

## [0.8.16] - 2026-01-02
### Changed
- `site set-php` is now profile-driven (respects requires_php, allowed versions, and allow_php_switch).
- `site remove` is now profile-driven (skips irrelevant prompts/actions for static/alias; safer removal flow).

## [0.8.15] - 2026-01-02
### Fixed
- `site doctor` now uses a safe fallback slug for derived paths when metadata slug is invalid, reducing noisy false negatives.
- Healthcheck location detection is now exact for nginx/php modes.
### Improved
- Extension install hints now include php reload command.

## [0.8.14] - 2026-01-02
### Fixed
- `site doctor` writable paths are now checked as SIMAI_USER (correct under root).
- Fixed numeric ini comparisons in doctor; added forbidden ini checks.
- Healthcheck validation now enforces local-only allow/deny for php/nginx modes.
### Changed
- Alias `--include-target` performs a partial target inspection without recursion.
- Updated profile spec docs with doctor-related fields.

## [0.8.13] - 2026-01-02
### Added
- New read-only `site doctor` command to diagnose a site against its profile contract (fs/nginx/php/cron/ssl/db) with PASS/WARN/FAIL reporting.
### Changed
- Hardened validations leveraged by doctor: strict project slug/path checks and safer cron/db handling are reused across diagnostics.

## [0.8.12] - 2026-01-02
### Changed
- Hardened site creation/removal with project slug validation, stricter path validation, and DB name/user checks; cron paths are safely escaped.
- Profile-driven healthcheck mode added (php vs nginx); static now uses nginx-served `/healthcheck` and summaries/docs reflect it.
- `.env` files now enforce chmod 640 after generation; installer/admin validation rejects unsafe slugs/paths before applying changes.

## [0.8.11] - 2026-01-02
### Changed
- site add now applies profile contracts (nginx template, markers, bootstrap, PHP/DB/healthcheck/cron) via the registry instead of hardcoded branches.
- Added profile fields for nginx template and required markers across docs/specs and profile definitions.
- simai-env.sh help clarifies the `<project-root>` placeholder.

## [0.8.10] - 2026-01-02
### Changed
- Unified placeholders across docs, GitHub instructions, and simai-env.sh help to use `<domain>/<project-root>/<project-slug>`; webroot explicitly `<project-root>/public`.
- Hardened profile file validation (allows arrays, blocks unsafe expansions/substitutions); profile restrictions documented.
- Documentation now consistently reflects slug-based IDs (pool/cron/unit/socket/log) and correct static healthcheck description.

## [0.8.9] - 2026-01-02
### Added
- Hardened profile registry validation and documentation; added architecture/development docs for templates/metadata and consistent path model.
### Changed
- Menu profile ordering uses the registry (generic, laravel, static, alias first); static site summary shows healthcheck disabled.
## [0.8.8] - 2026-01-02
### Added
- Architecture documentation section (`docs/architecture/*`, `docs/development/*`, `docs/README.md`) capturing profiles, lifecycle, security, logging, and release process.
- Declarative profile registry (`profiles/*.profile.sh`) with loader helpers.
### Changed
- Menu profile selection and CLI validation now use the profile registry (fallback to defaults only if registry is empty).

## [0.8.7] - 2025-12-31
### Changed
- site remove is now profile-aware: static/alias sites no longer prompt for DB/user drops, and CLI rejects DB drop flags for those profiles; summaries show DB actions as skipped for static/alias.

## [0.8.6] - 2025-12-31
### Changed
- db drop no longer assumes user=db_name; requires explicit --user in non-interactive mode, with interactive prompt fallback.
- Added README note about quoting passwords containing `!` to avoid bash history expansion.

## [0.8.5] - 2025-12-31
### Added
- DB commands (create/drop/set-pass) implemented with safe MySQL root detection, validation, and progress steps.

## [0.8.4] - 2025-12-31
### Added
- Installer prints a retro “SIMAI ENV” banner at startup (interactive terminals only, with safe fallback for narrow/non-UTF-8 environments).

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
- Added OS compatibility preflight with clear TTY status output (legacy support at the time: Ubuntu 20.04/22.04/24.04), shared via platform helpers and used before bootstrap/update/install.
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

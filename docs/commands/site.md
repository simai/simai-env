# site commands

Run with `sudo /root/simai-env/simai-admin.sh site <command> [options]` or via menu.

## add
Create nginx vhost and project root for an existing path.

Options:
- `--domain` (required)
- `--project-name` (optional; derived from domain if missing)
- `--path` (optional; default uses path style under `/home/simai/www/`)
- `--path-style` (`slug`|`domain`) controls default path when `--path` is not set. Default is `domain` (e.g., `/home/simai/www/your-domain.tld`). Use `--path-style slug` to restore legacy slug paths or set `/etc/simai-env.conf` with `SIMAI_DEFAULT_PATH_STYLE=domain|slug`. Menu does not prompt for path style; domain-based default is used unless overridden via CLI/config.
- `--profile` selects site type; profiles are defined declaratively in `profiles/*.profile.sh`. Supported: `generic`, `laravel`, `static`, `alias` (default `generic`).
- `--host-mode standard|wildcard` controls whether the site serves only the main domain or the main domain plus all first-level subdomains. Default is `standard`.
- `--wildcard-domain` (optional) overrides the wildcard hostname stored in metadata for `--host-mode wildcard`. Default is `*.your-domain.tld`.
- `--usage` selects a user-facing activity class: `standard` (default), `high-traffic`, or `rarely-used`. simai-env maps this to the internal performance mode automatically.
- `--target-domain` (alias only) set target non-interactively; required in CLI for alias when not in menu.
- `--php` (optional; choose from installed if omitted; in menu the selector shows only installed versions that are compatible with the chosen profile)
- SSL (optional): `--ssl=ask|yes|no`, `--ssl-email`, `--ssl-redirect=yes|no`, `--ssl-hsts=yes|no`, `--ssl-staging=yes|no`
- DB (optional): `--create-db=yes|no` (alias: `--db=yes|no`), `--db-name`, `--db-user`, `--db-pass` (defaults from project; password generated), `--db-export=yes|no` (export to project `.env`; default yes for required DB profiles, no otherwise), `--skip-db-required=yes|no` (default `no`; allow required-DB profiles to be created without DB — for migration only, emits warning)

Behavior:
- Generic uses placeholder and profile-driven docroot (`PROFILE_PUBLIC_DIR`, default `public`); Laravel requires `artisan`. Static is nginx-only (no PHP/DB) with `index.html` placeholder under docroot and nginx-served `/healthcheck` (local-only). Alias points the domain to an existing site (reuses its root, no DB/pool creation).
- Creates PHP-FPM pool and nginx vhost for non-static profiles; installs `healthcheck.php` into the profile docroot when the profile healthcheck mode is `php`.
- `--host-mode wildcard` makes nginx serve both the main domain and all first-level subdomains by writing `server_name <domain> *.domain` and storing the host mode in metadata.
- When a wildcard-host site is created, the summary now prints the DNS records the user needs to create:
  - `<domain> -> A -> <server-ip>`
  - `*.domain -> A -> <server-ip>`
- The same summary and `site info` also print the next wildcard HTTPS step for the currently supported DNS provider flow (Cloudflare DNS challenge).
- If `create-db=yes` (or `db=yes`), creates DB/user and stores creds in `/etc/simai-env/sites/<domain>/db.env` (0640 root:root); for `generic`, exports to `<project>/.env` idempotently; for required DB profiles, `.env` export stays enabled by default and menu no longer asks a separate technical question about it. Required-DB profiles can be created without DB only when `--skip-db-required yes` is supplied (intended for migration); create DB later via `site db-create`.
- If `--ssl=yes`, `site add` issues a Let's Encrypt certificate after the site is created. SSL issuance is best-effort: site creation still succeeds if cert issuance fails. In menu mode, when `--ssl` is not supplied explicitly, the site creation flow now asks whether to issue Let's Encrypt and requests an email if needed. In non-menu CLI, `--ssl=ask` behaves as `no`.
- After creation, the summary prints profile-aware `Next steps` so the user can move directly to the expected installer or finalize flow.
- After creation, simai-env automatically stores the selected activity class in `/etc/simai-env/sites/<domain>/perf.env` and applies the mapped site-level performance mode:
  - `standard` -> `balanced`
  - `high-traffic` -> `aggressive`
  - `rarely-used` -> `parked`
- Central SSL defaults can be defined in `/etc/simai-env.conf`:
  - `SIMAI_SSL_AUTO_ISSUE_ON_CREATE=ask|yes|no`
  - `SIMAI_SSL_LE_EMAIL_DEFAULT=<email>`
  - `SIMAI_SSL_REDIRECT_DEFAULT=yes|no`
  - `SIMAI_SSL_HSTS_DEFAULT=yes|no`
  - `SIMAI_SSL_STAGING_DEFAULT=yes|no`
  Example:
  ```bash
  SIMAI_SSL_AUTO_ISSUE_ON_CREATE=ask
  SIMAI_SSL_LE_EMAIL_DEFAULT=ops@example.com
  SIMAI_SSL_REDIRECT_DEFAULT=yes
  SIMAI_SSL_HSTS_DEFAULT=no
  SIMAI_SSL_STAGING_DEFAULT=no
  ```
 - For static profile, `--php` and DB flags are ignored (with warnings); no PHP-FPM pool or cron is created.
- Project ID (slug) is still used for pools/cron/queue/sockets/logs even if the path style uses the domain.
- `site info` and `site list` show the site host mode and wildcard hostname when enabled.
- `site info` for wildcard-host sites also shows:
  - the DNS records to create
  - the wildcard HTTPS command to run after DNS is ready
 - If an existing slug/domain directory is found, the tool reuses it to avoid duplicates and warns accordingly.
- Required markers: if the directory is newly created or empty, missing markers do not block immediately; bootstrap files are applied first, then markers are rechecked. On non-empty directories without markers, CLI errors (menu can still fallback to generic).
- `/healthcheck.php` is localhost-only by default for php-mode profiles; test with `curl -i -H "Host: <domain>" http://127.0.0.1/healthcheck.php`. Static uses nginx-mode healthcheck at `/healthcheck` (local-only).
- Web root is profile-driven (`PROFILE_PUBLIC_DIR`, empty/"." means project root).

Examples:
- Create without TLS: `simai-admin.sh site add --domain example.com --profile generic --php 8.3`
- Create and issue TLS immediately: `simai-admin.sh site add --domain example.com --profile generic --php 8.3 --ssl yes --ssl-email ops@example.com`
- Create one site for domain plus subdomains: `simai-admin.sh site add --domain obr.site --profile generic --host-mode wildcard`

## remove
Remove site resources (profile-driven; no fixes on target data unless confirmed).

Options:
- `--domain`
- `--project-name`
- `--path`
- `--remove-files` (`yes|no`)
- `--drop-db` (`yes|no`, default DB name from project)
- `--drop-db-user` (`yes|no`, default user from project)
- `--db-name`, `--db-user`
- `--dry-run` (`yes|no`, default `no`; when `yes`, plan-only and no confirm needed)

Behavior:
- Dry-run mode (`--dry-run yes` or menu “Plan only”) prints what *would* be removed and exits without changes (no confirm needed).
- Apply mode removes nginx vhost/symlink (with nginx -t before reload; restores if test fails).
- PHP/cron/queue removal only when the profile requires PHP (alias/static skip automatically; cron removal is profile-gated).
- DB prompts only when `PROFILE_REQUIRES_DB != no`; static/alias skip DB prompts entirely. DB drop flags are errors for such profiles even in dry-run.
- File removal and DB/user drops happen only when explicitly confirmed (defaults to “no” in CLI; menu asks). Uses safe fallback slug for derived paths when metadata is invalid.
- Alias profile: refuses file/DB removal flags and ignores path overrides (manage on the target site instead).

### Destructive operations and `--confirm`
In non-menu mode, `--confirm yes` is required only when any destructive flags are set:
- `--remove-files yes`
- `--drop-db yes`
- `--drop-db-user yes`

Examples:
- Dry-run (plan): `simai-admin.sh site remove --domain <domain> --dry-run yes`
- Dry-run with flags (still plan-only): `simai-admin.sh site remove --domain <domain> --remove-files yes --drop-db yes --dry-run yes`
- Apply destructive removal (confirm required in CLI): `simai-admin.sh site remove --domain <domain> --remove-files yes --confirm yes`

## list
List domains from nginx sites-available with profile, PHP version, root/alias target, and brief SSL status (off/LE:YYYY-MM-DD/custom).

## info
Show the main site card for one domain.

Options:
- `--domain` (required outside menu)

Output includes:
- domain, profile, project, slug
- host mode and hostnames
- root/docroot
- nginx enabled state
- nginx conf path
- expected nginx log paths
- healthcheck endpoint
- PHP and socket/pool details
- SSL summary plus redirect/HSTS hints
- scheduler file state
- worker unit state
- activity class and plain-language optimization recommendation

This is the command used by `Sites -> Site info`.

## set-php
Switch site to a different PHP version (profile-driven).

Options:
- `--domain` (required; aliases are not allowed)
- `--php` (target version; menu lets you pick supported versions 8.1–8.4 and optionally install if missing; CLI still requires it installed)
- `--keep-old-pool` (`yes|no`, default `no`; if `no`, removes old PHP-FPM pool)

Behavior:
- Loads the profile from nginx metadata; refuses when `PROFILE_REQUIRES_PHP=no`, `PROFILE_IS_ALIAS=yes`, or `PROFILE_ALLOW_PHP_SWITCH=no`.
- Enforces `PROFILE_ALLOWED_PHP_VERSIONS` when set (only installed+allowed versions are accepted).
- Recreates PHP-FPM pool for the target version, patches nginx upstream sockets in-place, validates with `nginx -t`, then reloads nginx/php-fpm. Socket/pool naming uses a safe fallback slug when metadata is invalid.
- Laravel/queue profiles keep their cron/unit wiring; `--keep-old-pool=yes` preserves the previous pool, otherwise it is removed.

## perf-status
Show per-site runtime governance and PHP-FPM pool footprint.

Options:
- `--domain` (required outside menu)

Output includes:
- activity class and its mapped governance baseline
- human-readable optimization posture (`automatic`, `manual`, `paused`)
- a plain-language recommendation based on current runtime state and server pressure
- profile and PHP version
- current pool mode / children / request limits
- current request timeout
- memory limit and a best-effort memory risk estimate
- opcache / redis extension presence
- cron / queue footprint summary

## perf-tune
Apply per-site PHP-FPM governance mode.

Options:
- `--domain` (required outside menu)
- `--mode` (`parked|safe|balanced|aggressive`, default `balanced`)
- `--confirm` (`yes|no`, default `no`; required outside menu)

Behavior:
- Stores managed site-level performance settings in `/etc/simai-env/sites/<domain>/perf.env`.
- Applies a managed `simai-site-perf-*` block to the current PHP-FPM pool.
- Keeps existing `site php-ini` and profile-managed INI blocks intact.
- Validates php-fpm config before reload and restores the previous pool on failure.

## usage-status
Show the simple user-facing activity class for a site.

Options:
- `--domain` (required outside menu)

Output includes:
- activity class (`standard`, `high-traffic`, `rarely-used`)
- human-readable optimization posture
- mapped internal performance mode
- a plain-language recommendation
- current runtime state

## usage-set
Set the simple user-facing activity class for a site.

Options:
- `--domain` (required outside menu)
- `--class` (`standard|high-traffic|rarely-used`)
- `--confirm` (`yes|no`, default `no`; required outside menu)

Behavior:
- Stores `usage_class` in `/etc/simai-env/sites/<domain>/perf.env`.
- Automatically maps the class to the internal mode:
  - `standard` -> `balanced`
  - `high-traffic` -> `aggressive`
  - `rarely-used` -> `parked`
- Applies the mapped pool governance immediately for PHP sites.
- Non-PHP profiles still store the usage class so future tooling can respect the same user intent.

## auto-optimize-status
Show whether a site participates in automatic optimization.

Options:
- `--domain` (required outside menu)

Output includes:
- effective automatic optimization state
- current site-level override (`inherit`, `yes`, `no`)
- usage class and mapped performance mode
- runtime state

## auto-optimize-enable / auto-optimize-disable / auto-optimize-reset
Control the per-site automatic optimization override.

Options:
- `--domain` (required outside menu)
- `--confirm` (`yes|no`, default `no`; required outside menu)

Behavior:
- Stores `auto_optimize` in `/etc/simai-env/sites/<domain>/perf.env`.
- `enable` forces the site to participate in automatic optimization when the global scheduler job is enabled.
- `disable` excludes the site from scheduler-driven `auto` rebalance actions.
- `reset` removes the explicit decision and returns the site to the global default (`inherit`).
- Manual commands like `site perf-tune` still work even when automatic optimization is disabled for the site.

## runtime-status
Show whether a site runtime is active or suspended.

Options:
- `--domain` (required outside menu)

Output includes:
- runtime state (`active` / `suspended`)
- PHP pool state
- cron file state
- queue unit state

## runtime-suspend
Suspend a site runtime without deleting the site.

Options:
- `--domain` (required outside menu)
- `--confirm` (`yes|no`, default `no`; required outside menu)

Behavior:
- Disables the site PHP-FPM pool by moving it out of active `pool.d`.
- Adds a managed nginx `503 Site is parked by simai-env` block while keeping ACME validation reachable.
- Disables site cron/queue where the profile uses them.
- Stores runtime state in `/etc/simai-env/sites/<domain>/runtime.env`.

## runtime-resume
Resume a previously suspended site runtime.

Options:
- `--domain` (required outside menu)
- `--confirm` (`yes|no`, default `no`; required outside menu)

Behavior:
- Restores the disabled PHP-FPM pool.
- Removes the managed nginx suspend block.
- Re-enables cron/queue if they were disabled by `runtime-suspend`.

## fix
Plan or apply profile-required PHP fixes (PHP extensions and PHP INI overrides). Defaults to plan-only (no changes).

Options:
- `--domain` (required outside menu)
- `--apply` (`none|php-ext|php-ini|all`, default `none`)
- `--include-recommended` (`yes|no`, default `no`)
- `--confirm` (`yes|no`, default `no`; required in non-menu mode when `--apply != none`)

Behavior:
- Validates domain/path/profile; refuses alias/static (`PROFILE_IS_ALIAS=yes` or `PROFILE_REQUIRES_PHP=no`) or sites without PHP metadata.
- Plans missing PHP extensions (required; recommended when `--include-recommended=yes`) and INI entries (required; recommended when flag is on).
- Apply modes:
  - `php-ext`: install missing extensions via mapped apt packages, then reload php-fpm (config test skipped if binary absent); fails when required extensions remain missing.
- `php-ini`: write managed pool block (`; simai-profile-ini-begin/end`) with required (and optional recommended) INI overrides, php-fpm config test, reload on success; restores backup if test fails.
- `all`: both of the above.
- Non-menu apply requires `--confirm yes`; menu prompts for apply mode and whether to include recommended items.

Examples:
- Plan only: `simai-admin.sh site fix --domain example.com`
- Apply missing required extensions: `simai-admin.sh site fix --domain example.com --apply php-ext --confirm yes`
- Apply extensions + INI including recommended: `simai-admin.sh site fix --domain example.com --apply all --include-recommended yes --confirm yes`

## doctor
Diagnose a site against its profile contract (read-only; no fixes applied).

Options:
- `--domain` (required outside menu)
- `--strict` (`yes|no`, default `no`) – exit non-zero on FAIL when `yes`
- `--include-target` (`yes|no`, default `yes`) – for alias, run a partial (non-recursive) target inspection with prefixed results

Checks (non-destructive):
- Filesystem: root/docroot, markers, bootstrap files, writable paths, .env permissions
- nginx: config/symlink presence, healthcheck policy vs profile, `nginx -t`
- PHP: version installed, php-fpm service/pool/socket, required/recommended extensions, INI expectations
- Cron: `/etc/cron.d/<project-slug>` when profile enables cron
- SSL: cert files present when metadata says ssl=on
- DB: mysql service presence when profile requires DB; `.env` presence for required DB profiles
- Alias profiles: when `--include-target=yes`, performs a prefixed partial check of the target site (root/docroot/markers/healthcheck/nginx/php service/pool/socket) without recursion

Output: PASS/WARN/FAIL per check with hints; no secrets are shown.

## Per-site PHP ini overrides
- Overrides are stored at `/etc/simai-env/sites/<domain>/php.ini` and applied as a managed pool block `simai-site-ini-*` (profile-managed `simai-profile-ini-*` stays last and has higher priority).
- Commands:
  - `simai-admin.sh site php-ini-set --domain example.com --name memory_limit --value 512M --apply yes --confirm yes`
  - `simai-admin.sh site php-ini-unset --domain example.com --name memory_limit --apply yes --confirm yes`
  - `simai-admin.sh site php-ini-list --domain example.com`
  - `simai-admin.sh site php-ini-apply --domain example.com --confirm yes`

## Profile selection
- The admin menu lists profiles from the registry `profiles/*.profile.sh`; default ordering: `generic`, `laravel`, `static`, `alias`.
- CLI `--profile` must match a registered profile; registry is declarative only (no executable logic).
- **doctor**: `simai-admin.sh site doctor --domain <domain> [--strict yes|no] [--include-target yes|no]`  
  Read-only contract diagnostic: checks profile validity, filesystem/docroot, nginx healthcheck policy, PHP/cron/SSL/DB expectations. No fixes applied. Use `--strict yes` to exit non-zero on FAIL.
- **drift**: `simai-admin.sh site drift --domain <domain> [--fix yes]`  
  Checks metadata/cron drift; `--fix yes` can migrate marked legacy cron blocks to `/etc/cron.d/<slug>` (safe markers only). Does not auto-fix metadata/DB/files/SSL.

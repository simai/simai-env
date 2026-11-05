# site commands

Run with `sudo /root/simai-env/simai-admin.sh site <command> [options]` or via menu.

## add
Create nginx vhost and project root for an existing path.

Options:
- `--domain` (required)
- `--project-name` (optional; derived from domain if missing)
- `--path` (optional; default uses path style under `/home/simai/www/`)
- `--path-style` (`slug`|`domain`) controls default path when `--path` is not set. Default is `domain` (e.g., `/home/simai/www/your-domain.tld`). Use `--path-style slug` to restore legacy slug paths or set `/etc/simai-env.conf` with `SIMAI_DEFAULT_PATH_STYLE=domain|slug`. Menu does not prompt for path style; domain-based default is used unless overridden via CLI/config.
- `--profile` selects site type; profiles are defined declaratively in `profiles/*.profile.sh`. Bundled: `generic`, `laravel`, `static`, `alias`, `wordpress`, `bitrix`, `node`, `redirect`, `proxy` (default `generic`); `self profiles` lists the enabled ones with their arguments.
- `--host-mode standard|wildcard` controls whether the site serves only the main domain or the main domain plus all first-level subdomains. Default is `standard`.
- `--wildcard-domain` (optional) overrides the wildcard hostname stored in metadata for `--host-mode wildcard`. Default is `*.your-domain.tld`.
- `--frame-policy same-origin|any` controls whether browsers may embed the site in an iframe. The safe default is `same-origin`; use `any` only for a dedicated embedded application endpoint.
- `--usage` selects a user-facing activity class: `standard` (default), `high-traffic`, or `rarely-used`. simai-env maps this to the internal performance mode automatically.
- `--target-domain` (alias only) set target non-interactively; required in CLI for alias when not in menu.
- `--php` (optional; choose from installed if omitted; in menu the selector shows only installed versions that are compatible with the chosen profile)
- SSL (optional): `--ssl=ask|yes|no`, `--ssl-email`, `--ssl-redirect=yes|no`, `--ssl-hsts=yes|no`, `--ssl-staging=yes|no`
- DB (optional): `--create-db=yes|no` (alias: `--db=yes|no`), `--db-name`, `--db-user`, `--db-pass` (defaults from project; password generated), `--db-export=yes|no` (export to project `.env`; default yes for required DB profiles, no otherwise), `--skip-db-required=yes|no` (default `no`; allow required-DB profiles to be created without DB — for migration only, emits warning)
- Access (optional): `--access-create=yes|no`, `--access-login`, `--access-password` (create project-scoped SFTP access after site creation; menu prompts when omitted)
- Backups: `--backup yes|no` (default `yes`): a new site gets the daily data backup with the `backup data-schedule` defaults (03:30, keep 7); redirect, proxy and alias sites never do. `site remove` drops the schedule and keeps the backups already taken.
- Reverse proxy (profile `proxy`): `--upstream-port P` (required; a service on 127.0.0.1, never 80 or 443), `--upstream-path /` (the path requests are passed to), `--websockets yes|no` (default `no`; `yes` passes WebSocket upgrades and keeps them open for an hour). Nothing outside the host is reachable. Settings live in `/etc/simai-env/sites/<domain>/proxy.env`; certificates still renew over http-01 in front of the service. Proxy sites get no daily backup (they hold no data). Enable the profile first: `profile enable --id proxy`.
- Bitrix helper files (Bitrix profile only): `--bitrix-files=none|setup|restore`. Default is `none` so new Bitrix sites do not expose public installer/restore scripts until the operator chooses the required flow.

Behavior:
- Generic uses placeholder and profile-driven docroot (`PROFILE_PUBLIC_DIR`, default `public`); Laravel requires `artisan`. Static is nginx-only (no PHP/DB) with `index.html` placeholder under docroot and nginx-served `/healthcheck` (local-only). Alias points the domain to an existing site (reuses its root, no DB/pool creation).
- Creates PHP-FPM pool and nginx vhost for non-static profiles; installs `healthcheck.php` into the profile docroot when the profile healthcheck mode is `php`.
- `--host-mode wildcard` makes nginx serve both the main domain and all first-level subdomains by writing `server_name <domain> *.domain` and storing the host mode in metadata.
- When a wildcard-host site is created, the summary now prints the DNS records the user needs to create:
  - `<domain> -> A -> <server-ip>`
  - `*.domain -> A -> <server-ip>`
- The same summary and `site info` also print the next wildcard HTTPS step for the currently supported DNS provider flow (Cloudflare DNS challenge).
- If `create-db=yes` (or `db=yes`), creates or reuses the managed DB/user for the site and stores creds in `/etc/simai-env/sites/<domain>/db.env` (0640 root:root); for `generic`, exports to `<project>/.env` idempotently; for required DB profiles, `.env` export stays enabled by default and menu no longer asks a separate technical question about it. In menu mode, DB setup now offers a clearer branch between creating a managed DB now and continuing without DB setup. Required-DB profiles can still be created without DB only when `--skip-db-required yes` is supplied in CLI (intended for migration); create DB later via `site db-create`.
- For Bitrix profile, `site add` asks in menu mode whether to prepare public helper files:
  - `none`: create only infrastructure; no `bitrixsetup.php` or `restore.php` is added.
  - `setup`: download current `bitrixsetup.php` from the official Bitrix URL and write DB preseed files when managed DB credentials exist.
  - `restore`: download current `restore.php` from the official Bitrix URLs, prepare restore-writable paths, and write `.settings.php` plus connection initialization from managed DB credentials without creating a premature `dbconn.php`. The archive restores its own `dbconn.php`; this avoids legacy `mbstring.func_overload` checks on PHP 8. After uploading every archive volume, run `bitrix restore-ready` again; the browser URL is shown only after the archive passes integrity validation.
  CLI default is `none`. Use `bitrix installer-ready` or `bitrix restore-ready` later if the choice changes.
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
- If the target domain already exists as a configured site, `site add` now refuses to continue instead of silently reattaching or downgrading the site profile.
- Menu-based `site add` now expects a new empty project directory. Reusing a non-empty path requires an explicit CLI `--path` flow and is refused in the regular menu wizard.
- The menu wizard collects DB, access, SSL, runtime, and target choices before the first filesystem/service change, then shows a final creation plan with a default-safe `no` confirmation. The final prompt names the domain and explains that `yes` creates the site while `no` exits without creating files or configuration.
- Cancelling a `site add` wizard step returns `CANCELLED` (exit `89`) and writes the exact step and domain to `/var/log/simai-admin.log`; cancellations before final confirmation do not apply site changes.
- If an apply-stage failure occurs after confirmation, site creation rolls back only resources created by that invocation; pre-existing pools, paths, databases, users and access entries are not treated as owned cleanup targets.
- Required markers: if the directory is newly created or empty, missing markers do not block immediately; bootstrap files are applied first, then markers are rechecked. On non-empty directories without markers, the command now errors instead of falling back to `generic`.
- `/healthcheck.php` is localhost-only by default for php-mode profiles; test with `curl -i -H "Host: <domain>" http://127.0.0.1/healthcheck.php`. Static uses nginx-mode healthcheck at `/healthcheck` (local-only).
- Web root is profile-driven (`PROFILE_PUBLIC_DIR`, empty/"." means project root).

Examples:
- Create without TLS: `simai-admin.sh site add --domain example.com --profile generic --php 8.3`
- Create and issue TLS immediately: `simai-admin.sh site add --domain example.com --profile generic --php 8.3 --ssl yes --ssl-email ops@example.com`
- Create one site for domain plus subdomains: `simai-admin.sh site add --domain obr.site --profile generic --host-mode wildcard`
- Create a dedicated iframe application endpoint: `simai-admin.sh site add --domain app.example.com --profile laravel --frame-policy any`
- Create Bitrix infrastructure only: `simai-admin.sh site add --domain example.com --profile bitrix --php 8.3 --create-db yes`
- Create Bitrix and prepare fresh installer helper: `simai-admin.sh site add --domain example.com --profile bitrix --php 8.3 --create-db yes --bitrix-files setup`
- Create Bitrix and prepare restore helper: `simai-admin.sh site add --domain example.com --profile bitrix --php 8.3 --create-db yes --bitrix-files restore`

## adopt
Attach an existing application directory as a site without scaffolding.
Requirements come from `composer.json` and `.simai/app.json`
(`docs/architecture/app-manifest.md`).

```bash
sudo /root/simai-env/simai-admin.sh site adopt --domain app.example.com --path /home/simai/www/app.example.com
sudo /root/simai-env/simai-admin.sh site adopt --domain app.example.com --path /home/simai/www/app.example.com --confirm yes
```

Apply installs the required PHP version, extensions and packages (and
PostgreSQL when declared), creates `.env` from `.env.example` only when it is
missing, sets manifest `env` defaults only where unset, runs
`composer install --no-dev` as the site user, generates `APP_KEY` once, runs
migrations when requested (`--migrate yes` or `"migrate": true`) and writes
the declared workers and scheduler. Options: `--profile`, `--php`, `--owner`,
`--db-engine`, `--create-db`, `--migrate`, `--build yes|no|auto`,
`--pgdg yes`. Running adopt again on the same domain reconciles.

## deploy
Deploy a release with an atomic switch.

```bash
sudo /root/simai-env/simai-admin.sh site deploy --domain D --git https://github.com/org/app.git --ref v1.4.0 --confirm yes
sudo /root/simai-env/simai-admin.sh site deploy --domain D --archive /root/app-1.4.0.tar.gz --sha256 <sum> --confirm yes
sudo /root/simai-env/simai-admin.sh site deploy --domain D --from /root/build/app --confirm yes
sudo /root/simai-env/simai-admin.sh site deploy-rollback --domain D --confirm yes
sudo /root/simai-env/simai-admin.sh site deploy-status --domain D
```

Layout: shared `.env` and `storage/` stay in the site root; code lives in
`releases/<id>`; `current` points at the live release and nginx serves
`current/<public>`. The first deploy keeps the adopted code as
`releases/<id>-initial`. Each deploy fetches as the site user, runs
`composer install --no-dev`, migrates before the switch, switches `current`,
reloads PHP-FPM and runs `artisan queue:restart`. A failed build never touches
the live release. `--keep` (default 5) limits stored releases. Rollback
switches code only; database migrations are not reverted.

Without `--confirm yes`, `deploy` and `deploy-rollback` print their detailed
plan and change nothing.

### Static sites from CI artifacts

```bash
sudo /root/simai-env/simai-admin.sh site deploy --domain D --archive site.tgz --sha256 <sum> --confirm yes
sudo /root/simai-env/simai-admin.sh site deploy-key-add --domain D --pubkey-file ci.pub --confirm yes
sudo /root/simai-env/simai-admin.sh site redirect-add --domain D --from / --to /ru/ --code 302 --confirm yes
```

The artifact is the document root; `<root>/public` points at `current`.
Static sites behave like GitHub Pages (`/dir/`, `name.html`, `404.html`,
`200.html` for single-page apps). Deploy keys, the gate and the workflow
step: `docs/operations/ci-deploy.md`.

### Serving only some paths

```bash
sudo /root/simai-env/simai-admin.sh site paths-allow --domain runner.example.com --allow /runner.html,/assets/,/distr/ --confirm yes
sudo /root/simai-env/simai-admin.sh site paths-allow --domain runner.example.com --clear yes --confirm yes
```

Exact files and prefixes ending in `/`; every other path answers 404 (ACME
challenges always pass). The list survives certificate changes and other
re-renders.

### Node.js services (profile `node`)

```bash
sudo /root/simai-env/simai-admin.sh profile enable --id node --confirm yes
sudo /root/simai-env/simai-admin.sh site add --domain D --profile node --confirm yes   # optional --app-port 3189
sudo /root/simai-env/simai-admin.sh site deploy --domain D --git https://github.com/org/service.git --ref v1.0.0 --confirm yes
sudo /root/simai-env/simai-admin.sh site service-restart --domain D --confirm yes
journalctl -u simai-app-<project> -n 100
```

The site gets a local port and an nginx proxy; the release describes the
service in `.simai/app.json` (`node.start`, dependencies, Python
requirements, shared paths, health check). Deploy builds as the site user,
runs `simai-app-<project>.service` from `current` (restarted on failure and
on boot) and returns to the previous release when the health check fails.
Details: `docs/architecture/app-manifest.md`.

### From static to node (`set-profile`)

A static site that grows an API keeps its releases and its address:

```bash
sudo /root/simai-env/simai-admin.sh site set-profile --domain D --profile node              # plan only
sudo /root/simai-env/simai-admin.sh site set-profile --domain D --profile node --confirm yes  # optional --app-port 3189
sudo /root/simai-env/simai-admin.sh site deploy --domain D --git URL --ref TAG --confirm yes  # first node release
```

The switch allocates a port (`service.env`, with `STATIC_RELEASES=yes`),
renders the vhost from `nginx-node.conf` with the same certificate, HTTPS
redirect, HSTS, path redirects and path rules, and after one nginx reload
turns `public/` from the symlink to `current` into the directory node sites
keep for ACME challenges. `current`, `releases/` and their files do not
change, and no service runs yet: until a release brings `node.start`, nginx
serves `current` the way the static profile does (`/dir/` → `dir/index.html`,
`/page` → `page.html`, `404.html`, static caching and font CORS). Any failure
(busy port, `nginx -t`, reload) puts back the previous vhost, routes, port
record and symlink.

Requirements: profile `static` with `public/` and the release layout (deploy
the site once with `site deploy`), the `node` profile enabled.

`site deploy-rollback --release <static release>` serves an earlier static
release again and stops the service. While `current` is such a release,
`site set-profile --profile static` switches back: `public/` becomes the
symlink again (only empty directories are removed; a file there stops the
switch), the port, routes and the service unit are removed, releases and
`shared/` stay.

## describe
JSON for people and AI agents: layout, database engine (no secrets), user,
release, workers, logs, validated manifest and ready-to-run commands.

```bash
sudo /root/simai-env/simai-admin.sh site describe --domain D
```

## isolate
Move an existing site from the shared `simai` account to its own Unix user
`site-<slug>`: project files, PHP-FPM pool, cron file, queue unit and SFTP
ACLs. New sites are created isolated automatically.

```bash
sudo /root/simai-env/simai-admin.sh site isolate --domain example.com
sudo /root/simai-env/simai-admin.sh site isolate --domain example.com --confirm yes
```

Without `--confirm yes` only the plan is printed. The command reloads
PHP-FPM, nginx and cron; any failure restores the previous owner, pool, cron
and unit. Alias sites follow their target site. After migrating, run
`site doctor` and open the site. Code that writes outside the project
directory (for example to another site's folder) stops working by design.

Symlinked modules keep working as long as their targets are readable by
others (for example `/home/simai/git/<repo>` with mode `755`). Deploy scripts
that used to write into the project as `simai` must now run as the site user
(`sudo -u site-<slug> ...`) or as root followed by
`chown -R site-<slug>:site-<slug> <project>`.

## frame-policy

Change the embedding policy of an existing managed site. The setting is stored
in nginx metadata and survives SSL regeneration.

- Block cross-origin embedding (default): `simai-admin.sh site frame-policy --domain app.example.com --mode same-origin --confirm yes`
- Allow embedding from any origin: `simai-admin.sh site frame-policy --domain app.example.com --mode any --confirm yes`

`any` removes the legacy `X-Frame-Options: SAMEORIGIN` response header and adds
`Content-Security-Policy: frame-ancestors *`. It should be enabled only on a
dedicated application domain whose own authentication and authorization remain
enabled.

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
- A full successful DB and user drop removes `db.env`; site removal always removes managed `perf.env` and `runtime.env`, then removes the metadata directory when it becomes empty. Partial DB/file/metadata failures return a non-zero status and preserve unresolved metadata for inspection.
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

Safety guards:
- Managed file removal is allowed only for real project directories under the configured web root (`/home/simai/www` by default).
- Symlink project roots, resolved paths outside the managed web root, and filesystem-boundary crossings are refused.
- Alias sites do not remove target files; remove or repair the target site explicitly.

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
- `--php` (target version; menu lets you pick installed versions allowed by the profile and can offer installation of apt-available versions when missing; CLI still requires it installed)
- `--keep-old-pool` (`yes|no`, default `no`; if `no`, removes old PHP-FPM pool)

Behavior:
- Loads the profile from nginx metadata; refuses when `PROFILE_REQUIRES_PHP=no`, `PROFILE_IS_ALIAS=yes`, or `PROFILE_ALLOW_PHP_SWITCH=no`.
- Enforces profile PHP constraints when set: explicit `PROFILE_ALLOWED_PHP_VERSIONS` or dynamic `PROFILE_ALLOWED_PHP_MIN_VERSION` / `PROFILE_ALLOWED_PHP_MAX_VERSION`.
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
- Filesystem: root/docroot, markers, bootstrap files, writable paths, `.env`
  permissions, world-writable files/directories
- nginx: config/symlink presence, healthcheck policy vs profile, `nginx -t`
- PHP: version installed, php-fpm service/pool/socket, required/recommended extensions, INI expectations
- Cron: `/etc/cron.d/<project-slug>` when profile enables cron
- SSL: cert files present when metadata says ssl=on
- DB: mysql service presence when profile requires DB, public listener exposure
  on `3306/33060`, `.env` presence for required DB profiles
- Alias profiles: when `--include-target=yes`, performs a prefixed partial check of the target site (root/docroot/markers/healthcheck/nginx/php service/pool/socket) without recursion

Output: PASS/WARN/FAIL per check with hints; no secrets are shown.

## nginx-custom
Set a site's own nginx directives, included at server level of the site's
virtual host from `/etc/nginx/simai-custom/<project>.conf` (both the HTTP
and the HTTPS server). Use it for what the profile does not cover: extra
`location` blocks, headers, `client_max_body_size`, rewrites.

Options:
- `--domain <domain>` (required)
- `--content-file <file>` (required): the directives, text up to 64 KB; an
  empty file removes them
- `--window <seconds>` (30-600, default 120)
- `--confirm yes`

Behavior:
- the virtual host and the directives file are saved first; a site rendered
  before 1.41.0 gets the include on first use
- `nginx -t` must accept the directives, otherwise nothing changes and the
  nginx error is shown
- nginx reloads; if the site answered before and no longer does, the change
  is undone at once
- otherwise it is a timed change: it is undone after `--window` seconds
  unless `simai-admin.sh change confirm --id <id> --confirm yes` keeps it, so
  a mistake that locks you out repairs itself
- removing the site removes its directives

## nginx-custom-show
Show a site's own directives. `--output json` answers `simai-nginx-custom/1`:
`domain, file, present, included, content, sha256, pending_change
{change_id, expires_at}`.

## apache
Serve a PHP site (profiles `generic`, `laravel`, `wordpress`, `bitrix`)
through Apache, for applications that rely on `.htaccess`, or put it back on
nginx only.

Options:
- `--domain <domain>` (required)
- `--enable yes|no` (required)
- `--confirm yes`; without it only the plan is shown

Behavior:
- the first time, Apache is installed listening on `127.0.0.1:8088` only;
  nginx keeps ports 80 and 443
- nginx stays in front: HTTPS, access rules, own directives, ACME and the
  health check; every other request goes to Apache, including static files,
  so `.htaccess` rules apply to them
- Apache reads `.htaccess` (`AllowOverride All`) and runs PHP through the
  site's own PHP-FPM pool, so the PHP version, the pool user and PHP
  settings do not change; `site set-php` updates both servers
- the client address and scheme come from nginx (`mod_remoteip`,
  `HTTPS=on` only when nginx served HTTPS); a client cannot fake them
- Apache's vhost is `/etc/apache2/sites-available/simai-<project>.conf`,
  its error log `/var/log/apache2/<project>.error.log`; unknown names get
  403 from Apache
- if Apache rejects the configuration, or the site answered before and no
  longer does, everything is put back
- `--enable no` removes the site's Apache vhost (Apache stays installed);
  removing the site does the same
- `site describe` shows `web_server: apache|nginx`

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
  Read-only contract diagnostic: checks profile validity, filesystem/docroot,
  world-writable files, nginx healthcheck policy, PHP/cron/SSL/DB expectations,
  and MySQL network exposure. No fixes applied. Use `--strict yes` to exit
  non-zero on FAIL.
- **drift**: `simai-admin.sh site drift --domain <domain> [--fix yes]`  
  Checks metadata/cron drift; `--fix yes` can migrate marked legacy cron blocks to `/etc/cron.d/<slug>` (safe markers only). Does not auto-fix metadata/DB/files/SSL.
- **config-normalize**: `simai-admin.sh site config-normalize --domain <domain> --confirm yes`  
  Removes duplicate directives from the site PHP-FPM pool (the last value
  wins, site overrides are kept). For Bitrix sites it also aligns the request
  budget to 300 seconds in nginx, PHP-FPM and PHP. Every file is backed up
  first and restored if validation or reload fails.

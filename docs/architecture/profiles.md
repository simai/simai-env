# Profiles

Profiles describe site types in a single registry (`profiles/*.profile.sh`) and are interpreted by simai-admin. Current profiles:

- **generic**: PHP site with placeholder `<project-root>/public/index.php`; optional DB; recommended extensions include intl/gd/opcache; healthcheck enabled.
- **laravel**: PHP app with `artisan` and `bootstrap/app.php`; requires DB; cron/queue supported; healthcheck enabled.
- **static**: No PHP/DB; serves `<project-root>/public/index.html`; no cron/queue; healthcheck served directly by nginx at `/healthcheck` (local-only).
- **alias**: Points to an existing site; no PHP/DB resources of its own; allows aliasing to another root/target.

All profiles use `<project-root>/public` as web root. Each profile declares the nginx template (`PROFILE_NGINX_TEMPLATE`), healthcheck mode (`PROFILE_HEALTHCHECK_MODE`), and any required markers (`PROFILE_REQUIRED_MARKERS`) that must exist before applying the profile. Definition files are declarative (`PROFILE_` variables only) and live in `profiles/<id>.profile.sh`. The admin menu reads available profiles from this registry.

## Profile activation
- Active profiles are listed in `/etc/simai-env/profiles.enabled` (one ID per line; comments allowed). If the file is missing, legacy mode treats all profiles as enabled.
- Core profiles (`static`, `generic`, `alias`) are protected from accidental disablement.
- `site add` shows only enabled profiles; enable a profile before using it in UX or CLI.
- Initialize or adjust the allowlist with `simai-admin.sh profile init|enable|disable|list|used-by`.
- On fresh install/repair, if no simai-managed sites exist and no allowlist is present, the system seeds `/etc/simai-env/profiles.enabled` with core profiles.

## Per-site PHP ini overrides
- Stored at `/etc/simai-env/sites/<domain>/php.ini` (key=value, comments allowed).
- Applied into pool files as a managed block `simai-site-ini-begin/end`; the profile-managed block (`simai-profile-ini-*`) remains below and has higher priority.
- Overrides can be managed via `site php-ini-*` commands.

## Per-site database credentials
- Stored at `/etc/simai-env/sites/<domain>/db.env` (mode 0640, root:root), containing DB_NAME/DB_USER/DB_PASS/DB_HOST/DB_CHARSET/DB_COLLATION.
- Passwords are shown once on creation/rotation and are not logged.

See also:
- `docs/development/how-to-add-profile.md` for a step-by-step guide and checklist.
- `docs/architecture/profiles-spec.md` for full field definitions.

# Laravel Commands

Laravel profile-aware lifecycle and optimization commands are available under the `laravel` section.
In the interactive menu, Laravel daily actions are shown inside the `Laravel` section.

All commands require a site with `laravel` profile.

## status

```bash
simai-admin.sh laravel status --domain <domain>
```

Shows:
- database state (`missing`, `empty`, `schema`, `migrated`, `unknown`)
- web state (`placeholder`, `app`, `error`, `unknown`)
- application state (`placeholder` vs real app)
- setup stage (`placeholder`, `app-ready`, `post-install`)
- composer / `.env` / `APP_KEY` readiness
- scheduler file and worker unit status

Typical next steps:
- `laravel app-ready` when the site is still a placeholder
- `laravel finalize` when the app exists but baseline setup is incomplete

## app-ready

```bash
simai-admin.sh laravel app-ready --domain <domain>
```

Behavior:
- creates a real Laravel application via `composer create-project laravel/laravel`
- copies the scaffold into the existing SIMAI site root
- prepares `.env` from the site DB credentials and `APP_URL`
- preserves the existing nginx/PHP-FPM/database wiring created by `site add`

Use this on a fresh Laravel site created by:

```bash
simai-admin.sh site add --domain <domain> --profile laravel --php 8.3 --db yes
```

## finalize

```bash
simai-admin.sh laravel finalize --domain <domain> --confirm yes
```

Optional flags:

```bash
simai-admin.sh laravel finalize --domain <domain> --confirm yes \
  --mode balanced \
  --migrate yes \
  --ssl yes --email admin@example.com --redirect yes --hsts no
```

Behavior:
- ensures `.env` is present and aligned with SIMAI DB credentials
- generates `APP_KEY` when missing
- runs `artisan storage:link`
- optionally runs `artisan migrate --force`
- applies the managed Laravel optimization/site-tune mode
- rewrites the managed scheduler file
- runs `artisan config:cache` and `artisan view:cache`
- can optionally issue Let's Encrypt during the same step

## perf-status

```bash
simai-admin.sh laravel perf-status --domain <domain>
```

Shows:
- managed optimization mode (`site perf-tune` state)
- lifecycle state (`Database state`, `Web state`, `Setup stage`)
- artisan/core readiness
- `.env` / `APP_KEY`
- config/route/event cache file presence
- compiled views directory state
- cron file state
- queue unit state
- Redis extension/service availability

## perf-apply

```bash
simai-admin.sh laravel perf-apply --domain <domain> --mode balanced --confirm yes
```

Supported modes:
- `safe`
- `balanced`
- `aggressive`

Behavior:
- applies the corresponding managed site PHP-FPM governance block
- rewrites the managed Laravel scheduler file
- for real Laravel apps, runs `artisan config:cache` and `artisan view:cache`
- restarts the queue worker unit when it exists and the site is a real app

Notes:
- requires `--confirm yes` outside interactive menu
- returns non-zero if pool validation, cron sync, or artisan optimize steps fail

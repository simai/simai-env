# Laravel Performance Commands

Laravel profile-aware performance commands are available under the `laravel` section.

All commands require a site with `laravel` profile.

## perf-status

```bash
simai-admin.sh laravel perf-status --domain <domain>
```

Shows:
- managed site performance mode (`site perf-tune` state)
- artisan/core readiness
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
- Applies the corresponding managed site PHP-FPM governance block.
- Rewrites the managed Laravel cron file.
- For real Laravel apps, runs `artisan config:cache` and `artisan view:cache` as the site user.
- Restarts the queue worker unit when it exists.

Notes:
- Requires `--confirm yes` outside interactive menu.
- Returns non-zero if pool validation, cron sync, or artisan optimize steps fail.

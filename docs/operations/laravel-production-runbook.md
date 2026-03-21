# Laravel Production Runbook

This runbook describes the intended SIMAI flow for a fresh Laravel site.

## 1. Create the site shell

```bash
simai-admin.sh site add \
  --domain app.example.com \
  --profile laravel \
  --php 8.3 \
  --db yes
```

Result:
- nginx/PHP-FPM/site metadata are created
- MySQL database and user are created
- scheduler file and queue unit wiring are prepared
- the filesystem still contains only a SIMAI placeholder app

## 2. Bootstrap a real Laravel application

```bash
simai-admin.sh laravel app-ready --domain app.example.com
```

Result:
- a real Laravel application is created via Composer
- `.env` is prepared from site DB credentials
- the site moves from `placeholder` to `app-ready`

## 3. Complete post-bootstrap setup

```bash
simai-admin.sh laravel finalize --domain app.example.com --confirm yes
```

Optional:

```bash
simai-admin.sh laravel finalize \
  --domain app.example.com \
  --confirm yes \
  --migrate yes \
  --ssl yes --email admin@example.com --redirect yes
```

Result:
- `APP_KEY` is generated
- `storage:link` is created
- optional migrations can be applied
- scheduler file is rewritten
- baseline optimization is applied
- optional Let's Encrypt is issued

## 4. Verify

```bash
simai-admin.sh laravel status --domain app.example.com
simai-admin.sh laravel perf-status --domain app.example.com
simai-admin.sh site doctor --domain app.example.com
simai-admin.sh queue status --domain app.example.com
```

Expected lifecycle after a normal setup:
- `Application state = app`
- `Setup stage = post-install`
- `site doctor` without FAIL

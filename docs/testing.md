# Testing Guide

This repository is tested against a dedicated server and disposable DNS zones.

## Test Targets

- Server: `root@5.129.198.85`
- Reference domain: `env.sf8.ru`
- Disposable Let's Encrypt zone: `*.env.sf8.ru`
- Disposable manual SSL zone: `*.sf0.ru`

## Domain Policy

Use `*.env.sf8.ru` for disposable test sites:

- `generic`
- `laravel`
- `static`
- `alias`
- Let's Encrypt issue/renew/remove/status/list
- queue/cron/db/menu/drift scenarios

Use `env.sf8.ru` only as a stable smoke/regression reference site.

Use `*.sf0.ru` only for manual SSL scenarios:

- `ssl install`
- `ssl status`
- `ssl remove`

## Naming

Use predictable temporary names:

- `t-generic-<id>.env.sf8.ru`
- `t-laravel-<id>.env.sf8.ru`
- `t-static-<id>.env.sf8.ru`
- `t-alias-<id>.env.sf8.ru`
- `t-manual-<id>.sf0.ru`

Recommended `<id>` format: `YYMMDD-NN`.

## Local Config

Copy the example file and fill in real values:

```bash
cp testing/test-config.example.env testing/test-config.env
```

Do not commit `testing/test-config.env`.

## Regression Runner

Use the executable regression runner for repeatable checks:

```bash
bash testing/run-regression.sh smoke
bash testing/run-regression.sh core
bash testing/run-regression.sh menu
bash testing/run-regression.sh backend
bash testing/run-regression.sh negative
bash testing/run-regression.sh full
```

Modes:

- `smoke` runs read-only daily checks.
- `core` runs smoke plus a disposable generic site lifecycle with DB and backup checks.
- `menu` runs interactive menu cancel-flow checks in text backend (`site info`, `ssl status`, `site remove`).
- `backend` probes `SIMAI_MENU_BACKEND=whiptail` activation (skips if `whiptail` is not installed on target host).
- `negative` runs expected-failure checks (missing domain/file) to validate error handling.
- `full` runs smoke + core + menu + backend + negative.

## Secret Material

Do not store private keys or certificate bundles in git.

Recommended locations:

- Local workstation: `testing/secrets/` or another non-repo path
- Server: `/root/test-certs/sf0/`

Expected manual SSL files on the server:

- `/root/test-certs/sf0/fullchain.pem`
- `/root/test-certs/sf0/privkey.pem`
- `/root/test-certs/sf0/chain.pem`

## Safe vs Mutating Checks

Safe checks that may run automatically:

- shell syntax checks
- command wiring smoke tests
- `self status`
- `self platform-status`
- `site list`
- `ssl list`
- `db status`
- `nginx -t`
- service state checks

Mutating checks allowed for disposable test sites:

- `self bootstrap`
- `site add/remove`
- `site set-php`
- `ssl letsencrypt/install/renew/remove`
- `site db-create/db-rotate/db-export/db-drop`
- `cron add/remove`
- `queue restart`
- `site drift --fix yes`

Do not mutate non-test domains or user-managed sites unless explicitly requested.

## Regression Checklist

### Fast Smoke

1. `simai-admin.sh self status`
2. `simai-admin.sh self platform-status`
3. `simai-admin.sh site list`
4. `simai-admin.sh ssl list`
5. `simai-admin.sh db status`

### Extended Integration

1. `site add` for `generic`
2. `site info`
3. `ssl letsencrypt`
4. `ssl status`
5. `site set-php`
6. `site add` for `laravel`
7. `cron add/remove`
8. `queue status/restart/logs`
9. `site db-create/db-rotate/db-export/db-drop`
10. `site add` for `alias`
11. `ssl install` for `*.sf0.ru`
12. `ssl remove`
13. `site remove`

### Negative Cases

1. cancel in menu selectors
2. missing required args
3. repeated command execution
4. non-existent domain
5. broken manual cert path
6. non-zero command exit must not kill menu

## Notes

- Keep all test actions idempotent where possible.
- Never log secrets such as DB passwords, private keys, or token values.
- Prefer cleaning up disposable sites after each completed scenario unless a failure investigation needs them preserved.

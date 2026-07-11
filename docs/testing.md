# Testing Guide

This repository is tested against a dedicated server and disposable DNS zones.

## Test Targets

- Server: `root@5.129.198.85`
- Reference domain: `env.sf8.ru`
- Disposable Let's Encrypt zone: `*.env.sf8.ru`
- Disposable manual SSL zone: `*.env.sf8.ru`

## Domain Policy

Use `*.env.sf8.ru` for disposable test sites:

- `generic`
- `laravel`
- `static`
- `alias`
- Let's Encrypt issue/renew/remove/status/list
- queue/cron/db/menu/drift scenarios

Use `env.sf8.ru` only as a stable smoke/regression reference site.

Use a separate disposable name under `*.env.sf8.ru` for manual SSL scenarios:

- `ssl install`
- `ssl status`
- `ssl remove`

## Naming

Use predictable temporary names:

- `t-generic-<id>.env.sf8.ru`
- `t-laravel-<id>.env.sf8.ru`
- `t-static-<id>.env.sf8.ru`
- `t-alias-<id>.env.sf8.ru`
- `t-manual-<id>.env.sf8.ru`

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
bash testing/release-gate.sh
bash testing/run-regression.sh smoke
bash testing/run-regression.sh core
bash testing/run-regression.sh menu
bash testing/run-regression.sh backend
bash testing/run-regression.sh negative
bash testing/run-regression.sh full
```

The runner is read-only by default. Set `TEST_SYNC_UPDATE=yes` only for an
explicit action-gated candidate synchronization step. Mutating modes also
require both `ALLOW_DESTRUCTIVE_TESTS=yes` and
`AUTO_CLEANUP_TEST_SITES=yes`; the example config keeps all three switches off.

Registry coverage is available as machine-readable JSON:

```bash
/usr/bin/python3 scripts/ci/command_coverage.py --check
bash scripts/ci/registry_dispatch_harness.sh
```

The JSON contains one row for every registered command, its menu/CLI/legacy
surface and whether runtime execution exists or remains explicitly `not_run`.
The Linux dispatcher harness checks every route without executing handlers by
injecting an unknown option that must fail before dispatch.

Modes:

- `release-gate` wrapper runs shell syntax checks + `full` regression (mandatory for releases).
- `smoke` runs read-only daily checks.
- `core` runs smoke plus a disposable generic site lifecycle with DB and backup checks.
- `menu` runs interactive menu cancel-flow checks in text backend (`site info`, `ssl status`, `site remove`).
- `backend` probes `SIMAI_MENU_BACKEND=whiptail` activation (skips if `whiptail` is not installed on target host).
- `negative` runs expected-failure checks (missing domain/file, broken manual cert paths, backup import profile-compatibility guards).
- `full` runs smoke + core + menu + backend + negative.

## Secret Material

Do not store private keys or certificate bundles in git.

Recommended locations:

- Local workstation: `testing/secrets/` or another non-repo path
- Server: `/root/test-certs/env-sf8/`

Expected manual SSL files on the server:

- `/root/test-certs/env-sf8/fullchain.pem`
- `/root/test-certs/env-sf8/privkey.pem`
- `/root/test-certs/env-sf8/chain.pem`

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
11. `ssl install` for a disposable `*.env.sf8.ru` name
12. `ssl remove`
13. `site remove`

### Negative Cases

1. cancel in menu selectors
2. missing required args
3. repeated command execution
4. non-existent domain
5. broken manual cert path
6. non-zero command exit must not kill menu
7. every command rejects an unknown option and a stray positional token

### Terminal UX

Check text and whiptail menus with `LINES`/`COLUMNS` equivalent to `60x20`,
`80x24` and `120x40`. Primary actions and `Back` must remain reachable, narrow
tables must switch to stacked output, and a safe long-running fixture must emit
at least one `WORKING` heartbeat and handle interruption.

## Notes

- Keep all test actions idempotent where possible.
- Never log secrets such as DB passwords, private keys, or token values.
- Prefer cleaning up disposable sites after each completed scenario unless a failure investigation needs them preserved.

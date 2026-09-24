# Container end-to-end tests

These tests exercise simai-env the way a server does: systemd, nginx, PHP-FPM,
MySQL and cron run inside a privileged container, and the tests install
PostgreSQL, PHP 8.4, redis and `age` through simai-env itself. They complement
`scripts/ci/run.sh` (static checks) and `testing/run-regression.sh` (a real
host over SSH).

```bash
testing/containers/run.sh                      # default cases on Ubuntu 24.04
testing/containers/run.sh --ubuntu 22.04 all   # every case on 22.04
testing/containers/run.sh adopt_e2e deploy_e2e # named cases, in order
```

Each case prints `PASS`/`FAIL` lines and ends with `failures=<n>`; the runner
exits non-zero when a case fails. Requirements: Docker with privileged
containers and internet access (packages, Composer, Laravel).

| Case | What it covers |
| --- | --- |
| `p0_tests` | password generation, `.env` symlink refusal, jail removal with a live bind mount, observer storage trust, strict-handler pattern |
| `p1_tests` | update ref resolution without git, NodeSource keyring, site path and wildcard validation, managed config writes, logrotate |
| `nginx_tests` | every nginx template plus the HTTP/HTTPS catch-all against real nginx |
| `backup_tests` | `backup data`, verify with restore test, retention, restore, `age` encryption, schedule |
| `migrate_e2e` | `self migrate`: `/home` owner, observer relocation and sanitising, catch-all upgrade, idempotency |
| `iso_e2e` | per-site users: cross-site reads denied, migration of a legacy site, rollback |
| `lara_e2e` | Laravel site: cron and queue unit run as the site user |
| `sftp_e2e` | project SFTP access with ACLs for the site user |
| `owner_e2e` | owners: shared sites, SSH login with managed keys, a key planted by PHP is ignored |
| `moveq_e2e` | moving a Laravel site with a running queue worker to an owner |
| `sot_e2e` | Bitrix `short_open_tag` survives `php-ini-set`; `self migrate` repairs legacy pools |
| `pg_e2e` | PostgreSQL engine: site lifecycle, rotation, backup/restore, MySQL site untouched |
| `adopt_e2e` | `site adopt` on a real Laravel 13 app with PostgreSQL: requirements, migrations, workers, long job across `queue:restart`, describe output |
| `deploy_e2e` | releases: layout conversion, failed deploy, archive with checksum, rollback, retention (run after `adopt_e2e`) |

`deploy_e2e` reuses the site created by `adopt_e2e`, so run them in that order
(the default list does).

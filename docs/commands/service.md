# service commands

Host services: nginx, PHP-FPM of the installed versions, MySQL or MariaDB,
PostgreSQL, Redis and cron. Only services present on this host are accepted;
nothing else reaches `systemctl`.

## list
Show each service with its state, whether it starts at boot, since when it
runs, whether it can reload, whether it is `critical` and whether it
`can_stop` (1.62.0).

Usage: `simai-admin.sh service list [--output json]` (`simai-services/1`)

## restart / reload
Restart a service, or reload its configuration without stopping it.

Usage: `simai-admin.sh service restart --name <service> --confirm yes`,
`simai-admin.sh service reload --name <service> --confirm yes`

Behavior:
- nginx and PHP-FPM test their configuration first (`nginx -t`,
  `php-fpm<ver> -t`); a failed test stops the command and the service keeps
  running on its old configuration.
- `reload` is refused for a service that cannot reload (MySQL, cron); use
  `restart`.
- If the service is not running afterwards, the command fails and prints the
  last 30 lines of its journal.

## stop / start
Stop a service the sites can do without for a while, or start a stopped one
(1.62.0).

Usage: `simai-admin.sh service stop --name <service> --confirm yes`,
`simai-admin.sh service start --name <service> --confirm yes`

Behavior:
- nginx, PHP-FPM and the database servers are critical: sites stop
  answering without them, so `stop` refuses them (use `restart`). Only Redis
  and cron can be stopped.
- The plan of `stop` (without `--confirm yes`) names the sites that lose
  something: for cron, the sites with a scheduler or cron jobs (and the
  server's own checks and alerts pause); for Redis, the sites whose `.env`
  picks Redis for `CACHE_STORE`, `CACHE_DRIVER`, `SESSION_DRIVER` or
  `QUEUE_CONNECTION`, and their Redis queue workers. Only these keys are
  read.
- `stop` does not disable the service: it starts again on `start` or on
  reboot.
- `start` tests the configuration first, like `restart`; if the service is
  not running afterwards, the command fails with its last journal lines.

## log
Show the last journal lines of a service.

Usage: `simai-admin.sh service log --name <service> [--lines 100] [--priority err] [--format json] [--output json]`
(`simai-service-log/1`, at most 10000 lines). `--priority` keeps that level
and above (`emerg` … `debug`); `--format json` adds `entries` with `at` (ISO
8601 with the zone), `level`, `unit`, `message` and `raw` (1.60.0)

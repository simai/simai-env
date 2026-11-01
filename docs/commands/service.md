# service commands

Host services: nginx, PHP-FPM of the installed versions, MySQL or MariaDB,
PostgreSQL, Redis and cron. Only services present on this host are accepted;
nothing else reaches `systemctl`.

## list
Show each service with its state, whether it starts at boot, since when it
runs and whether it can reload.

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

## log
Show the last journal lines of a service.

Usage: `simai-admin.sh service log --name <service> [--lines 100] [--output json]`
(`simai-service-log/1`, at most 1000 lines)

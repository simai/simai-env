# queue commands

Laravel queue worker management for sites using the `laravel` profile. Commands are non-interactive and operate on the domain's queue unit (`laravel-queue-<project>.service`).

## status
Check queue worker status for a Laravel site.

Usage: `simai-admin.sh queue status --domain <domain>`

Behavior:
- Validates the domain and profile (laravel-only).
- Reads site metadata to locate the queue unit and reports Enabled/Active/SubState/PID/ExitStatus in a small table.
- If the unit is missing, suggests recreating wiring via `site set-php` or `site fix`.

## restart
Restart queue worker unit for a Laravel site.

Usage: `simai-admin.sh queue restart --domain <domain>`

Behavior:
- Same validation as `status`; fails fast for non-Laravel profiles.
- Restarts the unit with systemd, then prints the resulting Active/SubState.
- On failure, shows the last few journal lines for the unit.

## logs
Show recent queue worker logs.

Usage: `simai-admin.sh queue logs --domain <domain> [--lines 100]`

Behavior:
- Validates domain/profile and unit presence.
- Shows the last N journal lines (`--lines` numeric, default 100).

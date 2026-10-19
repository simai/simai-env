# Execution safety rollout

Owner isolation is the chosen boundary. Sites of one owner share files/identity;
cross-owner read/write probes must fail. No per-site user migration is required
solely because several sites belong to the same owner.

## Before update

Inspect describe/commands/network-plan. Custom cron, deployment and maintenance
callers that mutate need `--confirm yes`. Back up the installed toolkit before
replacing code. Confirmed `self migrate` preserves existing managed
observer/backup/scheduler jobs by adding explicit confirmation atomically after
a verified private cron backup. Custom callers still require operator review.

Run the isolated Ubuntu 22.04/24.04 matrix. Review saved case logs, failures,
skips and candidate-bound receipts under `source/output`. Failed scenarios block
promotion of the affected behavior.

## Canary site

Use a dedicated new site and owner. Preview then confirm creation. Take
`backup data --domain D --confirm yes`; verify with `backup data-verify --path P
--restore-test yes --confirm yes`. Check deploy, HTTP, code rollback and data
restore only on that site's database. Retain staged recovered files for readback.

Bitrix nginx `fastcgi_read_timeout`, FPM `request_terminate_timeout` and profile
PHP `max_execution_time` use 300 seconds. Preview `site config-normalize --domain
D`, then confirm after backup. Check effective configuration and repeat to prove
idempotency. Intentional site PHP overrides remain authoritative. Longer jobs
and restorations run through CLI as the site's user with a verified backup.

## MySQL checkpoint

Inventory established connections, remote database accounts, application
dependencies and monitoring. An empty connection snapshot is not historical
proof. Recommendation: classic and X listeners bind to `127.0.0.1`. Required
external addresses need a separately agreed restriction strategy.

Keep monitoring and SSH recovery access. Do not enable UFW blindly. Back up the
affected MySQL configuration and validate the exact proposed config. Apply after
the owner agrees to consumers and recovery. Restart and verify local TCP/socket
applications, monitoring and external denial. Roll back by restoring the config,
validating, restarting and repeating connection checks.

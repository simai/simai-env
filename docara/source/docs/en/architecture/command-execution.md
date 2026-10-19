---
extends: _core._layouts.documentation
section: content
title: Command Execution
description: Confirmation, locks, strict execution and machine-readable results
---

# Command execution and AI discovery

The existing command registry owns options and safety metadata. New commands
default to mutation; reviewed read-only operations carry `effects:read` on their
registration. `admin/lib/execution.sh` interprets conditional effects and lock
rules. Diagnostics may still write private audit logs.

## Operator contract

Mutating CLI calls preview without executing their handler unless `--confirm yes`
is supplied. `--dry-run yes` and `--dry_run yes` override confirmation. The generic
preview states action, target, effects, identity, redacted arguments, lock and
verification; it does not assert application prerequisites have passed.

The menu collects the target and confirms changes. The create-site wizard keeps
its detailed final plan and stage-specific cancellation. Existing automation
that applied without confirmation must add `--confirm yes`. New managed
scheduler/backup/observer schedules include it.

Handlers run in a fresh Bash with `set -euo pipefail`; a menu conditional cannot
disable its error handling. Handle expected nonzero outcomes explicitly. A
required transactional helper called from a conditional must return errors
explicitly because Bash can suppress errexit inside that helper. Existing EXIT
rollback traps remain active in the worker.

Two registry flags adjust the defaults. `confirm:none` exempts idempotent
reconciliation from mandatory confirmation; it is used only by `self migrate`,
which toolkits up to 1.14.x run after `self update` without `--confirm` (the
old handler is still in memory during the update). `lock:none` lets a handler
take the lock itself: `self scheduler` locks the host only when a job is due,
so the every-minute tick does not collide with scheduled backups.

Interactive callers get `busy` (75) at once. Without a terminal (cron,
automation) a lock is awaited for `SIMAI_LOCK_WAIT` seconds (default 600).

Commands that declare their own `dry-run`/`dry_run` option (`site remove`,
`site db-*`) receive it and print their detailed plan; others get the generic
preview.

Mutations lock root-owned `/run/lock/simai-env/<domain>.lock`. Site operations also
hold a shared global lock; host operations hold it exclusively. Conflicts exit 75
before the handler runs. Nested operations inherit the parent lock/authorization.
A different site target is refused unless the parent holds the host lock.
Operations without a domain conservatively use the host lock.
Creation and adoption also use the host lock because they can change packages,
profile availability and owner state.

## Machine result

`--output json` returns `simai-command-result/1`: status, exit/error code, target,
operation ID, effects, execution state and checks. Statuses: `planned`, `success`,
`cancelled`, `busy`, `invalid`, `failed`. Shell exit codes remain authoritative:
89 means user cancellation; 75 means busy. Arbitrary handler stdout/stderr is
suppressed; structured data is included only for audited describe/catalog and
site diagnostic output. Diagnostics exposes check names/statuses and counts,
omitting raw configuration details and hints. `data.status` describes site health;
the outer status describes whether the diagnostic command executed successfully.

`verification: handler_exit_only` is not HTTP/database acceptance. `applied: null`
means changed state needs readback; an idempotent successful call may change
nothing. Inspect describe/doctor and the affected application scenario.

## AI First 1.0.0 pilot

Save `self commands` as `commands.json`, then `self ai-catalog` as `ai.json` beside
it in a private directory. The external-contract binding locates exact command
entries. Only discovery, site diagnostics/listing, SSL and database status are
published. Discovery grants no root access or permission to invoke commands.

The test schema is pinned to AI First `v1.0.0`, commit
`8ed3d48efdb2435f1dd4142ab3339b00f5340fb1`, with license/checksum under
`testing/contracts`. Structure validation, publication traversal and runtime
acceptance are separate. This is an offline publisher pilot.

## Coverage

The coverage script reports static registrations and declared scenarios.
`runtime_verified: 0` is deliberate. Actual runs retain candidate digest, Ubuntu
version, case assertions, skips and command exit observations in
`source/output/<run>/`. Exit observations alone are not semantic acceptance.

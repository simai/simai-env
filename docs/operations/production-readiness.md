# Production Readiness

This document defines the minimum gate for promoting `simai-env` from a controlled test environment to real production use.

The goal is not “feature complete”. The goal is predictable day-to-day operation for common site profiles, safe updates, and clear operator visibility.

## Production Gate

`simai-env` is considered ready for production rollout only when all of the following are true:

1. Platform acceptance passes on a fresh or near-fresh Ubuntu server.
2. Core profile lifecycle acceptance passes for:
   - `generic`
   - `wordpress`
   - `laravel`
   - `bitrix`
3. Daily operations and status flows behave predictably.
4. SSL issuance and status flows behave predictably.
5. `self update` remains safe and does not regress working sites.
6. Documentation matches the real menu, commands, and lifecycle flows.

## Phase Checklist

### 1. Platform Acceptance

Required checks:
- `self bootstrap`
- `self status`
- `self platform-status`
- `self version`
- `self update`
- `self scheduler-status`
- `self auto-optimize-status`
- `self health-review-status`
- `self site-review-status`
- `self perf-status`

Acceptance criteria:
- bootstrap is idempotent enough for repeated repair use
- update works via the managed update channel
- scheduler cron exists and jobs report cleanly
- no repeated `unbound variable` / shell crashes in normal flows
- status commands degrade to `unknown` / `n/a` instead of failing hard

### 2. Profile Lifecycle Acceptance

Required profiles:
- `generic`
- `wordpress`
- `laravel`
- `bitrix`

Acceptance criteria per profile:
1. `site add` works
2. optional DB creation works when relevant
3. installer/bootstrap step works
4. finalize step works where applicable
5. status command reflects the real lifecycle state
6. `site doctor` finishes without `FAIL`

Profile-specific references:
- Bitrix: [`bitrix-production-runbook.md`](./bitrix-production-runbook.md)
- WordPress: [`wordpress-production-runbook.md`](./wordpress-production-runbook.md)
- Laravel: [`laravel-production-runbook.md`](./laravel-production-runbook.md)

### 3. Daily Operations Acceptance

Required flows:
- `site list`
- `site info`
- `site usage-status`
- `site perf-status`
- `site runtime-status`
- `site runtime-suspend`
- `site runtime-resume`
- `ssl list`
- `ssl status`
- `db status`
- `db list`
- scheduler / worker status for supported profiles

Acceptance criteria:
- ordinary menu flows are understandable without low-level tuning knowledge
- cancel/empty paths do not behave as hard errors
- status commands are read-only and safe
- pause/resume is reversible

### 4. SSL / Update Acceptance

Required flows:
- issue Let's Encrypt during or after site creation
- inspect SSL status and list output
- verify renew timer visibility
- run `self update`
- confirm existing working sites still pass basic checks afterwards

Acceptance criteria:
- certificate issuance does not break site creation
- update channel remains deterministic
- already working sites remain working after update

### 5. Documentation Acceptance

Required docs:
- menu-first user guide
- command reference for daily operations
- lifecycle runbooks for supported CMS/framework profiles
- system/update/automation reference

Acceptance criteria:
- docs describe the current menu wording
- docs describe the current command names
- no critical daily flow depends on undocumented behavior

## Current Go / No-Go Rule

Production rollout is allowed when:
- all critical checks above pass
- remaining issues are warnings only
- remaining warnings are understood and documented

Production rollout is blocked when any of the following is true:
- a core lifecycle cannot be completed repeatably
- update breaks working sites
- status/automation layers behave unpredictably
- docs diverge from real operator behavior

## Reporting Format

Each production-readiness cycle should end with:
1. what was tested
2. what passed
3. what failed
4. what remains before production rollout


# Product Roadmap (Q1 2026)

## Goal

Build a simple, reliable server environment for daily website operations:

- deploy sites by profile
- manage SSL, PHP, DB, backup/migrate from one admin CLI/menu
- keep UX minimal and predictable
- avoid feature bloat and keep destructive actions explicit

## Product Principles

1. Daily-use first. Prioritize workflows operators execute every week.
2. One obvious path. Avoid duplicate commands and ambiguous menu actions.
3. Safe by default. Read-only/status operations should be easy; destructive flows must be explicit.
4. Profile quality over profile count. Add profiles only when full lifecycle works.
5. Every release gated by regression scenarios on a real server.

## Scope Tiers

### Tier A (must-have)

- Site lifecycle: add/info/set-php/remove
- SSL lifecycle: letsencrypt/install/status/renew/remove/list
- DB lifecycle: create/export/rotate/status/drop
- Backup lifecycle: export/inspect/import-plan
- Platform lifecycle: bootstrap/update/status/platform-status
- Menu resilience: cancel and non-zero exits never kill menu session

### Tier B (near-term product growth)

- Bitrix profile (MVP)
- WordPress profile (MVP)
- Profile-specific doctor/drift checks

### Tier C (later)

- Additional OS targets beyond Ubuntu 22.04/24.04
- Expanded ecosystem profiles after Bitrix/WordPress are stable

## Iterations

## Iteration 1: Runtime Reliability Baseline

Objective: harden daily operations and make regressions reproducible.

### Batch 1.1 (now)

- Add an executable regression runner for core scenarios.
- Keep test set focused on Tier A operations.
- Ensure cleanup of disposable sites is automatic.

Exit criteria:

- Operator can run one command and get pass/fail for core scenarios.
- Script supports safe smoke and mutating core mode.

### Batch 1.2

- Expand runner coverage for menu-equivalent flows where practical.
- Add strict secret-leak checks on recent logs.

Exit criteria:

- CI/local workflow detects regressions before release.

## Iteration 2: CMS Profiles MVP (Bitrix + WordPress)

Objective: provide practical first-class profiles for common usage.

### Batch 2.1 WordPress MVP

- Add `wordpress` profile definition and nginx template.
- Ensure site add/info/doctor/drift/basic SSL/basic DB work.

Exit criteria:

- Disposable WordPress site lifecycle passes Tier A checks.

### Batch 2.2 Bitrix MVP

- Add `bitrix` profile definition and nginx template.
- Add profile checks needed for daily Bitrix operations.

Exit criteria:

- Disposable Bitrix site lifecycle passes Tier A checks.

### Batch 2.3 UX polish

- Keep menu minimal; hide non-essential/unfinished branches.
- Improve prompts/selectors where confusion is still observed.

Exit criteria:

- Operators can complete top workflows without fallback to manual command discovery.

## Iteration 3: Release Hardening + Expansion

Objective: scale reliability, then scale platform support.

### Batch 3.1 Release gates

- Make regression runner a mandatory release gate.
- Document release checklist tied to executable checks.

### Batch 3.2 OS expansion (non-priority)

- Evaluate next popular target after Ubuntu (for example Debian 12).
- Add support only after bootstrap + Tier A regression pass.

## Acceptance for "Ready for Daily Use"

The environment is considered ready when all points are true:

- Tier A workflows pass on a clean test server.
- Bitrix and WordPress MVP profiles pass lifecycle checks.
- Menu stays stable on errors/cancel in all core sections.
- No secrets in command output or logs.
- Release process uses executable gates, not only manual checks.

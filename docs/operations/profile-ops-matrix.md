# Profile Ops Matrix

Use this matrix to choose the right daily commands for each site profile.

## generic

- Main checks: `site info`, `site doctor`, `ssl status`, `site db-status` (if DB was created).
- Typical actions: `ssl letsencrypt/install/remove`, `site set-php`, `site db-create/db-rotate/db-export`.
- Not applicable: queue/worker commands, CMS-specific commands.

## laravel

- Main checks: `site info`, `site doctor`, `ssl status`, `queue status`, `cron add/remove`.
- Typical actions: `cache clear`, `queue restart`, `site fix` (plan first), DB lifecycle commands.
- Not applicable: `wp *`, `bitrix *`.

## wordpress

- Main checks: `wp status`, `wp cron-status`, `site doctor`, `ssl status`.
- Typical actions: `wp cron-sync`, `wp cache-clear`, SSL lifecycle commands, DB rotate/export.
- Notes: `wp status` reports WP-CLI readiness and cron marker consistency.
- Production rollout playbook: `docs/operations/wordpress-production-runbook.md`.

## bitrix

- Main checks: `bitrix status`, `bitrix cron-status`, `bitrix agents-status`, `site doctor`, `ssl status`.
- Typical actions: `bitrix cron-sync`, `bitrix agents-sync` (plan first), `bitrix cache-clear`, SSL lifecycle commands, DB rotate/export.
- Notes: `bitrix status` reports `dbconn.php`, `BX_CRONTAB` (best effort), and cron marker consistency.
- Production rollout playbook: `docs/operations/bitrix-production-runbook.md`.

## static

- Main checks: `site info`, `site doctor`, `ssl status`.
- Typical actions: SSL lifecycle commands only.
- Not applicable: PHP/DB/cron/queue/CMS commands.

## alias

- Main checks: `site info`, `site doctor`, `ssl status`.
- Typical actions: SSL lifecycle on alias domain, remove alias.
- Not applicable: PHP switch, DB lifecycle, cron/queue/CMS commands.

## Safe Daily Baseline (all profiles)

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status
NO_COLOR=1 /root/simai-env/simai-admin.sh self platform-status
NO_COLOR=1 /root/simai-env/simai-admin.sh site list
NO_COLOR=1 /root/simai-env/simai-admin.sh ssl list
```

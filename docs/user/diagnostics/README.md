# Diagnostics

Use this section for read-only health and consistency checks before you apply fixes.

Menu items:

- [Site health check](./site-health-check.md)
- [Configuration check](./configuration-check.md)
- [Platform status](./platform-status.md)

Advanced mode adds `Repair configuration`, which is an apply step after drift has been confirmed.

Recommended order:

1. `Platform status` when several sites may be affected
2. `Site health check` for one site
3. `Configuration check` when manual drift or managed inconsistency is suspected

Use another section instead when:

- you already know the failure is runtime logging and need request-level evidence: `Logs`
- you already know the failure is inside Laravel, WordPress, or Bitrix lifecycle: `Applications`

Technical reference:

- [site doctor](../../developer/commands/site-doctor.md)
- [site drift](../../developer/commands/site-drift.md)

# Logging and Audit

Use this document when you need the source-of-truth log locations and audit behavior for `simai-env`.

Why it matters:

- support and automation depend on stable log paths,
- audit semantics affect CLI integrations and incident reconstruction,
- logging rules are part of the operational contract.

- Installer log: `/var/log/simai-env.log` (bootstrap/install/remove).
- Admin log: `/var/log/simai-admin.log` (CLI/menu operations).
- Audit log: `/var/log/simai-audit.log`
  - Records command start/finish with timestamp, user, section/command, redacted args (keys containing pass/password/secret/token/key/cert), exit code, correlation ID.
  - Permissions: 640 root:root.
- SSL/Let’s Encrypt output appended to admin log; progress shown interactively.
- ANSI color output is TTY-only; logs remain plain text to avoid escape clutter.

Related docs:

- [commands/logs.md](../commands/logs.md)
- [operations/runbook.md](../operations/runbook.md)

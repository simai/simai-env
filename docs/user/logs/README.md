# Logs

Use this section to inspect the most important logs without remembering full filesystem paths.

Menu items:

- [Platform log](./platform-log.md)
- [Setup log](./setup-log.md)
- [Command audit log](./command-audit-log.md)
- [Website access log](./website-access-log.md)
- [Website error log](./website-error-log.md)
- [Certificate log](./certificate-log.md)

Recommended order:

1. `Website error log` for one broken site
2. `Platform log` when a managed action failed
3. `Command audit log` when you need to know what changed
4. `Certificate log` when HTTPS issuance or renewal failed

Use another section first when:

- you still do not know whether the site is healthy at all: `Diagnostics`
- you still do not know whether the host is healthy at all: `System`

Technical reference:

- [logs command reference](../../developer/commands/logs.md)

# Export Site Settings

Use this item to create a config-only archive for one managed site.

Choose it when:

- you want a safe rollback point before risky changes,
- you need to transfer managed config to another server,
- you want to capture nginx, PHP pool, cron, and queue wiring without secrets.

What to expect:

- this is not a full application backup,
- SSL private keys and project `.env` are intentionally excluded.

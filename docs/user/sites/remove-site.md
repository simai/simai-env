# Remove Site

Use this item when the managed site should be removed from the server.

Choose it when:

- the domain is no longer hosted here,
- the environment must stop managing this site completely.

What happens:

- managed nginx and runtime wiring is removed,
- the wizard can also offer file, DB, and DB-user removal depending on the profile,
- destructive parts require explicit confirmation.

What to expect:

- this is the last step, not the first troubleshooting step,
- the menu is intentionally careful here,
- for a temporary stop use `Pause site` instead.

Best practice before removal:

1. `Backup / Migrate -> Export site settings`
2. `Site info`
3. Only then `Remove site`

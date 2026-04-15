# SSL

Use this section to manage HTTPS for existing sites.

Menu items:

- [List certificates](./list-certificates.md)
- [Certificate status](./certificate-status.md)
- [Issue Let's Encrypt](./issue-lets-encrypt.md)
- [Install custom certificate](./install-custom-certificate.md)
- [Renew certificate](./renew-certificate.md)
- [Disable HTTPS](./disable-https.md)

Use `SSL` after the site already exists in `Sites`.

Typical flow:

1. `Certificate status`
2. `Issue Let's Encrypt` or `Install custom certificate`
3. `Diagnostics -> Site health check`
4. `Site info` if you want a final read-only summary

Use another section instead when:

- the site itself does not exist yet: `Sites`
- the application is broken after HTTPS is already healthy: `Diagnostics`, `Logs`, or `Applications`

Technical reference:

- [ssl command reference](../../developer/commands/ssl.md)

# Create Bitrix Site

Use this when choosing the `bitrix` profile in:

```text
Sites -> Create site
```

## What The Menu Asks

The exact prompts depend on installed services and selected options, but the important choices are:

- domain name
- whether first-level subdomains should be served by the same site
- profile: `bitrix`
- site activity class
- PHP version
- whether to create a managed MySQL database and user
- whether to request Let's Encrypt certificate after creation

## Subdomain Mode

If the menu asks:

```text
Serve all first-level subdomains too?
```

Choose `yes` when `example.ru` and `*.example.ru` must open the same Bitrix installation. This is common for multi-domain or subdomain-based Bitrix projects.

For wildcard HTTPS, continue with [SSL](ssl.md).

## After Site Creation

Site creation prepares infrastructure. It does not replace the Bitrix browser installer or restore wizard.

Continue with:

- [Install vs restore](install-vs-restore.md) for application setup.
- [Agents on cron](agents-cron.md) after Bitrix is installed or restored.
- [Diagnostics](diagnostics.md) before handing the site to users.

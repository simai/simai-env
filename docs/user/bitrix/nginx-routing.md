# Bitrix Nginx Routing

Bitrix uses its own URL rewriting layer. For normal human-readable URLs, nginx must fall back to:

```text
/bitrix/urlrewrite.php?$args
```

not directly to:

```text
/index.php
```

This matters for pages such as `/news/10487/`, `/doc/personal-data/`, and other Bitrix-managed paths.

## Request Variables

The Bitrix profile forwards Apache-like request variables to PHP-FPM where possible, including:

- `SERVER_NAME`
- `HTTP_HOST`
- `REQUEST_SCHEME`
- `SERVER_PORT`
- `HTTPS`

This helps legacy Bitrix code that builds URLs from `$_SERVER`.

## Subdomains

When a site is created with wildcard host mode, the same Bitrix installation serves the root domain and first-level subdomains. Application logic may still distinguish hosts through `HTTP_HOST`.

## Check

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

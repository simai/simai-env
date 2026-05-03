# Bitrix SSL

Bitrix sites use the common simai-env SSL menu:

```text
SSL -> Issue Let's Encrypt
SSL -> Certificate status
SSL -> Renew certificate
```

## Wildcard Sites

If the site was created with:

```text
Serve all first-level subdomains too? -> yes
```

then wildcard HTTPS should cover:

```text
example.ru
*.example.ru
```

Wildcard certificates require DNS validation. Use the menu preflight before issuing the certificate. It shows required DNS records and provider readiness.

For Cloudflare, use a restricted API token with DNS edit access for the specific zone.

Manual DNS challenge is possible, but it is not suitable for unattended renewal because Certbot needs fresh TXT records during renewal.

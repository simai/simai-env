# Bitrix Nginx Routing

Bitrix uses its own URL rewriting layer. nginx must pass Bitrix-friendly requests and variables to PHP-FPM, otherwise human-readable URLs, subdomains, or legacy URL-building code can behave differently from Apache-based hosting.

## What Must Be True

For the Bitrix profile, nginx config should include:

- fallback to `/bitrix/urlrewrite.php` for Bitrix SEF/CHPU URLs
- `client_max_body_size 64m` for common Bitrix uploads
- `SERVER_NAME` and `HTTP_HOST` forwarded to PHP-FPM
- root domain and wildcard hostnames when wildcard host mode is enabled

`bitrix status` and `site doctor` check the most important nginx contract pieces.

## SEF/CHPU Fallback

For normal human-readable URLs, nginx must fall back to:

```text
/bitrix/urlrewrite.php?$args
```

not directly to:

```text
/index.php
```

This matters for pages such as:

```text
/news/10487/
/doc/personal-data/
/sveden-camp/about-camp/document-camp/
```

If these URLs are routed directly to `/index.php`, Bitrix can open the wrong content, skip route rules, or behave differently from the same project on Apache.

## SERVER_NAME And HTTP_HOST

The Bitrix profile forwards Apache-like request variables to PHP-FPM, including:

```text
SERVER_NAME
HTTP_HOST
REQUEST_SCHEME
SERVER_PORT
HTTPS
```

Use `HTTP_HOST` when application logic must know the exact incoming host, especially on wildcard/subdomain sites:

```text
camp.example.ru
test.example.ru
b24.example.ru
```

`SERVER_NAME` can be normalized by nginx/server config. Legacy Bitrix code may still read it, so the profile forwards it, but host-sensitive project logic should prefer `HTTP_HOST` where possible.

## Wildcard Host Mode

When a site is created with:

```text
Serve all first-level subdomains too? -> yes
```

nginx should serve both:

```text
example.ru
*.example.ru
```

This only routes requests to the same Bitrix project. It does not automatically make Bitrix multi-tenant. The application must still decide what to do for each host.

Wildcard host mode covers first-level subdomains only:

```text
camp.example.ru
```

It does not cover multi-level subdomains:

```text
a.b.example.ru
```

## How To Check

Menu:

```text
Sites -> Site info
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

CLI:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Expected Bitrix nginx checks:

```text
Bitrix SEF fallback: /bitrix/urlrewrite.php
Bitrix upload body limit: client_max_body_size 64m
```

For wildcard sites, `site info` should show host mode and hostnames:

```text
Host mode: wildcard
Hostnames: example.ru, *.example.ru
```

## How To Reproduce Host-Specific Issues

From the server, test the same local nginx site with different hosts:

```bash
curl -I -H "Host: <domain>" http://127.0.0.1/
curl -I -H "Host: test.<domain>" http://127.0.0.1/
```

For a Bitrix route:

```bash
curl -I -H "Host: <domain>" http://127.0.0.1/news/10487/
curl -I -H "Host: test.<domain>" http://127.0.0.1/news/10487/
```

This checks nginx routing without waiting for external DNS.

## Common Symptoms

CHPU page opens wrong content:

- check `Bitrix SEF fallback`
- expected fallback is `/bitrix/urlrewrite.php`

Subdomain opens root-domain behavior:

- check wildcard host mode in `site info`
- check DNS wildcard `A` record
- check application logic that reads `HTTP_HOST`

`$_SERVER["SERVER_NAME"]` or `$_SERVER["HTTP_HOST"]` differs from Apache:

- check `bitrix status`
- inspect nginx config if the site was migrated before the current Bitrix template
- prefer `HTTP_HOST` for exact incoming host in application logic

Manual nginx edits disappeared after SSL change:

- regenerate or patch through simai-env where possible
- SSL commands should preserve Bitrix template metadata
- run `site doctor` after SSL operations

## Repair Direction

If `site doctor` reports missing Bitrix nginx checks, the safe direction is to restore the Bitrix nginx template contract rather than hand-editing unrelated blocks.

Important checks:

```text
client_max_body_size 64m
try_files $uri $uri/ /bitrix/urlrewrite.php?$args
fastcgi_param SERVER_NAME $host
fastcgi_param HTTP_HOST $host
```

After any nginx change:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## Handoff Checklist

Before saying Bitrix nginx routing is ready:

- `site info` shows `Profile: bitrix`
- `bitrix status` reports Bitrix SEF fallback ready
- `site doctor` reports Bitrix nginx checks as pass
- wildcard host mode is enabled when subdomains are required
- root and subdomain hosts open the expected Bitrix application
- large uploads are covered by [Uploads](uploads.md)

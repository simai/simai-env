# ServBay Caddy clean-host routes for SIMAI Portal

This note records the Caddy-only delta required when a SIMAI Portal solution is
published on a clean host such as `camp.sf0.test`, while the Bitrix document root
remains the shared portal root.

## Site map route

Insert the snippet from
`templates/servbay-caddy-portal-clean-host.caddy` inside the HTTPS site block,
after any static `robots.txt`/sitemap handlers and before the generic PHP route:

```caddyfile
@portalTechnicalMap path /map.php /map/*
rewrite @portalTechnicalMap /simai-portal-technical.php?route=map
```

Do not rewrite the request to the solution directory (for example,
`/camp/map/`). The shared handler resolves the current tenant from the host and
renders the technical map with the correct page title.

## Verification

Validate the complete ServBay Caddyfile before reload:

```bash
/Applications/ServBay/bin/caddy validate \
  --config /Applications/ServBay/etc/caddy/Caddyfile
```

After reload, verify both semantics and routing:

```bash
curl -ksS -L https://camp.sf0.test/map/ | \
  rg '<title>Карта сайта</title>|<h1[^>]*>Карта сайта</h1>'
```

The route must return HTTP 200, title and H1 `Карта сайта`, and must not contain
`Fatal error`, `Cannot find`, or `Undefined constant`.

## Rollback

Restore the pre-change Caddyfile backup, validate it, reload Caddy, and repeat
the smoke check. Keep this change vhost-scoped; shared portal routes and sibling
solution hosts must not be modified.

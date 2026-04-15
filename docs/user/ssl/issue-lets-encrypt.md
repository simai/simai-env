# Issue Let's Encrypt

Use this item to enable managed HTTPS with a Let's Encrypt certificate.

Choose it when:

- the site already resolves to this server,
- you want standard managed HTTPS,
- you do not need to install your own certificate files.

The wizard may ask:

- domain,
- email,
- whether to redirect HTTP to HTTPS,
- whether to enable HSTS,
- for wildcard-host sites, whether wildcard issuance should be used.

What happens:

- `simai-env` requests the certificate,
- writes or updates nginx SSL wiring,
- reloads nginx,
- keeps renewal under managed control.

What to expect:

- if DNS is not ready, issuance can fail without deleting the site,
- wildcard certificates require the supported DNS challenge flow,
- after success, verify with `Certificate status` and `Diagnostics -> Site health check`.

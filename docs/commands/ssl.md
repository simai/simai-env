# ssl commands

Run with `sudo /root/simai-env/simai-admin.sh ssl <command> [options]` or via menu.

## list
Show SSL status for all current sites.

Typical output includes:
- domain
- certificate type (`LE`, `LE-stg`, `custom`, `none`)
- expiry date
- days left
- staging flag
- redirect state
- HSTS state

This is the command used by the normal `SSL -> List certificates` menu item.

## letsencrypt (Let's Encrypt)
Request a certificate via webroot or DNS challenge.
- `--domain` (required)
- `--email` (required)
- `--redirect yes|no` (default no) — add HTTP→HTTPS redirect.
- `--hsts yes|no` (default no) — add HSTS header.
- `--staging yes|no` (default no) — use LE staging.
- `--wildcard yes|no` (default `no`) — request one certificate for both the main domain and all first-level subdomains.
- `--wildcard-domain` (optional) — override wildcard hostname, default `*.domain`.
- `--dns-provider cloudflare` — required for wildcard mode in the current implementation.
- `--dns-credentials /path/to/file.ini` — required for wildcard mode; Cloudflare plugin credentials file.

Behavior:
- Standard mode uses site docroot (based on profile `PROFILE_PUBLIC_DIR`, recorded as `simai-public-dir` in nginx metadata), updates nginx with cert paths from `/etc/letsencrypt/live/<domain>/`, reloads nginx, ensures cron for renewals at `/etc/cron.d/simai-certbot`.
- Wildcard mode currently works only for sites created with `site add --host-mode wildcard`.
- Wildcard mode currently uses DNS challenge through the Certbot Cloudflare plugin and requests a cert for both `<domain>` and `*.domain`.
- In menu mode, wildcard issuance now shows a preflight screen before running Certbot:
  - the required `A` records for the main domain and wildcard host
  - a note that `_acme-challenge` TXT records are created automatically through Cloudflare API
  - readiness checks for site host mode, DNS resolution, DNS plugin availability, and credentials file presence
- Wildcard renewal reuses stored per-site DNS settings from `/etc/simai-env/sites/<domain>/ssl.env`.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain example.com --email ops@example.com
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain obr.site --email ops@example.com --wildcard yes --dns-provider cloudflare --dns-credentials /root/.secrets/certbot/cloudflare.ini
```

## renew
Force renew LE cert for domain, reload nginx.
- `--domain` (required)

Notes:
- Standard certs renew through webroot as before.
- Wildcard certs renew through the stored DNS challenge settings.

## install (custom cert)
Install your own certificate and key.
- `--domain` (required)
- `--cert` (path to full chain; default `/etc/nginx/ssl/<domain>/fullchain.pem`)
- `--key` (path to private key; default `/etc/nginx/ssl/<domain>/privkey.pem`)
- `--chain` (optional)
- `--redirect yes|no` (default no)
- `--hsts yes|no` (default no)

Files are copied to `/etc/nginx/ssl/<domain>/` with 640 perms, nginx is updated and reloaded.

## remove
Disable SSL for domain; optionally delete certs.
- `--domain` (required)
- `--delete-cert yes|no` (default no) — delete LE cert and `/etc/nginx/ssl/<domain>/`.

Reverts nginx to HTTP-only and reloads.

Confirmation: In non-menu mode, `--confirm yes` is required only when `--delete-cert yes`.

Examples:
- Remove SSL from config only (no confirm): `simai-admin.sh ssl remove --domain <domain> --delete-cert no`
- Remove SSL and delete certificate files (confirm required): `simai-admin.sh ssl remove --domain <domain> --delete-cert yes --confirm yes`

## status
Show cert type/paths/dates for domain.
- `--domain` (required)

Typical output includes:
- domain
- cert type
- actual nginx cert/key paths when detected
- fallback cert/key paths
- not before / not after
- issuer
- SAN
- staging state
- warning note for staging certs

This is the command used by the normal `SSL -> Certificate status` menu item.

Notes
- Works only for existing sites (aliases are ignored/blocked).
- Catch-all is never listed.
- Private keys are not logged; cert/keys live under `/etc/letsencrypt/live/<domain>/` (LE) or `/etc/nginx/ssl/<domain>/` (custom).
- Wildcard HTTPS is separate from wildcard host mode: wildcard host mode controls nginx routing, while wildcard HTTPS controls certificate coverage for subdomains.

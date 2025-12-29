# ssl commands

Run with `sudo /root/simai-env/simai-admin.sh ssl <command> [options]` or via menu.

## letsencrypt (Let's Encrypt)
Request a certificate via webroot.
- `--domain` (required)
- `--email` (required)
- `--redirect yes|no` (default no) — add HTTP→HTTPS redirect.
- `--hsts yes|no` (default no) — add HSTS header.
- `--staging yes|no` (default no) — use LE staging.

Uses site webroot `<project>/public`, updates nginx with cert paths from `/etc/letsencrypt/live/<domain>/`, reloads nginx, ensures cron for renewals at `/etc/cron.d/simai-certbot`.

## renew
Force renew LE cert for domain, reload nginx.
- `--domain` (required)

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
- Remove SSL from config only (no confirm): `simai-admin.sh ssl remove --domain example.com --delete-cert no`
- Remove SSL and delete certificate files (confirm required): `simai-admin.sh ssl remove --domain example.com --delete-cert yes --confirm yes`

## status
Show cert type/paths/dates for domain.
- `--domain` (required)

Notes
- Works only for existing sites (aliases are ignored/blocked).
- Catch-all is never listed.
- Private keys are not logged; cert/keys live under `/etc/letsencrypt/live/<domain>/` (LE) or `/etc/nginx/ssl/<domain>/` (custom).

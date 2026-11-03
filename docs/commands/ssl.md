# ssl commands

Run with `sudo /root/simai-env/simai-admin.sh ssl <command> [options]` or via menu.

Every HTTPS listener serves HTTP/2: `listen 443 ssl http2;` on nginx before
1.25.1 (Ubuntu 22.04, 24.04), `listen 443 ssl;` plus `http2 on;` from 1.25.1
(Ubuntu 26.04), where the listen parameter is deprecated. The form is chosen
from `nginx -v` whenever `letsencrypt` or `install` renders the site; `renew`
and `self migrate` upgrade configs written by earlier releases in place. All site templates
send `X-Content-Type-Options: nosniff` (also in locations that set their own
headers, such as Bitrix static files).

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
- `--challenge http|dns` (default `http`) — `dns` proves the domain through a `_acme-challenge` TXT record instead of the webroot, so a certificate can be issued before the domain points at this server; `--wildcard yes` always uses `dns`.
- `--wildcard yes|no` (default `no`) — request one certificate for both the main domain and all first-level subdomains.
- `--wildcard-domain` (optional) — override wildcard hostname, default `*.domain`.
- `--dns-provider cloudflare|manual` (default `cloudflare` with a DNS challenge).
- `--dns-credentials /path/to/file.ini` — Cloudflare plugin credentials file; without it the token stored by `ssl dns-credentials` is used.

Behavior:
- Standard mode uses site docroot (based on profile `PROFILE_PUBLIC_DIR`, recorded as `simai-public-dir` in nginx metadata), updates nginx with cert paths from `/etc/letsencrypt/live/<domain>/`, reloads nginx, ensures cron for renewals at `/etc/cron.d/simai-certbot`.
- Wildcard mode currently works only for sites created with `site add --host-mode wildcard`.
- Wildcard mode can use either:
  - `cloudflare` — automatic DNS challenge through the Certbot Cloudflare plugin
  - `manual` — interactive DNS challenge where Certbot prints the TXT records and the operator adds them by hand
- In menu mode, wildcard issuance now shows a preflight screen before running Certbot:
  - the required `A` records for the main domain and wildcard host
  - a note that `_acme-challenge` TXT records are either created automatically through Cloudflare API or shown interactively for manual entry
  - readiness checks for site host mode, DNS resolution, provider/plugin availability, and credentials file presence where applicable
- Renewal of a DNS certificate (wildcard or not) reuses stored per-site DNS settings from `/etc/simai-env/sites/<domain>/ssl.env` for automatic providers.
- Wildcard certificates issued with `--dns-provider manual` do not auto-renew; run the same manual wildcard command again when renewal is needed.
- Cloudflare credentials files are treated as secrets: they must be regular files, not symlinks, and `ssl letsencrypt` enforces `root:root` owner with `0600` permissions before calling Certbot.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain example.com --email ops@example.com
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain example.com --email ops@example.com --challenge dns --confirm yes
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain obr.site --email ops@example.com --wildcard yes --dns-provider cloudflare --dns-credentials /root/.secrets/certbot/cloudflare.ini
sudo /root/simai-env/simai-admin.sh ssl letsencrypt --domain obr.site --email ops@example.com --wildcard yes --dns-provider manual
```

## dns-credentials
Store the Cloudflare API token used for DNS challenges, once per server.
- `--provider cloudflare` (required)
- `--token-file F` — a file whose first line is the token (an API token with
  `Zone:DNS:Edit` on the zones; 30–64 letters, digits, `-` or `_`).
- `--remove yes` — delete the stored token.

The token is written to `/etc/simai-env/dns/cloudflare.ini` (`root:root`,
`0600`) and never printed; the Certbot Cloudflare plugin is installed when it
is missing. Certbot renewals read the same file.

## dns-status
Show whether a DNS provider token is stored, never the token.
`--output json` answers `simai-ssl-dns/1`: `providers [{provider, configured,
updated_at, plugin_installed}]`.

## renew
Force renew LE cert for domain, bring the site config up to the current TLS
defaults (HTTP/2, nosniff) in place, reload nginx.
- `--domain` (required)

Notes:
- Standard certs renew through webroot as before.
- Certs issued through an automatic DNS provider (wildcard or not) renew through the stored DNS challenge settings.
- Wildcard certs issued through `manual` DNS challenge must be re-issued manually.
- The result is recorded as the certificate's `last_renew {at, ok}` in `site describe`.

## renew-due
Run by `/etc/cron.d/simai-certbot` twice a day: renews every certificate in
`/etc/letsencrypt/renewal/` that is due, one at a time, and records a failure
against its certificate in `/var/lib/simai-env/ssl-renew/<name>.json`. The
certbot deploy hook `simai-record-renewal` records each successful renewal,
also those made by `certbot.timer`. `self migrate` moves older hosts to this
cron.

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

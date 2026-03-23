# Wildcard Site Regression

This checklist validates one-site-many-subdomains hosting plus wildcard HTTPS.

## Goal

Confirm that one site can serve:
- the main domain
- all first-level subdomains

and that HTTPS can be issued for both through one wildcard certificate.

## Preconditions

- target domain exists in DNS
- wildcard DNS record points to the server (`*.domain.tld`)
- if wildcard HTTPS is tested, Cloudflare DNS challenge is available and the server has:
  - `python3-certbot-dns-cloudflare`
  - credentials file readable by root only

## Scenario

1. Create site in wildcard host mode.
2. Confirm nginx metadata and `server_name` cover both the main domain and wildcard hostname.
3. Check HTTP response on:
   - main domain
   - one subdomain
4. Check `site info` and `site list` output.
5. Issue wildcard Let's Encrypt certificate.
6. Check HTTPS response on:
   - main domain
   - one subdomain
7. Check `ssl status` output.
8. Check `ssl renew` for the same site.
9. Re-check HTTPS after renewal.

## Commands

Example site creation:

```bash
sudo /root/simai-env/simai-admin.sh site add --domain obr.site --profile generic --host-mode wildcard
```

Example wildcard certificate issuance:

```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt \
  --domain obr.site \
  --email ops@example.com \
  --wildcard yes \
  --dns-provider cloudflare \
  --dns-credentials /root/.secrets/certbot/cloudflare.ini
```

## Pass criteria

- `site info` shows `Host mode = wildcard`
- nginx config contains both hostnames in `server_name`
- HTTP works on the main domain and a first-level subdomain
- HTTPS works on the main domain and a first-level subdomain after wildcard issuance
- `ssl renew` succeeds and does not lose wildcard settings
- `ssl status` and `site info` remain consistent after renew

## Out of scope

- nested subdomains like `a.b.domain.tld`
- DNS automation for providers other than Cloudflare
- application-level routing rules inside the project code

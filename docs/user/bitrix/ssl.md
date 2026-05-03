# Bitrix SSL

Bitrix sites use the common simai-env SSL menu:

```text
SSL -> Issue Let's Encrypt
SSL -> Certificate status
SSL -> Renew certificate
```

For Bitrix, the main decision is whether you need HTTPS only for one hostname or for the root domain plus first-level subdomains.

## Decision Rule

Use standard SSL when the site opens only one hostname:

```text
example.ru
```

Use wildcard SSL when the same Bitrix site must open the root domain and first-level subdomains:

```text
example.ru
*.example.ru
```

Wildcard SSL is common for Bitrix projects where hosts such as `camp.example.ru`, `test.example.ru`, or `b24.example.ru` must be served by the same Bitrix installation.

## Before You Issue SSL

Check the site:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```

For standard SSL, DNS must point the domain to the server:

```text
<domain> -> A -> <server-ip>
```

For wildcard SSL, DNS must point both root and wildcard hosts to the server:

```text
<domain>  -> A -> <server-ip>
*.<domain> -> A -> <server-ip>
```

Wildcard SSL also requires DNS validation for Let's Encrypt. HTTP/webroot validation is not enough for wildcard certificates.

## Standard SSL

Use this when only the main hostname needs HTTPS.

Menu flow:

```text
SSL -> Issue Let's Encrypt
Select domain
email: <email>
```

CLI equivalent:

```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt \
  --domain <domain> \
  --email <email>
```

After issue:

```bash
sudo /root/simai-env/simai-admin.sh ssl status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## Wildcard SSL With Cloudflare

Use this when:

- the Bitrix site was created with wildcard host mode
- DNS for the domain is managed in Cloudflare
- you want certificate renewal to work automatically

Cloudflare flow uses Certbot DNS challenge. Certbot creates temporary `_acme-challenge` TXT records through Cloudflare API.

### Cloudflare Token Requirements

Create a restricted Cloudflare API token with these permissions:

```text
Zone / DNS / Edit
Zone / Zone / Read
```

Limit zone resources to the exact domain:

```text
Include -> Specific zone -> <domain>
```

Do not use a global account token unless there is no alternative.

### Credentials File

Store the token on the server in a root-only file, for example:

```text
/root/.secrets/certbot/cloudflare.ini
```

File content:

```text
dns_cloudflare_api_token = <token>
```

Recommended permissions:

```bash
sudo chmod 600 /root/.secrets/certbot/cloudflare.ini
```

### Menu Flow

```text
SSL -> Issue Let's Encrypt
Select domain
Choose wildcard certificate when prompted
DNS provider -> cloudflare
Credentials file -> /root/.secrets/certbot/cloudflare.ini
```

The menu preflight shows:

- required `A` records
- whether the site is in wildcard host mode
- DNS readiness
- Cloudflare plugin/credentials readiness
- what TXT validation will do

### CLI Equivalent

```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt \
  --domain <domain> \
  --email <email> \
  --wildcard yes \
  --dns-provider cloudflare \
  --dns-credentials /root/.secrets/certbot/cloudflare.ini
```

## Wildcard SSL With Manual DNS

Use this only when:

- Cloudflare/API provider is not available
- you can manually add TXT records during certificate issue
- you understand renewal will not be automatic

CLI:

```bash
sudo /root/simai-env/simai-admin.sh ssl letsencrypt \
  --domain <domain> \
  --email <email> \
  --wildcard yes \
  --dns-provider manual
```

Certbot will print `_acme-challenge` TXT records. Add the records in DNS, wait for propagation, then continue the command.

Important: manual DNS challenge is not suitable for unattended renewal. Certbot needs fresh TXT records during renewal, so a human must repeat the manual flow.

## What Wildcard SSL Covers

Wildcard certificate covers:

```text
example.ru
*.example.ru
```

It does not cover multi-level subdomains:

```text
a.b.example.ru
```

If the project needs multi-level subdomains, it needs a different certificate/domain plan.

## Check Certificate

After issue:

```bash
sudo /root/simai-env/simai-admin.sh ssl status --domain <domain>
sudo /root/simai-env/simai-admin.sh ssl list
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Expected wildcard certificate SANs:

```text
DNS:<domain>
DNS:*.domain
```

## Renewal

Standard Let's Encrypt certificates renew through the normal webroot flow.

Wildcard certificates issued with Cloudflare can renew automatically because DNS API settings are stored for the site.

Wildcard certificates issued with manual DNS challenge do not auto-renew. Re-issue the certificate manually before expiry.

## Common Mistakes

- Creating wildcard host mode but issuing only standard SSL. The root domain works over HTTPS, but subdomains do not.
- Adding `A` record for the root domain but forgetting `*.<domain>`.
- Using Cloudflare token with `Read` only; DNS challenge needs DNS edit permission.
- Using a token that is not limited to the correct zone.
- Expecting manual DNS challenge to auto-renew without a DNS API provider.
- Expecting wildcard certificate to cover multi-level subdomains.

## Handoff Checklist

Before saying Bitrix wildcard HTTPS is ready:

- `site info` shows wildcard host mode when subdomains are required
- DNS has root `A` record
- DNS has wildcard `A` record
- `ssl status` shows the intended certificate type
- certificate SAN includes root and wildcard names
- `site doctor` has no SSL-related failure
- for automatic renewal, DNS provider is not `manual`

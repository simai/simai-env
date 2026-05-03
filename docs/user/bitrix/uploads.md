# Bitrix Uploads

Large Bitrix uploads can fail before PHP receives the request if nginx rejects the request body.

Typical symptom:

```text
HTTP 413 Request Entity Too Large
```

In the Bitrix UI this can appear as:

```text
Network error
```

## What To Check

- nginx `client_max_body_size`
- PHP-FPM `upload_max_filesize`
- PHP-FPM `post_max_size`
- Bitrix field or module upload limits

The Bitrix profile sets nginx upload body limit for common Bitrix FileInput uploads. If a migrated or manually edited nginx config lost the setting, regenerate or patch the site config and reload nginx.

## Check

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```

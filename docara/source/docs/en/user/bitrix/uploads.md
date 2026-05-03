---
extends: _core._layouts.documentation
section: content
title: Uploads
description: Uploads
---

# Bitrix Uploads

Bitrix upload errors can come from several layers: browser, nginx, PHP-FPM, Bitrix settings, or the application form itself.

This guide is for the common case where small files upload but larger files fail before Bitrix receives the request.

## Typical Symptom

In Bitrix UI:

```text
Network error
```

In HTTP response:

```text
HTTP 413 Request Entity Too Large
```

If small files upload successfully but files around 5-16 MB fail with `413`, the request is usually blocked by nginx before it reaches PHP or Bitrix.

## Expected Bitrix Profile Limits

The Bitrix profile expects nginx server block to include:

```text
client_max_body_size 64m;
```

The Bitrix PHP baseline expects PHP-FPM limits such as:

```text
post_max_size = 64M
upload_max_filesize = 64M
```

Both layers matter. If nginx limit is smaller, PHP settings do not help because the request never reaches PHP.

## What To Check First

Menu:

```text
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

CLI:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Expected checks:

```text
Bitrix upload body limit: client_max_body_size 64m
```

If this is missing or failed, the active nginx config is not matching the Bitrix profile baseline.

## Check Active Nginx Config

```bash
sudo grep -n "client_max_body_size" /etc/nginx/sites-enabled/<domain>.conf
sudo grep -n "urlrewrite.php" /etc/nginx/sites-enabled/<domain>.conf
```

Expected:

```text
client_max_body_size 64m;
try_files $uri $uri/ /bitrix/urlrewrite.php?$args;
```

## Check PHP-FPM Limits

Use `site doctor` first. If deeper inspection is needed, inspect the site PHP-FPM pool shown by:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```

Look for:

```text
post_max_size
upload_max_filesize
```

For common Bitrix FileInput uploads, both should be at least as large as the intended upload size.

## Why Bitrix Shows Network Error

When nginx returns `413`, Bitrix JavaScript may only show a generic upload/network failure. The application form did not necessarily reject the file; nginx rejected the request body before `/bitrix/tools/upload.php` or another Bitrix upload endpoint could process it.

## Common Causes

- active nginx config lost `client_max_body_size 64m`
- SSL or manual nginx edit regenerated a generic server block instead of preserving Bitrix template
- old migrated site config predates the current Bitrix profile template
- PHP limits are lower than the Bitrix field/interface limit
- Bitrix field setting has its own lower limit

## Repair Direction

If nginx limit is missing, restore the Bitrix nginx baseline:

```text
client_max_body_size 64m;
```

After nginx config change:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

If PHP-FPM limits are wrong, reapply Bitrix baseline:

```bash
sudo /root/simai-env/simai-admin.sh bitrix php-baseline-sync --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## Test After Repair

Use the same user-facing form that failed, and test with at least two files:

- small file below 1 MB
- larger file above the previous failure threshold

If the HTTP response is no longer `413` but Bitrix still rejects the file, inspect Bitrix field/module settings next.

## Handoff Checklist

Before saying upload limits are fixed:

- small upload succeeds
- previously failing larger upload no longer returns `413`
- `bitrix status` shows upload body limit ready
- `site doctor` has no Bitrix nginx upload failure
- PHP-FPM `post_max_size` and `upload_max_filesize` match the intended limit
- Bitrix field/module upload limit is not lower than the test file size

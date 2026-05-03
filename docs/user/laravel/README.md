# Laravel Profile

Use `laravel` when the site should become a real Laravel application.

## Typical Menu Flow

```text
Sites -> Create site
Applications -> Laravel -> Laravel status
Applications -> Laravel -> Laravel prepare app
Applications -> Laravel -> Laravel complete setup
Applications -> Laravel -> Laravel status
Diagnostics -> Site health check
```

## What Is Automatic During Site Creation

- nginx points to `public`
- PHP-FPM pool is created
- DB can be created
- scheduler/queue infrastructure is prepared according to the profile

## What Is Not Automatic Until Laravel Actions Run

- real Laravel application bootstrap
- `APP_KEY`
- storage link
- migrations
- queue worker activation

Use `Laravel prepare app` after creating a placeholder Laravel site. Use `Laravel complete setup` after the application exists and DB settings are ready.

## CLI Equivalents

```bash
sudo /root/simai-env/simai-admin.sh laravel status --domain <domain>
sudo /root/simai-env/simai-admin.sh laravel app-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh laravel finalize --domain <domain> --confirm yes
```

# Templates

Templates define rendered configuration artifacts:

- `templates/nginx-laravel.conf`, `templates/nginx-generic.conf`, `templates/nginx-static.conf`: nginx vhost templates with placeholders:
  - `{{SERVER_NAME}}`, `{{PROJECT_ROOT}}`, `{{DOC_ROOT}}`, `{{ACME_ROOT}}`, `{{PROJECT_NAME}}`, `{{PHP_VERSION}}`, `{{PHP_SOCKET_PROJECT}}`
  - `{{DOC_ROOT}}` is derived from profile `PROFILE_PUBLIC_DIR` (may be `public`, empty/"." for project root, or another safe relative path).
- `templates/healthcheck.php`: local-only healthcheck for non-alias/non-static profiles, copied to `<docroot>/healthcheck.php` when `PROFILE_HEALTHCHECK_MODE=php`.
- `nginx-static.conf` includes an nginx-served `/healthcheck` (local-only) matching `PROFILE_HEALTHCHECK_MODE=nginx`.
- `systemd/laravel-queue.service`: queue worker unit template with placeholders `{{PROJECT_NAME}}`, `{{PROJECT_ROOT}}`, `{{PHP_BIN}}`, `{{USER}}`.

Rendering rules:
- Admin/installer replace placeholders with actual values and prepend `# simai-*` metadata to nginx configs.
- Catch-all default_server is ensured to return 444.
- SSL injection is transactional: backups are created before applying TLS directives.

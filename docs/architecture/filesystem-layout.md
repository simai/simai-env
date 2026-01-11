# Filesystem layout (credentials/config)

- `/etc/simai-env/sites/<domain>/php.ini` — per-site PHP ini overrides (managed by `site php-ini-*`), mode 0644 root:root.
- `/etc/simai-env/sites/<domain>/db.env` — per-site database credentials (managed by `site db-*`), mode 0640 root:root; source of truth for DB_NAME/DB_USER/DB_PASS/DB_HOST/DB_CHARSET/DB_COLLATION.
- Project env files (e.g., `<project>/.env`) receive DB_* via `site db-export` or site add/export; written idempotently with `env_set_kv`.

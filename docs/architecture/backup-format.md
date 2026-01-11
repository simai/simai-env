# Backup archive format

- Формат: `tar.gz`.
- Структура:
  - `manifest.json` — метаданные архива (schema=1, domain, slug, profile, php, public_dir, doc_root, enabled, список файлов с sha256/mode).
  - `nginx/sites-available/<domain>.conf`
  - `nginx/sites-enabled/<domain>.conf.symlink` — содержит `enabled: yes|no`
  - `php-fpm/pool.d/php<ver>/<slug>.conf` — если пул есть в системе
  - `cron.d/<slug>` — только если файл simai-managed и slug совпадает
  - `systemd/<unit>.service` — очередь, если присутствует
  - `NOTES.txt` — краткое описание включённых/исключённых артефактов

### Безопасность
- Архив **не** содержит SSL приватных ключей, `.env` и другие секреты.
- Cron импортируется только если файл содержит заголовки `simai-managed: yes` и корректный slug (и, по возможности, domain).
- `enabled` в manifest — булево значение (true/false).

### Создание/импорт
- Экспорт: `simai-admin.sh backup export --domain <domain> [--out <path>]`
- Инспекция: `simai-admin.sh backup inspect --file <archive>`
- Импорт: `simai-admin.sh backup import --file <archive> [--apply yes] [--enable yes|no] [--reload yes|no]`
  - По умолчанию dry-run (apply=no).
  - При apply=yes существующие файлы бэкапятся в `.bak.<timestamp>` перед заменой.
  - nginx reload выполняется только после `nginx -t`; при ошибке reload/ restart выполняется откат бэкапов (включая symlink, если enable=yes).

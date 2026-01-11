# Backup commands

Config-only backups (без секретов, без SSL ключей, без .env).

## Export
```
simai-admin.sh backup export --domain example.com [--out /root/simai-backups/example.tar.gz]
```
Сохраняет nginx конфиг, php-fpm pool (если есть), cron.d (если simai-managed), очередь systemd (если есть), manifest.json и NOTES.txt.

## Inspect
```
simai-admin.sh backup inspect --file example.tar.gz
```
Показывает manifest и проверяет sha256 файлов внутри архива. Ничего не изменяет на системе.

## Import
```
simai-admin.sh backup import --file example.tar.gz [--apply yes] [--enable yes|no] [--reload yes|no]
```
- По умолчанию dry-run (apply=no): только план.
- apply=yes применяет файлы с бэкапом существующих (`.bak.<timestamp>`).
- enable=yes создаст symlink в sites-enabled.
- reload=yes выполнит nginx -t, затем reload nginx и php-fpm (если есть пул); при ошибке reload/restart выполняется откат бэкапов (включая symlink).

Cron импортируется только если файл содержит заголовки `simai-managed: yes` и slug совпадает. SSL ключи и .env не входят в архив и не импортируются.

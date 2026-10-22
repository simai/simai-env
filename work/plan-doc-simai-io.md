# План работ: doc.simai.io → docara.simai.io (перепроверено 2026-10-22, 18:20–18:35 UTC)

## Короткий ответ на вопрос «рекомендации ещё актуальные?»

Нет, часть прежнего плана уже не нужна: перенос `play.simai.io` выполнен и
работает, а правка кодировки вышла в релизе без моего участия. Осталось одно
дело из старого плана и появилось одно новое — редирект `doc.simai.io`.

## Что перепроверено сегодня (факты)

| Проверка | Факт |
| --- | --- |
| `play.simai.io` DNS | **201.51.24.222** (вчера был 85.92.108.56) — A-запись уже переключена |
| `play.simai.io` живой | `/` 200 `text/html; charset=utf-8`, `/embed.html` 200, `/runner/editor.html` 200, `/api/health` 200 `no-store`, `/assets/*.js` и `?sf_v=…` → `immutable`, `/package.json`, `/.env`, `/simai/.htaccess` → 404 |
| `/api/health` | `releaseId: e062a00367aa-7c001c4df89e` — формат `12hex-12hex` сохранился, вопрос из прошлого плана снят |
| Сайт на сервере | профиль `node`, релиз `20261021070032` от 2026-10-21T07:00:40Z, юнит `simai-app-play-simai-io.service` active, манифест `.simai/app.json` valid, SSL LE до 2027-01-19 |
| Версия сервера | **1.18.2** (вчера 1.18.0) |
| Моя ветка `fix/node-static-charset` | **устарела**: правка вышла как 1.18.2 (там же `self migrate` для уже созданных сайтов), плюс 1.18.1 закрыл обход `deny` внутри `^~`. Локальный `main` перебазирован на 1.18.2 |
| Старый хост 85.92.108.56 | `play.simai.io` ещё отвечает 200 — vhost не выведен |
| Вопрос владельцу `q-c8d62fbfce` | потерял смысл: события его опередили (перенос сделан, 1.18.x выпущен) |

## Остаток старого плана

**Шаг 8 (без изменений) — вывод старого хоста.** Отключить vhost
`play.simai.io` и api-юнит на 85.92.108.56. Необратимо и затрагивает чужой
хост — только по слову владельца.

## Новое поручение треда simai.io: `doc.simai.io` → `docara.simai.io`

### Главный ответ отправителю: отбросить путь нельзя

Профиль `redirect` в 1.18.2 **всегда сохраняет путь и запрос**:

- `templates/nginx-redirect.conf`: `location / { return {{REDIRECT_CODE}} {{REDIRECT_TARGET}}$request_uri; }`
- `admin/commands/site.sh:1109` — `--redirect-to` принимает только origin
  (`^https?://host(:port)?$`), путь в цели запретён;
- `site redirect-add` рендерит `location = <from>`, то есть точные пути, а не
  «всё»; каталог целиком им не накрыть.

Живой пример на этом же сервере: `www.simai.io` → `simai.io`, один блок
`listen 80; listen 443 ssl;`, один переход в обе схемы,
`http://www.simai.io/foo?a=1` → `301 https://simai.io/foo?a=1`.

### Два варианта

**Вариант A — сегодня, без правок кода: путь сохраняется.**
`https://doc.simai.io/en/configurator` → `301 https://docara.simai.io/en/configurator`,
а у `docara.simai.io` нет `/en/` → читатель получит 404 вместо документации.
Для корня (`/`) всё хорошо. Годится, только если 404 на старых адресах
считается приемлемым.

**Вариант B — доработка `simai-env` (рекомендую, но это релиз).**
Добавить `site add --profile redirect --redirect-path keep|drop`
(по умолчанию `keep`, поведение не меняется):

| Файл | Правка |
| --- | --- |
| `templates/nginx-redirect.conf` | `return {{REDIRECT_CODE}} {{REDIRECT_TARGET}}{{REDIRECT_SUFFIX}};` |
| `admin/commands/site.sh` (≈1105–1115, `register_cmd` на 2295) | разобрать и проверить `--redirect-path`, записать `PATH_MODE=` в `redirect.env` |
| `admin/lib/site_utils.sh` (≈1432–1455) | подставить `{{REDIRECT_SUFFIX}}`: `$request_uri` для `keep`, `/$is_args$args` для `drop` |
| `testing/containers/cases/static_e2e.sh` (≈115–123) | рядом с «domain redirect keeps path and query» — проверка, что `drop` даёт ровно `https://new.test/?c=1` |
| `docs/commands/site.md`, `docs/operations/ci-deploy.md`, `docs/architecture/profiles.md` | строка про новый ключ |
| `VERSION`, `CHANGELOG.md`, `docs/releases/v1.19.0.md` | новый ключ — это функция, значит минорная версия |

Обязательный гейт — `bash testing/release-gate.sh` (включает регрессию на
тестовом сервере), затем `self update` на 201.51.24.222. Объём правки — около
десяти строк кода, остальное документация, тест и релизная обвязка.

### Оговорка про цель редиректа

`https://docara.simai.io/` — это не страница, а заглушка Docara с
`meta refresh` и `noindex`, которая переводит на `/ru/`. То есть читатель
сделает ещё один переход и попадёт на **русскую** документацию вместо прежней
английской. Отправить сразу на `/ru/` нельзя: `--redirect-to` не принимает
путь. Если нужен один переход в `/ru/`, в варианте B придётся разрешить путь и
в цели — это ещё одна строка в проверке, но уже другое решение.

### Шаги после выбора варианта (команды готовы)

Все три шага меняют продакшен-сервер, поэтому в фоновом прогоне не выполнены.

```bash
# 1. сайт (профиль redirect уже включён в /etc/simai-env/profiles.enabled)
/root/simai-env/simai-admin.sh site add --domain doc.simai.io --profile redirect \
  --redirect-to https://docara.simai.io --redirect-code 301 \
  [--redirect-path drop]            # только в варианте B
# сначала без --confirm yes, прочитать план, потом с ним

# 2. сертификат (уже выпущен тредом, CN doc.simai.io, до 2027-01-20, ключ соответствует)
/root/simai-env/simai-admin.sh ssl install --domain doc.simai.io \
  --cert /root/simai-setup/incoming-cert-doc-simai-io/fullchain.pem \
  --key  /root/simai-setup/incoming-cert-doc-simai-io/privkey.pem \
  --redirect no --hsts no
# --redirect no важен: иначе http получит два перехода (http→https→цель)
rm -rf /root/simai-setup/incoming-cert-doc-simai-io

# 3. доказательство до переключения DNS (DNS пока на старом хосте)
curl -sI --resolve doc.simai.io:443:201.51.24.222 https://doc.simai.io/
curl -sI --resolve doc.simai.io:443:201.51.24.222 https://doc.simai.io/en/configurator
curl -sI --resolve doc.simai.io:80:201.51.24.222  http://doc.simai.io/
```

Проверка сертификата выполнена сегодня (read-only, ничего не печатали из
ключа): `CN=doc.simai.io`, SAN `doc.simai.io`, Let's Encrypt,
`notAfter=Jan 20 16:46:30 2027 GMT`, открытый ключ сертификата совпадает с
ключом из `privkey.pem`.

### Приёмка

| Запрос | Ожидание варианта A | Ожидание варианта B |
| --- | --- | --- |
| `https://doc.simai.io/` | `301 https://docara.simai.io/` | `301 https://docara.simai.io/` |
| `https://doc.simai.io/en/configurator` | `301 https://docara.simai.io/en/configurator` (на цели 404) | `301 https://docara.simai.io/` |
| `http://doc.simai.io/en/` | один переход на цель | один переход на цель |
| `/.well-known/acme-challenge/<file>` | отдаётся с нового хоста | то же |

Дальше по письму треда: они добавляют `A doc.simai.io → 201.51.24.222`
(сейчас имя едет на старом `*.simai.io` → 85.92.108.56), после чего
`ssl letsencrypt --domain doc.simai.io --email rim@zabarov.com --redirect no`
ставит самообновляемый сертификат.

### Про журнал

Отправитель просит запись в `CHANGES.md` — в `simai-env` такого файла нет:
поведение инструмента пишется в `CHANGELOG.md` и `docs/releases/`, а операции
на сервере — в `/var/log/simai-admin.log`. Если `CHANGES.md` — журнал их
репозитория `simai/simai.io`, запись делают они.

## Что нужно от владельца

1. Вариант A (сегодня, 404 на старых английских адресах) или вариант B
   (релиз 1.19.0 с `--redirect-path drop`, затем создание сайта)?
2. Разрешение выполнить три шага выше на 201.51.24.222 (создание сайта,
   установка сертификата, удаление папки с переданным сертификатом).
3. Вывод `play.simai.io` со старого хоста 85.92.108.56 — делать или ждать?

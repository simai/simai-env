# ui.simai.io: read-only triage, 2026-11-02

Письмо msg-a7ea1f565da24bc595ed; работа task-2d287a0a324b4eb3bf55.
Статус: local_only, диагностика и подготовка. Сервер не изменён; исправление и after-check не выполнены.
Источник кода simai-env: 4fe88e69edac16313897d6e582b0db917f68192e.

## Наблюдения

Публичные curl GET из текущего agent-host (география не подтверждена), HTTP/2,
gzip, отдельный процесс curl на запрос, cache-busting ops_probe. DNS указывал
201.51.24.222. curl time_appconnect — время от начала запроса до завершения TLS,
а не чистая длительность handshake; для неё вычесть time_connect.
Исходное письмо содержит измерения из Москвы: это другая точка и другой файл.
Прямого before/after сравнения между ними нет.

Первый GET /ru/pro/admin/table/: 200, DNS 0.002138 s, TCP 0.178880 s,
TLS completion 0.293810 s, TTFB 0.930929 s, total 1.225369 s, gzip 105690 bytes.
В текущем HTML не найден прямой src table.js; вместо угадывания пути измерен
реально подключённый core.js (полный адрес ниже).

| Запрос | HTTP | TLS completion s | TTFB s | Total s | Bytes gzip | B/s (curl average) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 200 | 0.207501 | 0.412754 | 0.823552 | 270772 | 328785 |
| 2 | 200 | 0.272840 | 0.588802 | 1.122438 | 270772 | 241235 |
| 3 | 200 | 0.202870 | 0.403371 | 1.923294 | 270772 | 140785 |
| 4 | 200 | 0.209037 | 0.589827 | 1.739506 | 270772 | 155660 |
| 5 | 200 | 1.866554 | 2.189345 | 4.745461 | 270772 | 57059 |
| 6 | 200 | 0.228289 | 0.431091 | 1.052125 | 270772 | 257357 |
| 7 | 200 | 0.293795 | 0.394276 | 0.394404 | 5986 | 15177 |
| 8 | 200 | 0.280677 | 0.809867 | 1.429288 | 61816 | 43249 |

Запросы 1–6: core.js, 7: hashed CSS, 8: property-view HTML.
JS: public, max-age=600 во всех шести ответах.
CSS: public, max-age=31536000, immutable — годовой кэш уже действует для этого файла.
HTML property-view: no-cache. Все ответы nginx/1.28.3 (Ubuntu), gzip.

## Вывод и границы

Подтверждён разброс скорости с этого agent-host: core.js 0.824–4.745 s,
57–329 kB/s (десятичные kB/s, curl average включает установление соединения).
35-секундная задержка не воспроизведена; чистый TLS handshake самого медленного
запроса около 1.757 s. Эти результаты не доказывают причину и не опровергают
исходный инцидент. Нельзя заключить, что проблема только на сервере: возможны
сетевой маршрут, потери, ограничение канала, ресурсы хоста или обслуживание nginx.
Локальная быстрая сборка исключает лишь часть причин; браузерная инициализация
и цепочка зависимостей также требуют отдельного наблюдения.

## Следующая безопасная проверка и пакет изменения

1. В разрешённом запуске подтвердить production access alias для этого IP.
   В Access Center найден simai_env_test, но он описывает выделенный тестовый
   сервер: применять его к production без проверки соответствия нельзя.
   В private infrastructure catalog паспорта ui.simai.io нет. SSH в этом запуске
   не выполнялся; отсутствие доступа не утверждается.
2. Через /root/simai-env/simai-admin.sh получить self describe,
   site describe --domain ui.simai.io, self commands, self status,
   site doctor --domain ui.simai.io. Установить профиль, release, источник
   nginx-правил, исполняющего пользователя, ограничения и соседние сервисы.
3. Сопоставить временные метки внешних запросов с nginx timings, загрузкой CPU,
   памятью, диском, сетью и retransmits. Проверить rate limits, TLS/OCSP/resolver
   настройки и лимиты провайдера. Нужны два независимых внешних маршрута и
   loopback-запрос с правильным Host/SNI на тот же файл; без этого причину
   считать неизвестной. Не публиковать сырые access logs или секреты.
4. Кэш разбирать отдельно: проверенный CSS уже immutable. Для versioned JS
   установить фактический источник правил. docs/architecture/app-manifest.md
   описывает locations/cache для managed node static; применимость к этому
   сайту без inventory не установлена. Не назначать immutable HTML или
   изменяемому framework-runtime пути только из-за сходного имени.
5. Перед любой записью получить разрешение владельца, сохранить и проверить
   конфигурацию и release/manifest, записать точные команды возврата и журнал.
   Получить план штатного CLI без --confirm; проверить его; затем изменение
   только этого сайта. Не редактировать генерируемый nginx вручную.
6. Окно изменения выбрать с владельцем. Stop: неизвестный источник правил,
   нет проверенного backup/rollback, ошибочный план/nginx validation, новые
   ошибки или ухудшение соседних сайтов. При ошибке вернуть сохранённый источник
   штатным CLI и повторить smoke. Не менять глобальные настройки по догадке.
7. После разрешённого изменения повторить те же URL, gzip и точки измерения;
   проверить p50/p95, холодную загрузку table/property-view и repeat visit,
   корректность HTML/404 cache, отсутствие дублирующих Cache-Control.

Фоновый запуск запрещает production-изменения и публикацию. Нужен запуск с
владельцем для применения; новых поручений другим тредам не отправлено.
Ни backup, ни rollback, ни runtime inventory пока не проверены.

## Машиночитаемые измерения

```json
[
  {
    "at": "2026-11-02T20:38:03.767156+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.001864,
    "time_connect": 0.100855,
    "time_appconnect": 0.207501,
    "time_starttransfer": 0.412754,
    "time_total": 0.823552,
    "size_download": 270772,
    "speed_download": 328785,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:04.918506+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.002454,
    "time_connect": 0.168248,
    "time_appconnect": 0.27284,
    "time_starttransfer": 0.588802,
    "time_total": 1.122438,
    "size_download": 270772,
    "speed_download": 241235,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:06.871623+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.002153,
    "time_connect": 0.100772,
    "time_appconnect": 0.20287,
    "time_starttransfer": 0.403371,
    "time_total": 1.923294,
    "size_download": 270772,
    "speed_download": 140785,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:08.642193+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.001602,
    "time_connect": 0.09798,
    "time_appconnect": 0.209037,
    "time_starttransfer": 0.589827,
    "time_total": 1.739506,
    "size_download": 270772,
    "speed_download": 155660,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:13.425974+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.001737,
    "time_connect": 0.109374,
    "time_appconnect": 1.866554,
    "time_starttransfer": 2.189345,
    "time_total": 4.745461,
    "size_download": 270772,
    "speed_download": 57059,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:14.512779+00:00",
    "path": "/_docara/vendor/simai-framework/runtime/c4d39d528148cc8fbb1b1dadc5294462a2aaa812/distr/core/js/core.js",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.002215,
    "time_connect": 0.102761,
    "time_appconnect": 0.228289,
    "time_starttransfer": 0.431091,
    "time_total": 1.052125,
    "size_download": 270772,
    "speed_download": 257357,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: application/javascript; charset=utf-8",
      "cache-control: public, max-age=600",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:14.941086+00:00",
    "path": "/_docara/docara-shell.01e5e3b9f240a8bb570c0483694b66c4da9587751f21a6ea959ca5544d937d53.css",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.00277,
    "time_connect": 0.189937,
    "time_appconnect": 0.293795,
    "time_starttransfer": 0.394276,
    "time_total": 0.394404,
    "size_download": 5986,
    "speed_download": 15177,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: text/css; charset=utf-8",
      "cache-control: public, max-age=31536000, immutable",
      "content-encoding: gzip"
    ]
  },
  {
    "at": "2026-11-02T20:38:16.409202+00:00",
    "path": "/ru/pro/admin/property-view/",
    "curl_exit": 0,
    "http_code": 200,
    "http_version": "2",
    "remote_ip": "201.51.24.222",
    "time_namelookup": 0.004932,
    "time_connect": 0.107654,
    "time_appconnect": 0.280677,
    "time_starttransfer": 0.809867,
    "time_total": 1.429288,
    "size_download": 61816,
    "speed_download": 43249,
    "headers": [
      "server: nginx/1.28.3 (Ubuntu)",
      "content-type: text/html; charset=utf-8",
      "cache-control: no-cache",
      "content-encoding: gzip"
    ]
  }
]
```

#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
PHPV="${PHPV:-8.3}"
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }

cli db pgsql-install --confirm yes >/tmp/pi 2>&1 && ok "db pgsql-install" || { bad "pgsql-install"; tail -8 /tmp/pi; }
cli db pgsql-status 2>&1 | grep -q "localhost only" && ok "postgres local-only" || bad "pgsql-status"
php$PHPV -m | grep -qx pdo_pgsql && ok "php$PHPV pdo_pgsql installed" || bad "pdo_pgsql"

cli site add --domain gen.test --profile generic --php $PHPV --create-db yes --db-engine oracle >/dev/null 2>&1 && bad "unknown engine accepted" || ok "unknown engine refused"
cli site add --domain wpx.test --profile wordpress --php $PHPV --create-db yes --db-engine pgsql >/dev/null 2>&1 && bad "wordpress pgsql accepted" || ok "wordpress refuses pgsql"
[[ ! -e /etc/nginx/sites-available/wpx.test.conf ]] && ok "refusal left nothing behind" || bad "refusal left config"

cli site add --domain pg.test --profile generic --php $PHPV --create-db yes --db-engine pgsql --db-export yes >/tmp/a 2>&1 && ok "site add generic pgsql" || { bad "site add pgsql"; tail -15 /tmp/a; }
grep -q '^DB_ENGINE=pgsql' /etc/simai-env/sites/pg.test/db.env && ok "db.env records pgsql" || bad "db.env engine"
[[ "$(stat -c %a /etc/simai-env/sites/pg.test/db.env)" == 640 ]] && ok "db.env 0640" || bad "db.env mode"
P=/home/simai/www/pg.test
grep -q '^DB_CONNECTION=pgsql' $P/.env && grep -q '^DB_PORT=5432' $P/.env && ok ".env has pgsql connection" || { bad ".env"; cat $P/.env; }
set -a; . /etc/simai-env/sites/pg.test/db.env; set +a
u=$(stat -c %U $P)
cat > $P/public/pg.php <<'PHP'
<?php
$e = []; foreach (file(__DIR__.'/../.env', FILE_IGNORE_NEW_LINES) as $l) { if (strpos($l,'=')) { [$k,$v] = explode('=', $l, 2); $e[$k] = trim($v, '"'); } }
$pdo = new PDO("pgsql:host={$e['DB_HOST']};port={$e['DB_PORT']};dbname={$e['DB_DATABASE']}", $e['DB_USERNAME'], $e['DB_PASSWORD']);
$pdo->exec("CREATE TABLE IF NOT EXISTS orders (id serial primary key, total int)");
$pdo->exec("INSERT INTO orders (total) VALUES (100)");
echo "rows=", $pdo->query("SELECT count(*) FROM orders")->fetchColumn();
PHP
chown $u:$u $P/public/pg.php
r=$(curl -s -H 'Host: pg.test' http://127.0.0.1/pg.php); [[ "$r" == rows=1 ]] && ok "PHP-FPM site writes to its PostgreSQL DB" || bad "app db: $r"
cp /root/simai-env/templates/healthcheck.php $P/public/healthcheck.php 2>/dev/null; chown $u:$u $P/public/healthcheck.php
h=$(curl -s -H 'Host: pg.test' http://127.0.0.1/healthcheck.php); echo "$h" | grep -q '"driver": "pgsql"' && echo "$h" | grep -q '"ok": true' && ok "healthcheck connects via pgsql" || bad "healthcheck: $h"
cli site db-status --domain pg.test 2>&1 | grep -q "Owner     : ${DB_USER}" && ok "db-status shows owner role" || bad "db-status"
runuser -u postgres -- psql -Atc "SELECT has_database_privilege('public','${DB_NAME}','CONNECT')" | grep -q f && ok "PUBLIC cannot connect to site DB" || bad "public connect"

cli site db-rotate --domain pg.test --confirm yes >/tmp/rot 2>&1 && ok "db-rotate" || { bad rotate; tail /tmp/rot; }
r=$(curl -s -H 'Host: pg.test' http://127.0.0.1/pg.php); [[ "$r" == rows=2 ]] && ok "app works after rotation (.env updated)" || bad "after rotate: $r"

cli backup data --domain pg.test --keep 2 >/tmp/b 2>&1 && ok "backup data (pgsql)" || { bad backup; tail /tmp/b; }
d=$(ls -1d /var/backups/simai/pg.test/2* | tail -1)
grep -q '^db_engine=pgsql' $d/manifest.txt && ok "manifest records pgsql" || bad manifest
cli backup data-verify --path "$d" --restore-test yes 2>&1 | grep -q "restore test (1 tables" && ok "pgsql restore test" || bad "restore test"
runuser -u postgres -- psql -d "$DB_NAME" -qc "DELETE FROM orders"
cli backup data-restore --domain pg.test --path "$d" --confirm yes >/tmp/rs 2>&1 || { bad restore; tail /tmp/rs; }
r=$(curl -s -H 'Host: pg.test' http://127.0.0.1/pg.php); [[ "$r" == rows=3 ]] && ok "restore brought rows back (app still owns tables)" || bad "after restore: $r"

# MySQL site next to it is untouched.
cli site add --domain my.test --profile generic --php $PHPV --create-db yes --db-export yes >/tmp/m 2>&1 && ok "mysql site add still works" || { bad "mysql add"; tail /tmp/m; }
grep -q '^DB_CONNECTION=mysql' /home/simai/www/my.test/.env && grep -q '^DB_ENGINE=mysql' /etc/simai-env/sites/my.test/db.env && ok "mysql site keeps mysql" || bad "mysql env"

cli site remove --domain pg.test --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/tmp/rm 2>&1
[[ -z "$(runuser -u postgres -- psql -Atc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" ]] && ok "site remove dropped pg database" || bad "db left"
[[ -z "$(runuser -u postgres -- psql -Atc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" ]] && ok "site remove dropped pg role" || bad "role left"
echo "failures=$fails"; exit $fails

#!/usr/bin/env bash
# shellcheck disable=SC2024,SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive COMPOSER_ALLOW_SUPERUSER=1
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
command -v composer >/dev/null || apt-get install -y -qq composer unzip git >/dev/null 2>&1
id simai >/dev/null 2>&1 || useradd -m simai

D=app.test; P=/home/simai/www/$D
mkdir -p /home/simai/www
if [[ ! -d /root/laravel-src ]]; then
  composer create-project --no-interaction --prefer-dist laravel/laravel /root/laravel-src >/tmp/cp 2>&1 || { bad "create-project"; tail /tmp/cp; }
fi
rm -rf "$P"; cp -a /root/laravel-src "$P"; rm -rf "$P/vendor" "$P/.env" "$P/database/database.sqlite"
echo "laravel: $(grep -o '"laravel/framework": "[^"]*"' $P/composer.json)"
mkdir -p "$P/.simai"
cat >"$P/.simai/app.json" <<'JSON'
{
  "schema": "simai-app/1",
  "php": "8.4",
  "db": { "engine": "pgsql" },
  "packages": ["age", "util-linux"],
  "executables": ["/usr/bin/age", "/usr/bin/script"],
  "env": { "QUEUE_CONNECTION": "database", "DB_QUEUE_RETRY_AFTER": "120", "CACHE_STORE": "database" },
  "scheduler": true,
  "migrate": true,
  "workers": [ { "name": "default", "command": "queue:work database --sleep=1 --tries=2 --timeout=90", "stop_timeout": 100 } ],
  "frame_ancestors": ["https://*.bitrix24.ru"]
}
JSON
cli db pgsql-install --confirm yes >/dev/null 2>&1
systemctl stop mysql; systemctl disable mysql >/dev/null 2>&1  # PostgreSQL-only server

cli site adopt --domain $D --path $P >/tmp/plan 2>&1; cat /tmp/plan | sed 's/^/  | /'
grep -q "no scaffold" /tmp/plan && grep -q "pgsql" /tmp/plan && ok "adopt plan" || bad "plan"
[[ ! -e /etc/nginx/sites-available/$D.conf ]] && ok "plan changed nothing" || bad "plan applied"
cli site adopt --domain $D --path $P --confirm yes >/tmp/ad 2>&1 && ok "adopt apply" || { bad "adopt"; tail -25 /tmp/ad; }
tail -14 /tmp/ad | sed 's/^/  | /'

php8.4 -v >/dev/null 2>&1 && ok "PHP 8.4 installed" || bad "php8.4"
[[ -x /usr/bin/age && -x /usr/bin/script ]] && ok "age and script present" || bad "executables"
grep -q '^DB_CONNECTION=pgsql' $P/.env && grep -q '^QUEUE_CONNECTION=database' $P/.env && ok ".env pgsql + queue database" || bad ".env"
key1=$(grep '^APP_KEY=' $P/.env); [[ "$key1" == APP_KEY=base64:* ]] && ok "APP_KEY generated" || bad "APP_KEY"
set -a; . /etc/simai-env/sites/$D/db.env; set +a
runuser -u postgres -- psql -d "$DB_NAME" -Atc "select count(*) from migrations" | grep -qv '^0$' && ok "migrations ran in PostgreSQL" || bad "migrations"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $D" http://127.0.0.1/); [[ "$code" == 200 ]] && ok "Laravel serves 200" || { bad "http $code"; tail -5 $P/storage/logs/*.log 2>/dev/null; }
u=$(stat -c %U $P)
unit=/etc/systemd/system/laravel-queue-app-test.service
grep -q 'artisan queue:work database --sleep=1 --tries=2 --timeout=90' $unit && grep -q 'TimeoutStopSec=100' $unit && ok "worker unit from manifest" || { bad "unit"; cat $unit; }
systemctl is-active --quiet laravel-queue-app-test.service && ok "worker active" || bad "worker inactive"
sleep 2; ps -o args= -C php8.4 | grep "queue:work" | grep -q -- "--timeout=90" && ok "running worker uses manifest arguments" || bad "worker args: $(ps -o args= -C php8.4 | grep queue:work)"
! grep -qh "Connection: sqlite" $P/storage/logs/*.log 2>/dev/null && ok "no worker started before .env was configured" || bad "early worker hit sqlite"
[[ "$(ps -o user= -C php8.4 | sort -u | tr -d ' \n')" == *"$u"* ]] && ok "worker runs as $u" || bad "worker user"
grep -q "site-app-test cd $P && /usr/bin/php8.4 artisan schedule:run" /etc/cron.d/app-test && ok "scheduler cron as site user" || { bad cron; cat /etc/cron.d/app-test; }

# Long job + graceful restart: the job must finish exactly once.
rm -f $P/storage/app/done-*
mkdir -p $P/app/Jobs
cat >$P/app/Jobs/SlowJob.php <<'PHPJOB'
<?php
namespace App\Jobs;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
class SlowJob implements ShouldQueue
{
    use Queueable;
    public int $timeout = 60;
    public function handle(): void
    {
        sleep(15);
        file_put_contents(storage_path('app/done-'.uniqid()), 'x');
    }
}
PHPJOB
chown $u:$u $P/app/Jobs $P/app/Jobs/SlowJob.php
sudo -u $u php8.4 $P/artisan tinker --execute 'dispatch(new App\Jobs\SlowJob);' >/tmp/t 2>&1
sleep 4
pid1=$(systemctl show -p MainPID --value laravel-queue-app-test.service)
sudo -u $u php8.4 $P/artisan queue:restart >/dev/null 2>&1
sleep 20
n=$(ls $P/storage/app/done-* 2>/dev/null | wc -l)
[[ "$n" == 1 ]] && ok "long job finished exactly once across queue:restart" || { bad "done files: $n"; cat /tmp/t; }
pid2=$(systemctl show -p MainPID --value laravel-queue-app-test.service)
[[ -n "$pid2" && "$pid2" != 0 && "$pid2" != "$pid1" ]] && ok "worker restarted by systemd after finishing" || bad "pid $pid1 -> $pid2"
[[ "$(runuser -u postgres -- psql -d "$DB_NAME" -Atc 'select count(*) from jobs')" == 0 ]] && ok "queue drained" || bad "jobs left"

# Re-adopt reconciles without changing APP_KEY.
cli site adopt --domain $D --confirm yes >/tmp/ad2 2>&1 && ok "re-adopt (reconcile)" || { bad "re-adopt"; tail /tmp/ad2; }
[[ "$(grep '^APP_KEY=' $P/.env)" == "$key1" ]] && ok "APP_KEY unchanged" || bad "APP_KEY changed"
grep -q reconciled /tmp/ad2 && ok "reconcile mode used" || bad "mode"
# Frame policy from the manifest.
curl -sI -H "Host: $D" http://127.0.0.1/ | grep -qi "frame-ancestors 'self' https://\*.bitrix24.ru" && ok "frame-ancestors from manifest" || bad "frame policy header"
# AI-first discovery.
cli self describe >/tmp/host.json 2>/dev/null && python3 -c 'import json;d=json.load(open("/tmp/host.json"));s=[x for x in d["sites"] if x["domain"]=="app.test"][0];assert s["database"]["engine"]=="pgsql" and s["runs_as"].startswith("site-") and d["schema"]=="simai-host/1"' && ok "self describe JSON" || { bad "self describe"; head -c 600 /tmp/host.json; }
cli site describe --domain $D >/tmp/site.json 2>/dev/null && python3 -c 'import json;d=json.load(open("/tmp/site.json"));assert d["manifest"]["valid"] and d["manifest"]["db_engine"]=="pgsql" and "deploy" in d["how_to"] and d["workers"]' && ok "site describe JSON with how_to" || { bad "site describe"; head -c 600 /tmp/site.json; }
pass=$(grep '^DB_PASS=' /etc/simai-env/sites/$D/db.env | cut -d= -f2)
! grep -qF "$pass" /tmp/host.json /tmp/site.json && ok "no DB password in describe output" || bad "password leaked"
cli self commands >/tmp/cmds.json 2>/dev/null && python3 -c 'import json;d=json.load(open("/tmp/cmds.json"));n=[c["command"] for c in d["commands"]];assert "simai-admin.sh site adopt" in n and d["count"]>140' && ok "self commands JSON" || bad "self commands"
cli self migrate >/dev/null 2>&1; [[ "$(readlink /root/AGENTS.md)" == /root/simai-env/AGENTS.md ]] && ok "/root/AGENTS.md links the agent guide" || bad "AGENTS.md link"
echo "failures=$fails"; exit $fails

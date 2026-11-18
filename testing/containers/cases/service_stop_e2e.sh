#!/usr/bin/env bash
# Service stop and start (1.62.0): the list says which services are critical
# and which can stop; a stop of nginx, PHP-FPM or a database server is
# refused "critical" before a job starts; the plan of a cron or Redis stop
# names the sites that lose their scheduler, cache, sessions or queue; a
# stop job leaves the service stopped and a start job brings it back.
set -uo pipefail
rm -rf /root/simai-env-ss
cp -r /src /root/simai-env-ss
cd /root/simai-env-ss || exit 1
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
cli profile enable --id generic --confirm yes >/dev/null 2>&1
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","lang":"ru","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
wait_job() {
  local a st
  for _ in $(seq 1 180); do
    a=$(gate "$(req job:status "{\"job_id\":\"$1\"}")")
    st=$(j "d['data']['state']" <<<"$a" 2>/dev/null)
    [[ "$st" == running || -z "$st" ]] || break; sleep 1
  done
  printf '%s' "$a"
}
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server >/tmp/ss-redis 2>&1 && systemctl start redis-server 2>/dev/null
systemctl start cron 2>/dev/null
D=ss.test
cli site add --domain $D --profile generic --php 8.3 --confirm yes >/tmp/ss-add 2>&1 || { bad 'site add'; tail -5 /tmp/ss-add; }
printf '* * * * * simai true\n' >/etc/cron.d/ss-test
printf 'APP_NAME=x\nCACHE_STORE=redis\nSESSION_DRIVER="redis"\nQUEUE_CONNECTION=database\nREDIS_PASSWORD=redis\n' >/home/simai/www/$D/.env

# The list.
l=$(gate "$(req service:list '{}')")
[[ "$(j "{s['name']: (s['critical'], s['can_stop']) for s in d['data']['services']}.get('nginx')" <<<"$l")" == "(True, False)" \
  && "$(j "{s['name']: s['can_stop'] for s in d['data']['services']}.get('cron')" <<<"$l")" == True ]] \
  && ok 'list: nginx critical, cron can stop' || bad "list: $(head -c 400 <<<"$l")"

# Critical services are refused before a job.
r=$(gate "$(req service:stop '{"name":"nginx"}')")
[[ "$(j "d['status']+'/'+d['reason']" <<<"$r")" == refused/critical ]] && ok 'nginx stop plan refused: critical' || bad "nginx: $(head -c 300 <<<"$r")"
r=$(gate "$(req service:stop '{"name":"nginx"}' ',"confirm":true')")
[[ "$(j "d['status']+'/'+d['reason']" <<<"$r")" == refused/critical ]] && ok 'confirmed nginx stop refused, no job' || bad "nginx confirm: $(head -c 300 <<<"$r")"
cli service stop --name php8.3-fpm --confirm yes >/dev/null 2>&1 && bad 'CLI stopped php-fpm' || ok 'CLI refuses to stop php-fpm'
systemctl is-active --quiet nginx && systemctl is-active --quiet php8.3-fpm && ok 'nginx and php-fpm still run' || bad 'a critical service stopped'

# The plan of a cron stop names the site with a scheduler.
p=$(gate "$(req service:stop '{"name":"cron"}')")
[[ "$(j "d['data']['title']" <<<"$p")" == "Остановка cron" ]] && ok 'plan title in Russian' || bad "title: $(head -c 300 <<<"$p")"
[[ "$(j "[(s['domain'], s['uses']) for s in d['data']['service']['sites']]" <<<"$p")" == "[('$D', ['scheduler'])]" \
  && "$(j "d['data']['service']['server']" <<<"$p")" == True ]] && ok 'cron plan: the site loses its scheduler, server checks pause' || bad "cron plan: $(head -c 500 <<<"$p")"

# Redis: cache and sessions from .env (only the driver keys).
if systemctl is-active --quiet redis-server; then
  p=$(gate "$(req service:stop '{"name":"redis-server"}')")
  [[ "$(j "[(s['domain'], sorted(s['uses'])) for s in d['data']['service']['sites']]" <<<"$p")" == "[('$D', ['cache_store', 'session_driver'])]" ]] \
    && ok 'redis plan: cache and sessions, not the password' || bad "redis plan: $(head -c 500 <<<"$p")"
else
  bad "redis-server not installed: $(tail -2 /tmp/ss-redis)"
fi

# Stop and start jobs.
job=$(gate "$(req service:stop '{"name":"cron"}' ',"confirm":true')" | j "d.get('job_id','')")
a=$(wait_job "$job")
[[ "$(j "d['data']['state']" <<<"$a")" == succeeded ]] && ! systemctl is-active --quiet cron && ok 'stop job: cron stopped' || bad "stop job: $(head -c 400 <<<"$a")"
[[ "$(gate "$(req service:list '{}')" | j "{s['name']: s['active'] for s in d['data']['services']}['cron']")" != active ]] && ok 'list shows cron stopped' || bad 'list after stop'
job=$(gate "$(req service:start '{"name":"cron"}' ',"confirm":true')" | j "d.get('job_id','')")
a=$(wait_job "$job")
[[ "$(j "d['data']['state']" <<<"$a")" == succeeded ]] && systemctl is-active --quiet cron && ok 'start job: cron runs again' || bad "start job: $(head -c 400 <<<"$a")"
cli service start --name nginx --confirm yes >/dev/null 2>&1 && ok 'start of a running service is fine' || bad 'start running nginx'

rm -f /etc/cron.d/ss-test
cli site remove --domain $D --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=$fails"; exit "$fails"

#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# site suspend / site resume (1.57.0): a 503 page with Retry-After while the
# ACME challenge still answers; the scheduler, cron jobs, enabled workers and
# the site's PHP pool stop; the pause survives names, nginx-custom, cron
# job-add, self migrate and an nginx restart; resume brings back exactly what
# ran; describe/status show suspended; old names runtime-suspend/resume work;
# the panel gateway plans, runs as a job and refuses already_suspended /
# not_suspended.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { COLUMNS=220 ./simai-admin.sh "$@"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
D=pause.test
conf=/etc/nginx/sites-available/$D.conf
code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $D" "http://127.0.0.1$1"; }
until_code() { local _; for _ in {1..10}; do [[ "$(code "$1")" == "$2" ]] && return 0; sleep 0.5; done; return 1; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain "$D" --profile generic --php "$native" --create-db no --confirm yes >/tmp/ss-add.out 2>&1 \
  || { bad 'site add'; tail -15 /tmp/ss-add.out; }
project=$(sed -n 's/^# simai-project: *//p' "$conf" | head -1)
slug=$(sed -n 's/^# simai-slug: *//p' "$conf" | head -1); slug=${slug:-$project}
root=$(sed -n 's/^# simai-root: *//p' "$conf" | head -1)
grep -qF "simai-suspend/${project}[.]conf" "$conf" && ok 'a new site includes the pause file' || bad 'include missing'
echo '<?php echo "live";' >"$root/public/index.php" 2>/dev/null || echo '<?php echo "live";' >"$root/index.php"
pool=/etc/php/$native/fpm/pool.d/$project.conf
[[ -f $pool ]] || bad "no pool $pool"

# Workers: one enabled and running, one installed but disabled.
for u in "laravel-queue-${project}" "laravel-queue-${project}-mail"; do
  printf '[Unit]\nDescription=%s\n[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' "$u" >"/etc/systemd/system/$u.service"
done
systemctl daemon-reload
systemctl enable --now "laravel-queue-${project}.service" >/dev/null 2>&1
printf '* * * * * root true\n' >"/etc/cron.d/$slug"
cli cron job-add --domain "$D" --schedule '0 3 * * *' --command 'true' --confirm yes >/tmp/ss-job.out 2>&1 || { bad 'job-add'; tail -5 /tmp/ss-job.out; }
[[ -f /etc/cron.d/simai-jobs-$slug ]] || bad 'job file missing'
until_code / 200 && ok 'site answers 200 before the pause' || bad "before: $(code /)"

# Plans and refusals on the CLI.
[[ "$(cli site suspend --domain "$D" --output json 2>/dev/null | j "d['status']")" == planned ]] && ok 'suspend without confirm is a plan' || bad 'suspend plan'
[[ "$(code /)" == 200 ]] && ok 'the plan changed nothing' || bad 'plan changed'
[[ "$(cli site resume --domain "$D" --output json 2>/dev/null | j "d['status']")" == failed ]] && ok 'resume plan refuses a site that is not paused' || bad 'resume plan'

# Pause.
cli site suspend --domain "$D" --confirm yes >/tmp/ss-s.out 2>&1 && ok 'suspend' || { bad 'suspend'; tail -15 /tmp/ss-s.out; }
until_code / 503 && ok 'site answers 503' || bad "paused answer: $(code /)"
[[ "$(code /index.php)" == 503 && "$(code /any/path?x=1)" == 503 ]] && ok 'every path answers 503' || bad 'paths'
h=$(curl -s -D - -o /tmp/ss-body -H "Host: $D" http://127.0.0.1/)
grep -qi '^Retry-After: 3600' <<<"$h" && ok 'Retry-After header' || bad "headers: $h"
grep -qi '^Content-Type: text/html' <<<"$h" && grep -q 'Site temporarily unavailable' /tmp/ss-body && ok 'HTML stub page' || bad "body: $(head -c 300 /tmp/ss-body)"
acme=$(sed -n 's#^[[:space:]]*alias \(.*\)/\.well-known/acme-challenge/;#\1#p' "$conf" | head -1)
mkdir -p "$acme/.well-known/acme-challenge" && echo token-ok >"$acme/.well-known/acme-challenge/t1"
[[ "$(curl -s -H "Host: $D" http://127.0.0.1/.well-known/acme-challenge/t1)" == token-ok ]] && ok 'ACME challenge still answers' || bad "acme ($acme)"
! systemctl is-active --quiet "laravel-queue-${project}.service" && ! systemctl is-enabled --quiet "laravel-queue-${project}.service" \
  && ok 'running worker stopped and disabled' || bad 'worker still running'
[[ ! -f /etc/cron.d/$slug && -f /etc/cron.d/$slug.disabled-by-simai ]] && ok 'scheduler file paused' || bad 'cron file'
[[ ! -f /etc/cron.d/simai-jobs-$slug && -f /etc/cron.d/simai-jobs-$slug.disabled-by-simai ]] && ok 'cron jobs paused' || bad 'jobs file'
[[ ! -f $pool && -f $pool.disabled-by-simai ]] && ok 'PHP pool paused' || bad 'pool'
[[ -f "$root/public/index.php" || -f "$root/index.php" ]] && ok 'files untouched' || bad 'files'
[[ "$(cli site describe --domain "$D" 2>/dev/null | j "d['suspended']")" == True ]] && ok 'site describe: suspended' || bad 'describe'
[[ "$(cli self describe 2>/dev/null | j "next(s['suspended'] for s in d['sites'] if s['domain']=='$D')")" == True ]] && ok 'self describe: suspended' || bad 'self describe'
[[ "$(cli site status --domain "$D" --output json 2>/dev/null | j "d['data']['suspended']")" == True ]] && ok 'site status: suspended' || bad 'status'
[[ "$(cli site suspend --domain "$D" --output json 2>/dev/null | j "d['status']")" == failed ]] && ok 'suspend plan refuses a paused site' || bad 'double suspend plan'
cli site suspend --domain "$D" --confirm yes >/dev/null 2>&1 && bad 'second suspend ran' || ok 'second suspend refused'

# The pause survives commands that write the site again.
cli site name-add --domain "$D" --name "www.$D" --mode serve --check-dns no --confirm yes >/tmp/ss-n.out 2>&1 || { bad 'name-add'; tail -5 /tmp/ss-n.out; }
until_code / 503 && ok 'paused after name-add' || bad "after name-add: $(code /)"
printf 'client_max_body_size 64m;\n' >/tmp/ss-custom
cli site nginx-custom --domain "$D" --content-file /tmp/ss-custom --confirm yes >/tmp/ss-c.out 2>&1 || { bad 'nginx-custom'; tail -5 /tmp/ss-c.out; }
until_code / 503 && ok 'paused after nginx-custom' || bad "after nginx-custom: $(code /)"
cli cron job-add --domain "$D" --schedule '0 4 * * *' --command 'true' --confirm yes >/dev/null 2>&1 || bad 'job-add paused'
[[ ! -f /etc/cron.d/simai-jobs-$slug ]] && grep -q ' 4 \* \* \* ' "/etc/cron.d/simai-jobs-$slug.disabled-by-simai" \
  && ok 'a job added while paused waits' || bad "job while paused: $(ls /etc/cron.d)"
cli self migrate --confirm yes >/tmp/ss-m.out 2>&1 || { bad 'self migrate'; tail -5 /tmp/ss-m.out; }
systemctl restart nginx cron 2>/dev/null || systemctl restart nginx
until_code / 503 && ok 'paused after self migrate and restarts' || bad "after migrate: $(code /)"
! systemctl is-active --quiet "laravel-queue-${project}.service" && ok 'worker stays stopped' || bad 'worker came back'
# A deploy is refused while paused.
cli site deploy --domain "$D" --git https://example.invalid/x.git --ref v1 --confirm yes >/tmp/ss-d.out 2>&1 && bad 'deploy while paused' \
  || { grep -q 'is paused' /tmp/ss-d.out && ok 'deploy refused while paused' || { bad 'deploy message'; tail -3 /tmp/ss-d.out; }; }

# Panel gateway.
cli panel gate-enable --confirm yes >/tmp/ss-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/ss-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req site:suspend "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:already_suspended ]] && ok 'gateway refuses already_suspended' || bad "already: ${a:0:300}"
a=$(gate "$(req site:resume "{\"domain\":\"$D\"}")")
[[ "$(j "d['kind']+'|'+d['data']['command']" <<<"$a")" == 'plan|site:resume' ]] && ok 'gateway resume plan' || bad "resume plan: ${a:0:300}"
a=$(gate "$(req site:resume "{\"domain\":\"$D\"}" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a")
st=""
for _ in $(seq 1 60); do
  st=$(gate "$(req job:status "{\"job_id\":\"$jid\"}")" | j "d['data']['state']" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok 'gateway resume job succeeds' || bad "resume job: $st ${a:0:200}"

# Resumed: exactly what ran before.
until_code / 200 && ok 'site answers 200 again' || bad "resumed answer: $(code /)"
[[ ! -f /etc/nginx/simai-suspend/$project.conf ]] && ok 'pause file removed' || bad 'pause file left'
systemctl is-active --quiet "laravel-queue-${project}.service" && systemctl is-enabled --quiet "laravel-queue-${project}.service" \
  && ok 'the enabled worker runs again' || bad 'worker not restored'
! systemctl is-active --quiet "laravel-queue-${project}-mail.service" && ! systemctl is-enabled --quiet "laravel-queue-${project}-mail.service" \
  && ok 'the disabled worker stays disabled' || bad 'disabled worker started'
[[ -f /etc/cron.d/$slug && ! -e /etc/cron.d/$slug.disabled-by-simai ]] && ok 'scheduler file back' || bad 'cron back'
[[ -f /etc/cron.d/simai-jobs-$slug ]] && grep -q ' 4 \* \* \* ' /etc/cron.d/simai-jobs-$slug && ok 'cron jobs back, with the one added while paused' || bad 'jobs back'
[[ -f $pool && ! -e $pool.disabled-by-simai ]] && ok 'PHP pool back' || bad 'pool back'
[[ "$(cli site describe --domain "$D" 2>/dev/null | j "d['suspended']")" == False ]] && ok 'describe: not suspended' || bad 'describe after'
a=$(gate "$(req site:resume "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:not_suspended ]] && ok 'gateway refuses not_suspended' || bad "not_suspended: ${a:0:300}"
a=$(gate "$(req site:suspend "{\"domain\":\"$D\"}")")
[[ "$(j "d['kind']" <<<"$a")" == plan ]] && ok 'gateway suspend plan' || bad "suspend plan: ${a:0:300}"

# Older names, and a site paused by them before 1.57.0 (block inside the config).
cli site runtime-suspend --domain "$D" --confirm yes >/dev/null 2>&1 && until_code / 503 && ok 'runtime-suspend pauses' || bad 'runtime-suspend'
cli site runtime-resume --domain "$D" --confirm yes >/dev/null 2>&1 && until_code / 200 && ok 'runtime-resume resumes' || bad 'runtime-resume'
cli site suspend --domain "$D" --confirm yes >/dev/null 2>&1
rm -f "/etc/nginx/simai-suspend/$project.conf"
sed -i "\#simai-suspend/${project}#d" "$conf"
awk '{ lines[NR]=$0 } END { for (i=1;i<=NR;i++) { if (i==NR) { print "    # simai-runtime-suspend-begin"; print "    if ($request_uri !~ \"^/[.]well-known/acme-challenge/\") { return 503; }"; print "    # simai-runtime-suspend-end" } print lines[i] } }' "$conf" >/tmp/ss-legacy && cat /tmp/ss-legacy >"$conf"
nginx -t >/dev/null 2>&1 && systemctl reload nginx
cli self migrate --confirm yes >/tmp/ss-m2.out 2>&1
! grep -q 'simai-runtime-suspend-begin' "$conf" && [[ -f /etc/nginx/simai-suspend/$project.conf ]] && until_code / 503 \
  && ok 'self migrate moves an old pause block to the pause file' || { bad 'legacy migrate'; tail -5 /tmp/ss-m2.out; }
cli site resume --domain "$D" --confirm yes >/dev/null 2>&1 && until_code / 200 && ok 'resume after migration' || bad "resume after migration: $(code /)"

cli site remove --domain "$D" --remove-files yes --confirm yes >/dev/null 2>&1 || true
echo "failures=$fails"; exit "$fails"

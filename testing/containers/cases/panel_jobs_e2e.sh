#!/usr/bin/env bash
# Panel words and job details (1.60.0): a plan in Russian (labels, values,
# title, what it does, checks: blockers and notes), a refused plan names what
# stops it; a job has started_at/finished_at, title, object, actor.kind,
# steps with Russian names, progress, outcome and cancel; job:list filters
# (state, since, limit, before) and counts; nginx and service logs as entries
# with the zone, the status and priority filters, 10000 lines; self:describe
# has the timezone and the panel block.
set -uo pipefail
rm -rf /root/simai-env-pj
cp -r /src /root/simai-env-pj
cd /root/simai-env-pj || exit 1
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
  for _ in $(seq 1 240); do
    a=$(gate "$(req job:status "{\"job_id\":\"$1\"}")")
    st=$(j "d['data']['state']" <<<"$a" 2>/dev/null)
    [[ "$st" == running || -z "$st" ]] || break; sleep 1
  done
  printf '%s' "$a"
}
D=pj.test

# Plan in words.
p=$(gate "$(req site:add "{\"domain\":\"$D\",\"profile\":\"generic\",\"php\":\"8.3\",\"create-db\":\"yes\"}")")
[[ "$(j "d['data']['title']" <<<"$p")" == "Создание сайта $D" ]] && ok 'plan title in Russian' || bad "title: $(head -c 400 <<<"$p")"
[[ "$(j "{r['key']: (r['label'], r['words']) for r in d['data']['display']}['create-db']" <<<"$p")" == "('Создать базу', 'да')" ]] \
  && ok 'plan labels and values in words' || bad "display: $(j "d['data'].get('display')" <<<"$p" 2>&1 | head -c 300)"
[[ "$(j "sorted(d['data']['checks'])" <<<"$p")" == "['blockers', 'notes']" && -n "$(j "d['data']['effects_words']" <<<"$p")" ]] \
  && ok 'plan has checks and effects in words' || bad 'checks/effects'
p=$(gate "$(req site:add "{\"domain\":\"$D\",\"profile\":\"generic\",\"php\":\"8.3\"}")" | sed 's/"lang":"ru",//')
[[ "$(gate "$(printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"a"},"command":"site:add","args":{"domain":"%s","profile":"generic","php":"8.3"}}' $D)" | j "d['data']['display'][0]['label']")" == domain ]] \
  && ok 'without lang: English keys' || bad 'default lang'
[[ "$(gate "$(req job:list '{}' | sed 's/"lang":"ru"/"lang":"de"/')" | j "d['status']")" == refused ]] && ok 'an unknown lang is refused' || bad 'lang de'

# A job: steps, times, outcome.
job=$(gate "$(req site:add "{\"domain\":\"$D\",\"profile\":\"generic\",\"php\":\"8.3\",\"create-db\":\"yes\"}" ',"confirm":true')" | j "d.get('job_id','')")
a=$(wait_job "$job")
[[ "$(j "d['data']['state']" <<<"$a")" == succeeded ]] && ok 'site add job succeeded' || bad "job: $(head -c 600 <<<"$a")"
[[ "$(j "d['data']['started_at'][-1]+d['data']['finished_at'][-1]" <<<"$a")" == ZZ && "$(j "d['data']['finished_at'] >= d['data']['started_at']" <<<"$a")" == True ]] \
  && ok 'started_at and finished_at with the zone' || bad "times: $(j "(d['data']['started_at'], d['data']['finished_at'])" <<<"$a")"
[[ "$(j "d['data']['title']" <<<"$a")" == "Создание сайта $D" && "$(j "d['data']['object']" <<<"$a")" == "{'kind': 'site', 'id': '$D'}" ]] \
  && ok 'title and object' || bad "title/object: $(j "(d['data']['title'], d['data']['object'])" <<<"$a")"
[[ "$(j "d['data']['actor']['kind']" <<<"$a")" == person ]] && ok 'actor.kind person' || bad 'actor.kind'
[[ "$(j "d['data']['outcome']['code']+'/'+d['data']['outcome']['words']" <<<"$a")" == succeeded/Готово ]] && ok 'outcome succeeded' || bad "outcome: $(j "d['data']['outcome']" <<<"$a")"
[[ "$(j "d['data']['cancel']['cancellable']" <<<"$a")" == False ]] && ok 'a finished job cannot be cancelled' || bad 'cancel'

# A refused plan names what stops it: no HTTPS for the database browser.
r=$(gate "$(req site:db-browser "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']" <<<"$r")" != ok && "$(j "len((d.get('data') or {}).get('checks', {}).get('blockers', []))" <<<"$r")" -ge 1 ]] \
  && ok "a refused plan has blockers: $(j "d['data']['checks']['blockers'][0]" <<<"$r" | head -c 80)" || bad "refusal: $(head -c 400 <<<"$r")"

# A failed job: the reason in words.
since=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
fjob=$(gate "$(req ssl:renew "{\"domain\":\"$D\"}" ',"confirm":true')" | j "d.get('job_id','')")
f=$(wait_job "$fjob")
[[ "$(j "d['data']['state']" <<<"$f")" == failed && "$(j "d['data']['outcome']['words']" <<<"$f")" == Ошибка:* ]] \
  && ok "failed outcome: $(j "d['data']['outcome']['words']" <<<"$f" | head -c 90)" || bad "failed: $(j "(d['data']['state'], d['data'].get('outcome'))" <<<"$f")"

# job:list: counts, filters, pages.
l=$(gate "$(req job:list "{\"since\":\"$since\"}")")
[[ "$(j "d['data']['counts']" <<<"$l")" == "{'running': 0, 'failed_since': 1}" && "$(j "[x['job_id'] for x in d['data']['jobs']]" <<<"$l")" == "['$fjob']" ]] \
  && ok 'since: counts and the jobs after it' || bad "since: $(j "(d['data']['counts'], [x['job_id'] for x in d['data']['jobs']])" <<<"$l")"
[[ "$(gate "$(req job:list '{"state":"succeeded"}')" | j "all(x['state'] == 'succeeded' for x in d['data']['jobs']) and len(d['data']['jobs']) >= 1")" == True ]] && ok 'state filter' || bad 'state filter'
l1=$(gate "$(req job:list '{"limit":"1"}')")
[[ "$(j "(len(d['data']['jobs']), d['data']['more'], d['data']['jobs'][0]['job_id'])" <<<"$l1")" == "(1, True, '$fjob')" ]] && ok 'limit and more' || bad "limit: $(j "(len(d['data']['jobs']), d['data']['more'])" <<<"$l1")"
[[ "$(gate "$(req job:list "{\"before\":\"$fjob\",\"limit\":\"1\"}")" | j "d['data']['jobs'][0]['job_id']")" == "$job" ]] && ok 'before continues the list' || bad 'before'
[[ "$(gate "$(req job:list '{"limit":"500"}')" | j "d['status']")" == refused ]] && ok 'limit over 100 refused' || bad 'limit 500'


# nginx log entries.
root=/home/simai/www/$D; doc=$root/public; [[ -d $doc ]] || doc=$root
printf '<?php http_response_code(404); echo "nf";\n' >$doc/nf.php; chown "$(stat -c %U:%G $root)" $doc/nf.php
for _ in 1 2 3; do curl -s -o /dev/null -H "Host: $D" "http://127.0.0.1/nf.php?nope-$RANDOM"; done
curl -s -o /dev/null -H "Host: $D" http://127.0.0.1/
g=$(gate "$(req logs:nginx "{\"domain\":\"$D\",\"format\":\"json\",\"status\":\"4xx\",\"lines\":\"10000\"}")")
[[ "$(j "len(d['data']['entries']) >= 3 and all(e['status'] // 100 == 4 for e in d['data']['entries'])" <<<"$g")" == True ]] && ok 'status=4xx entries only' || bad "4xx: $(head -c 400 <<<"$g")"
[[ "$(j "d['data']['entries'][0]['at']" <<<"$g")" =~ ^20[0-9-]{8}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$ ]] && ok "access time with the zone: $(j "d['data']['entries'][0]['at']" <<<"$g")" || bad "at: $(j "d['data']['entries'][0]" <<<"$g")"
[[ "$(j "d['data']['entries'][0]['method']+' '+d['data']['entries'][0]['path'][:7]" <<<"$g")" == "GET /nf.php" ]] && ok 'method and path' || bad 'method/path'
printf '%s [error] 1#1: *1 open() "/x" failed (2: No such file or directory), client: 10.0.0.9, server: %s, request: "GET /x HTTP/1.1", host: "%s"\n' "$(date '+%Y/%m/%d %H:%M:%S')" $D $D >>"/var/log/nginx/$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$D.conf | head -n1).error.log"
e=$(gate "$(req logs:nginx "{\"domain\":\"$D\",\"kind\":\"error\",\"format\":\"json\",\"lines\":\"5\"}")")
[[ "$(j "(d['data']['entries'][-1]['level'], d['data']['entries'][-1]['ip'], d['data']['entries'][-1]['path'])" <<<"$e")" == "('error', '10.0.0.9', '/x')" \
   && "$(j "d['data']['entries'][-1]['at']" <<<"$e")" =~ [+-][0-9]{2}:[0-9]{2}$ ]] && ok 'error log: level, ip, path, zone' || bad "error entries: $(head -c 500 <<<"$e")"
[[ "$(gate "$(req logs:nginx "{\"domain\":\"$D\",\"lines\":\"10001\"}")" | j "d['status']")" == refused ]] && ok '10001 lines refused' || bad '10001'

# service log entries.
s=$(gate "$(req service:log '{"name":"nginx","format":"json","lines":"50"}')")
[[ "$(j "d['status']" <<<"$s")" == ok && "$(j "all(e['at'] and e['level'] for e in d['data']['entries'])" <<<"$s")" == True ]] && ok 'service entries with time and level' || bad "service: $(head -c 400 <<<"$s")"
s=$(gate "$(req service:log '{"name":"nginx","format":"json","priority":"err"}')")
[[ "$(j "all(e['level'] in ('emerg','alert','crit','err') for e in d['data']['entries'])" <<<"$s")" == True ]] && ok 'priority filter' || bad 'priority'

# self:describe.
h=$(gate "$(req self:describe '{}')")
[[ "$(j "sorted(d['data']['timezone'])" <<<"$h")" == "['name', 'offset']" && "$(j "'panel' in d['data']" <<<"$h")" == True ]] && ok "timezone $(j "d['data']['timezone']" <<<"$h")" || bad 'describe timezone/panel'

# Steps: site remove announces five; the commands it runs add none of theirs.
rjob=$(gate "$(req site:remove "{\"domain\":\"$D\",\"remove-files\":\"yes\",\"drop-db\":\"yes\",\"drop-db-user\":\"yes\"}" ',"confirm":true')" | j "d.get('job_id','')")
a=$(wait_job "$rjob")
steps=$(j "[(s['state'], s['title']) for s in d['data']['steps']]" <<<"$a")
[[ "$(j "d['data']['state']" <<<"$a")" == succeeded && "$(j "len(d['data']['steps']) == 5 and all(s['state'] == 'done' for s in d['data']['steps'])" <<<"$a")" == True && "$steps" == *Удаление* ]] \
  && ok "five steps in Russian, all done" || bad "steps: [$(j "d['data']['state']" <<<"$a")] $steps"
[[ "$(j "(d['data']['progress']['current'], d['data']['progress']['total'])" <<<"$a")" == "(5, 5)" ]] && ok 'progress 5 of 5' || bad "progress: $(j "d['data']['progress']" <<<"$a")"
[[ "$(j "d['data']['steps'][0]['started_at'] <= d['data']['steps'][0]['finished_at']" <<<"$a")" == True ]] && ok 'step times' || bad 'step times'
cli site remove --domain $D --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/dev/null 2>&1
echo "failures=$fails"; exit "$fails"

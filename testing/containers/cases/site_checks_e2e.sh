#!/usr/bin/env bash
# Profile rules with a one-click fix: site doctor items carry key/fix/since,
# site check-state / check-fix (CLI and panel gateway, refusals check_ok and
# unknown_check), bitrix status steps upload -> validate -> run_restore ->
# finalize -> done, and site:add refused for a disabled profile.
set -uo pipefail
rm -rf /root/simai-env-checks
cp -r /src /root/simai-env-checks
cd /root/simai-env-checks || exit 1
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
D=bxchecks.test
root=/home/simai/www/$D
doc=$root/public
ac=$doc/bitrix/php_interface/after_connect_d7.php
conf=/etc/nginx/sites-available/$D.conf
fpm=/etc/php/8.3/fpm/php-fpm.conf
opc=/etc/php/8.3/fpm/conf.d/99-zz-simai-opcache.ini
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
doctor() { cli site doctor --domain "$D" --output json 2>/dev/null; }
step() { cli bitrix status --domain "$D" --output json 2>/dev/null | j "d['data']['step']"; }

cli profile init --mode all --confirm yes >/tmp/sc-profile.out 2>&1 \
  || cli profile enable --id bitrix --confirm yes >>/tmp/sc-profile.out 2>&1 || bad 'enable profiles'
cli site add --domain "$D" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/sc-add.out 2>&1 \
  || { bad 'add Bitrix site'; tail -15 /tmp/sc-add.out; }
owner=$(stat -c %U:%G "$doc")
db=$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D/db.env")

# 1. Steps of a restore.
rm -f "$doc/restore.php" "$doc/bitrixsetup.php"
[[ "$(step)" == prepare ]] && ok 'empty Bitrix site: step prepare' || bad "step before restore.php: $(step)"
echo '<?php // restore wizard' >"$doc/restore.php"
[[ "$(step)" == upload ]] && ok 'restore.php without archive: step upload' || bad "step upload: $(step)"
mkdir -p /tmp/sc-arch/bitrix && echo x >/tmp/sc-arch/bitrix/x.txt
tar -C /tmp/sc-arch -czf "$doc/site_20261110_full_abc.tar.gz" . && chown "$owner" "$doc/site_20261110_full_abc.tar.gz"
[[ "$(step)" == validate ]] && ok 'archive uploaded: step validate' || bad "step validate: $(step)"
cli bitrix restore-ready --domain "$D" --confirm yes >/tmp/sc-rr.out 2>&1 || { bad 'restore-ready'; tail -20 /tmp/sc-rr.out; }
s=$(cli bitrix status --domain "$D" --output json 2>/dev/null)
[[ "$(j "d['data']['step']+'|'+str(d['data']['restore_url'])" <<<"$s")" == "run_restore|http://$D/restore.php" ]] \
  && ok 'validated archive: step run_restore with restore_url' || bad "run_restore: ${s:0:600}"
echo more >>"$doc/site_20261110_full_abc.tar.gz"
[[ "$(step)" == validate ]] && ok 'changed archive asks to validate again' || bad "changed archive step: $(step)"

# 2. Simulate the restored site: installed database, archive's own files.
mysql -e "CREATE TABLE \`${db}\`.b_user (ID INT PRIMARY KEY); INSERT INTO \`${db}\`.b_user VALUES (1);
  ALTER DATABASE \`${db}\` COLLATE utf8mb3_general_ci;" || bad 'prepare database'
printf '<?php\nreturn [];\n' >"$doc/bitrix/.settings.php"
printf '%s\n' '<?php' "\$this->queryExecute(\"SET NAMES 'utf8mb4'\");" >"$ac"
chown -R "$owner" "$doc"
sed -i 's#location ~ /\\.(?!well-known/|default/) {#location ~ /\\.(?!well-known/) {#' "$conf" && nginx -t >/dev/null 2>&1 && systemctl reload nginx
rm -f "$opc"; systemctl reload php8.3-fpm 2>/dev/null || true
sed -i '/process_control_timeout/d' "$fpm"
cli site php-ini-unset --domain "$D" --name date.timezone --apply yes --confirm yes >/dev/null 2>&1 || true
# No time zone anywhere PHP-FPM reads (php.ini, conf.d, the pool).
grep -rlE '^[[:space:]]*date\.timezone' /etc/php/8.3/fpm | xargs -r sed -i -E '/^[[:space:]]*date\.timezone/d'
sed -i '/date.timezone/d' /etc/php/8.3/fpm/pool.d/bxchecks-test.conf
# UTC under another name is the same zone.
settz() { timedatectl set-timezone "$1" 2>/dev/null || { ln -sf "/usr/share/zoneinfo/$1" /etc/localtime && echo "$1" >/etc/timezone; }; }
settz Etc/UTC
[[ "$(cli site check-state --domain "$D" --id bitrix.timezone --output json 2>/dev/null | j "d['data']['state']")" == ok ]] \
  && ok 'PHP UTC and server Etc/UTC agree' || bad 'UTC alias'
# Server zone Europe/Moscow (MySQL follows it); PHP left at its UTC default.
settz Europe/Moscow

s=$(cli bitrix status --domain "$D" --output json 2>/dev/null)
[[ "$(j "d['data']['step']" <<<"$s")" == finalize ]] && ok 'restored site: step finalize' || bad "finalize step: ${s:0:600}"
p=$(j "','.join(d['data']['pending'])" <<<"$s")
[[ "$p" == *bitrix.docroot-leftovers* && "$p" == *bitrix.db-session-modes* && "$p" == *bitrix.db-charset* ]] \
  && ok "status lists pending finalize rules ($p)" || bad "pending: $p"

d1=$(doctor)
[[ "$(j "d['data']['profile']" <<<"$d1")" == bitrix ]] && ok 'doctor answer names the profile' || bad 'doctor profile'
for r in bitrix.docroot-leftovers:FAIL bitrix.dot-default:FAIL bitrix.db-session-modes:WARN bitrix.db-charset:WARN \
         bitrix.timezone:WARN bitrix.opcache:WARN php.fpm-graceful-reload:WARN; do
  k=${r%%:*}; want=${r#*:}
  got=$(j "next((c['status']+'|'+str(c.get('fix'))+'|'+str(bool(c.get('since'))) for c in d['data']['checks'] if c.get('key')=='$k'), 'absent')" <<<"$d1")
  [[ "$got" == "$want|$k|True" ]] && ok "doctor: $k $want with fix and since" || bad "doctor $k: $got"
done
[[ "$(j "next(c.get('fix') for c in d['data']['checks'] if c.get('key')=='bitrix.sef-fallback')" <<<"$d1")" == None ]] \
  && ok 'a keyed rule without a fix has fix null' || bad 'sef-fallback fix'
since1=$(j "next(c['since'] for c in d['data']['checks'] if c.get('key')=='bitrix.db-charset')" <<<"$d1")
sleep 1
[[ "$(doctor | j "next(c['since'] for c in d['data']['checks'] if c.get('key')=='bitrix.db-charset')")" == "$since1" ]] \
  && ok 'since stays the first time a rule failed' || bad 'since moved'

# 3. check-state, check-fix plans and refusals.
st=$(cli site check-state --domain "$D" --id bitrix.db-charset --output json 2>/dev/null)
[[ "$(j "d['data']['state']+'|'+str(d['data']['refusal'])+'|'+str(bool(d['data']['plan']))" <<<"$st")" == 'needed|None|True' ]] \
  && ok 'check-state: needed, with a plan line' || bad "check-state: ${st:0:400}"
[[ "$(cli site check-fix --domain "$D" --id bitrix.db-charset --output json 2>/dev/null | j "d['status']")" == planned ]] \
  && ok 'check-fix without confirm is a plan' || bad 'check-fix plan'
[[ "$(cli site check-fix --domain "$D" --id bitrix.sef-fallback --output json 2>/dev/null | j "d['status']")" == failed ]] \
  && ok 'check-fix refuses a rule without a fix' || bad 'check-fix unknown'
[[ "$(cli site check-state --domain "$D" --id bitrix.nope --output json 2>/dev/null | j "d['data']['refusal']")" == unknown_check ]] \
  && ok 'check-state names unknown_check' || bad 'unknown_check'

# 4. Panel gateway.
cli panel gate-enable --confirm yes >/tmp/sc-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/sc-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req site:check-fix "{\"domain\":\"$D\",\"id\":\"bitrix.db-session-modes\"}")")
[[ "$(j "d['kind']+'|'+d['data']['check']['id']+'|'+str(bool(d['data']['check']['plan']))" <<<"$a")" == 'plan|bitrix.db-session-modes|True' ]] \
  && ok 'gateway check-fix plan carries title and plan line' || bad "gateway plan: ${a:0:500}"
a=$(gate "$(req site:check-fix "{\"domain\":\"$D\",\"id\":\"bitrix.nope\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:unknown_check ]] && ok 'gateway refuses unknown_check' || bad "unknown: $a"
a=$(gate "$(req bitrix:status "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']+'|'+d['data']['step']" <<<"$a")" == ok\|finalize ]] && ok 'gateway bitrix:status step' || bad "gateway status: ${a:0:400}"
a=$(gate "$(req bitrix:finalize "{\"domain\":\"$D\"}")")
[[ "$(j "d['kind']" <<<"$a")" == plan ]] && ok 'gateway bitrix:finalize plans' || bad "gateway finalize: ${a:0:400}"
a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D\",\"archive\":\"../x.tar.gz\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:invalid_argument ]] && ok 'gateway refuses an archive path' || bad "archive path: $a"
cli profile disable --id wordpress --confirm yes >/dev/null 2>&1
a=$(gate "$(req site:add '{"domain":"wp.test","profile":"wordpress"}')")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:profile_disabled ]] && ok 'gateway refuses a disabled profile' || bad "disabled profile: ${a:0:300}"
a=$(gate "$(req site:check-fix "{\"domain\":\"$D\",\"id\":\"bitrix.db-session-modes\"}" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a")
for _ in $(seq 1 60); do
  st=$(gate "$(req job:status "{\"job_id\":\"$jid\"}")" | j "d['data']['state']" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok 'gateway check-fix job succeeds' || bad "gateway job: $st"
grep -q "innodb_strict_mode=0" "$ac" && ok 'the job fixed session modes' || bad 'session modes not fixed by job'
a=$(gate "$(req site:check-fix "{\"domain\":\"$D\",\"id\":\"bitrix.db-session-modes\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:check_ok ]] && ok 'gateway refuses check_ok after the fix' || bad "check_ok: $a"

# 5. Every remaining fix through the CLI.
for k in bitrix.docroot-leftovers bitrix.dot-default bitrix.db-charset bitrix.timezone bitrix.opcache php.fpm-graceful-reload; do
  cli site check-fix --domain "$D" --id "$k" --confirm yes >"/tmp/sc-fix-$k.out" 2>&1 && ok "check-fix $k" || { bad "check-fix $k"; tail -15 "/tmp/sc-fix-$k.out"; }
done
[[ ! -e $doc/site_20261110_full_abc.tar.gz && ! -e $doc/restore.php && -f $root/restore-archive/restore.php ]] \
  && ok 'leftovers moved out of the web root' || { bad 'leftovers'; ls -la "$doc" "$root/restore-archive"; }
grep -qF 'location ~ /\.(?!well-known/|default/) {' "$conf" && ok '.default rule restored' || bad '.default rule'
[[ "$(mysql -NBe "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}'")" == utf8mb4 ]] \
  && ok 'database default is utf8mb4' || bad 'db charset'
grep -q '^date.timezone=' "/etc/simai-env/sites/$D/php.ini" && ok 'timezone set for the site' || { bad 'timezone'; cat "/tmp/sc-fix-bitrix.timezone.out"; cat "/etc/simai-env/sites/$D/php.ini"; }
[[ -f $opc ]] && grep -q '^process_control_timeout' "$fpm" && ok 'OPcache baseline and graceful reload back' || bad 'host fixes'
d2=$(doctor)
[[ "$(j "sorted({c['status'] for c in d['data']['checks'] if c.get('fix')})" <<<"$d2")" == "['PASS']" ]] \
  && ok 'every fixable rule passes after the fixes' || bad "after: $(j "[(c['key'],c['status']) for c in d['data']['checks'] if c.get('fix') and c['status']!='PASS']" <<<"$d2")"
[[ "$(j "[c['since'] for c in d['data']['checks'] if c.get('fix')]" <<<"$d2")" == "[None, None, None, None, None, None, None]" ]] \
  && ok 'since clears when a rule passes' || bad 'since after pass'
[[ "$(step)" == "done" ]] && ok 'bitrix status: step done' || bad "step done: $(step)"
[[ "$(cli site check-fix --domain "$D" --id bitrix.db-charset --output json 2>/dev/null | j "d['status']")" == failed ]] \
  && ok 'CLI plan refuses a rule that already holds' || bad 'check_ok CLI'

cli site remove --domain "$D" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
echo "failures=$fails"; exit "$fails"

#!/usr/bin/env bash
# Database access (1.59.0): site db-credentials (CLI shows the password,
# the gateway hands it out once and never logs it), site db-rotate on
# WordPress and Bitrix rewrites the password in wp-config.php,
# bitrix/.settings.php and dbconn.php (other 'password' keys untouched) and
# the site keeps connecting; a configuration with another password is
# refused in the plan and nothing changes; db:list for the panel.
set -uo pipefail
rm -rf /root/simai-env-dba
cp -r /src /root/simai-env-dba
cd /root/simai-env-dba || exit 1
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
http() { curl -s -H "Host: $1" "http://127.0.0.1$2"; }
envv() { sed -n "s/^$2=//p" "/etc/simai-env/sites/$1/db.env"; }
for p in wordpress bitrix generic; do cli profile enable --id $p --confirm yes >/dev/null 2>&1; done

# WordPress: a wp-config.php with the site's password and a page that connects with it.
W=dbawp.test
cli site add --domain $W --profile wordpress --php 8.3 --create-db yes --confirm yes >/tmp/dba-wp 2>&1 || { bad 'wp site add'; tail -5 /tmp/dba-wp; }
WR=/home/simai/www/$W; wdoc=$WR/public; [[ -d $wdoc ]] || wdoc=$WR
wown=$(stat -c %U:%G $WR)
cat >$wdoc/wp-config.php <<PHP
<?php
define( 'DB_NAME', '$(envv $W DB_NAME)' );
define( 'DB_USER', '$(envv $W DB_USER)' );
define( 'DB_PASSWORD', '$(envv $W DB_PASS)' );
define( 'DB_HOST', 'localhost' );
PHP
cat >$wdoc/dbcheck.php <<'PHP'
<?php
require __DIR__ . '/wp-config.php';
$c = @mysqli_connect(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
echo $c ? "DB-OK\n" : "DB-FAIL\n";
PHP
chown $wown $wdoc/wp-config.php $wdoc/dbcheck.php
[[ "$(http $W /dbcheck.php)" == DB-OK* ]] && ok 'wp page connects before' || bad "wp before: $(http $W /dbcheck.php | head -c 200)"

# Credentials.
cli site db-credentials --domain $W --confirm yes >/tmp/dba-cred 2>&1 && grep -q "$(envv $W DB_PASS)" /tmp/dba-cred && ok 'CLI shows the password' || bad "credentials: $(tail -5 /tmp/dba-cred)"
grep -q "$(envv $W DB_PASS)" /var/log/simai-admin.log && bad 'password in the admin log' || ok 'password not in the admin log'

old=$(envv $W DB_PASS)
cli site db-rotate --domain $W >/tmp/dba-plan 2>&1; grep -q 'wp-config.php' /tmp/dba-plan || grep -q 'Rerun with --confirm yes' /tmp/dba-plan && ok 'rotate plan' || bad "plan: $(tail -3 /tmp/dba-plan)"
cli site db-rotate --domain $W --confirm yes >/tmp/dba-rot 2>&1 && ok 'rotate wordpress' || { bad 'rotate wordpress'; tail -8 /tmp/dba-rot; }
new=$(envv $W DB_PASS)
[[ -n "$new" && "$new" != "$old" ]] && grep -q "'DB_PASSWORD', '$new'" $wdoc/wp-config.php && ok 'wp-config.php has the new password' || bad "wp-config: $(grep DB_PASSWORD $wdoc/wp-config.php)"
[[ "$(stat -c %U:%G $wdoc/wp-config.php)" == "$wown" ]] && ok 'wp-config.php keeps its owner' || bad 'owner changed'
[[ "$(http $W /dbcheck.php)" == DB-OK* ]] && ok 'wp page connects after rotation' || bad "wp after: $(http $W /dbcheck.php | head -c 200)"
grep -q "$new" /tmp/dba-rot && bad 'new password printed' || ok 'new password not printed'

# Another password in the configuration: refused, nothing changes.
sed -i "s/'DB_PASSWORD', '$new'/'DB_PASSWORD', 'SomethingElse99'/" $wdoc/wp-config.php
cli site db-rotate --domain $W --confirm yes >/tmp/dba-mis 2>&1 && bad 'mismatched config rotated' || { grep -q 'another database password' /tmp/dba-mis && ok 'a config with another password is refused' || bad "mismatch: $(tail -3 /tmp/dba-mis)"; }
[[ "$(envv $W DB_PASS)" == "$new" ]] && ok 'db.env unchanged after the refusal' || bad 'db.env changed'
cli site db-rotate --domain $W >/tmp/dba-mis-plan 2>&1 && bad 'plan of a mismatched config passed' || ok 'the plan already refuses it'
sed -i "s/'DB_PASSWORD', 'SomethingElse99'/'DB_PASSWORD', '$new'/" $wdoc/wp-config.php

# Bitrix: .settings.php (and a cache password that must stay) and dbconn.php.
B=dbabx.test
cli site add --domain $B --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/dba-bx 2>&1 || { bad 'bitrix site add'; tail -5 /tmp/dba-bx; }
BR=/home/simai/www/$B; bdoc=$BR/public; [[ -d $bdoc/bitrix || ! -d $bdoc ]] || true; [[ -d $bdoc ]] || bdoc=$BR
bown=$(stat -c %U:%G $BR)
mkdir -p $bdoc/bitrix/php_interface
bp=$(envv $B DB_PASS)
cat >$bdoc/bitrix/.settings.php <<PHP
<?php
return array (
  'connections' => array ('value' => array ('default' => array (
    'className' => '\\\\Bitrix\\\\Main\\\\DB\\\\MysqliConnection',
    'host' => 'localhost', 'database' => '$(envv $B DB_NAME)', 'login' => '$(envv $B DB_USER)',
    'password' => '$bp', 'options' => 2))),
  'cache' => array ('value' => array ('type' => 'redis', 'password' => 'CacheSecret77')),
);
PHP
printf '<?php\n$DBType = "mysql";\n$DBPassword = "%s";\n' "$bp" >$bdoc/bitrix/php_interface/dbconn.php
cat >$bdoc/dbcheck.php <<'PHP'
<?php
$s = include __DIR__ . '/bitrix/.settings.php';
$d = $s['connections']['value']['default'];
$c = @mysqli_connect($d['host'], $d['login'], $d['password'], $d['database']);
echo $c ? "DB-OK\n" : "DB-FAIL\n";
PHP
chown -R $bown $bdoc/bitrix $bdoc/dbcheck.php
[[ "$(http $B /dbcheck.php)" == DB-OK* ]] && ok 'bitrix page connects before' || bad "bx before: $(http $B /dbcheck.php | head -c 200)"
cli site db-rotate --domain $B --confirm yes >/tmp/dba-bxr 2>&1 && ok 'rotate bitrix' || { bad 'rotate bitrix'; tail -8 /tmp/dba-bxr; }
bn=$(envv $B DB_PASS)
[[ "$bn" != "$bp" ]] && grep -q "'password' => '$bn'" $bdoc/bitrix/.settings.php && grep -q "\$DBPassword = \"$bn\"" $bdoc/bitrix/php_interface/dbconn.php \
  && ok '.settings.php and dbconn.php have the new password' || bad "bx files: $(grep -h -i password $bdoc/bitrix/.settings.php $bdoc/bitrix/php_interface/dbconn.php)"
grep -q "'password' => 'CacheSecret77'" $bdoc/bitrix/.settings.php && ok 'the cache password is untouched' || bad 'cache password changed'
[[ "$(http $B /dbcheck.php)" == DB-OK* ]] && ok 'bitrix page connects after rotation' || bad "bx after: $(http $B /dbcheck.php | head -c 200)"

# A site without a database.
cli site add --domain dbanodb.test --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1
cli site db-credentials --domain dbanodb.test --confirm yes >/tmp/dba-nodb 2>&1 && bad 'credentials of a site without a database' || ok 'a site without a database is refused'

# Gateway: the password once, never in the log; db:list.
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
[[ "$(gate "$(req site:db-credentials "{\"domain\":\"$W\"}")" | j "d['status']+'/'+d.get('kind','')")" == ok/plan ]] && ok 'gateway plan' || bad 'gateway plan'
job=$(gate "$(req site:db-credentials "{\"domain\":\"$W\"}" ',"confirm":true')" | j "d.get('job_id','')")
for _ in $(seq 1 60); do
  a=$(gate "$(req job:status "{\"job_id\":\"$job\"}")")
  st=$(j "d['data']['state']" <<<"$a" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$(j "(d['data']['result'] or {}).get('db_password','')" <<<"$a")" == "$(envv $W DB_PASS)" && "$(j "d['data']['result']['database']" <<<"$a")" == "$(envv $W DB_NAME)" ]] \
  && ok 'gateway hands the password out' || bad "gateway result: [$st] $(j "d['data']['result']" <<<"$a" 2>&1 | head -c 200)"
[[ -z "$(gate "$(req job:status "{\"job_id\":\"$job\"}")" | j "(d['data']['result'] or {}).get('db_password','')")" ]] && ok 'only once' || bad 'password shown twice'
gate "$(req job:log "{\"job_id\":\"$job\"}")" | grep -q "$(envv $W DB_PASS)" && bad 'password in the job log' || ok 'password not in the job log'
[[ "$(gate "$(req db:list '{}')" | j "sorted(x['site'] for x in d['data']['databases'] if x['site'] in ('$W','$B'))")" == "['$B', '$W']" ]] && ok 'db:list lists the site databases' || bad 'db:list'

for s in $W $B dbanodb.test; do cli site remove --domain $s --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/dev/null 2>&1; done
echo "failures=$fails"; exit "$fails"

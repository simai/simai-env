#!/usr/bin/env bash
# Extra databases of a site (1.70.0): site db-extra-add / db-extra-drop /
# db-extra-list on MySQL and PostgreSQL (<main>_<name>, the site's own user
# and password, recorded as DB_EXTRA in db.env), refusals of bad, taken,
# too long and foreign names (also in the plan and through the panel
# gateway), site describe / self describe / db-credentials / db:list show the
# names, db-rotate keeps the record, backup data dumps each extra database,
# data-verify --restore-test checks it, data-restore brings it back (creating
# it when missing), old backups without extras still verify and restore,
# db-extra-drop takes a last backup first, site remove drops the extras too.
set -uo pipefail
rm -rf /root/simai-env-xdb
cp -r /src /root/simai-env-xdb
cd /root/simai-env-xdb || exit 1
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
envv() { sed -n "s/^$2=//p" "/etc/simai-env/sites/$1/db.env"; }
myq() { mysql -N -B -e "$1" 2>/dev/null; }
# As the site's database user (its own password).
myuser() { MYSQL_PWD="$(envv "$1" DB_PASS)" mysql -N -B -u "$(envv "$1" DB_USER)" -h localhost "$2" -e "$3"; }
pgq() { runuser -u postgres -- psql -X -At -c "$1" "${2:-postgres}" 2>/dev/null; }
pguser() { PGPASSWORD="$(envv "$1" DB_PASS)" psql -X -At -h 127.0.0.1 -U "$(envv "$1" DB_USER)" -d "$2" -c "$3"; }
resum() { (cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf "%f\n" | sort | xargs sha256sum >SHA256SUMS); }
latest() { ls -1d "/var/backups/simai/$1"/2* 2>/dev/null | sort | tail -n1; }
cli profile enable --id generic --confirm yes >/dev/null 2>&1

# --- MySQL ---------------------------------------------------------------
M=xdbm.test
cli site add --domain $M --profile generic --php 8.3 --create-db yes --confirm yes >/tmp/xdb-add 2>&1 \
  && ok 'mysql site add' || { bad 'mysql site add'; tail -8 /tmp/xdb-add; }
MAIN=$(envv $M DB_NAME); MUSER=$(envv $M DB_USER)
# A backup from before any extra database (old layout).
cli backup data --domain $M --confirm yes >/tmp/xdb-b0 2>&1 && B0=$(latest $M) && ok 'backup before extras' || { bad 'backup b0'; tail -5 /tmp/xdb-b0; }
sleep 1

for n in Bad-Name 'a b' abcdefghijklmnopq ''; do
  cli site db-extra-add --domain $M --name "$n" --confirm yes >/tmp/xdb-bad 2>&1 && bad "bad name '$n' accepted" || ok "bad name '$n' refused"
done
cli site db-extra-add --domain $M --name 'x;drop' >/tmp/xdb-badplan 2>&1 && bad 'plan of a bad name passed' || ok 'the plan refuses a bad name'
cli site db-extra-add --domain $M --name logs >/tmp/xdb-plan 2>&1
grep -q "Create database ${MAIN}_logs" /tmp/xdb-plan && grep -q 'Rerun with --confirm yes' /tmp/xdb-plan && ok 'add prints a plan' || bad "plan: $(tail -5 /tmp/xdb-plan)"
[[ -z "$(myq "SHOW DATABASES LIKE '${MAIN}_logs'")" ]] && ok 'the plan changed nothing' || bad 'plan created the database'
cli site db-extra-add --domain $M --name logs --confirm yes >/tmp/xdb-a1 2>&1 && ok 'db-extra-add logs' || { bad 'db-extra-add'; tail -8 /tmp/xdb-a1; }
[[ "$(myq "SHOW DATABASES LIKE '${MAIN}_logs'")" == "${MAIN}_logs" ]] && ok 'database created' || bad 'database missing'
[[ "$(envv $M DB_EXTRA)" == logs ]] && ok 'db.env records DB_EXTRA=logs' || bad "DB_EXTRA: $(envv $M DB_EXTRA)"
[[ "$(stat -c %a /etc/simai-env/sites/$M/db.env)" == 640 ]] && ok 'db.env stays 0640' || bad 'db.env mode'
[[ -z "$(myq "SELECT User FROM mysql.user WHERE User LIKE '${MUSER}%' AND User <> '${MUSER}'")" ]] && ok 'no new database user' || bad 'a new user appeared'
myuser $M "${MAIN}_logs" "CREATE TABLE events (id INT PRIMARY KEY, msg VARCHAR(20)); INSERT INTO events VALUES (1,'one'),(2,'two');" \
  && ok 'site user writes to the extra database with its own password' || bad 'site user cannot use the extra database'
grep -q "$(envv $M DB_PASS)" /tmp/xdb-a1 && bad 'password printed by db-extra-add' || ok 'no password in the output'

cli site db-extra-add --domain $M --name logs --confirm yes >/tmp/xdb-dup 2>&1 && bad 'duplicate accepted' || { grep -q 'already has the extra database' /tmp/xdb-dup && ok 'duplicate refused' || bad "dup: $(tail -3 /tmp/xdb-dup)"; }
myq "CREATE DATABASE \`${MAIN}_foreign\`"
cli site db-extra-add --domain $M --name foreign --confirm yes >/tmp/xdb-for 2>&1 && bad 'a foreign database was adopted' || { grep -q 'already exists on this server' /tmp/xdb-for && ok 'an existing foreign database is refused' || bad "foreign: $(tail -3 /tmp/xdb-for)"; }
myq "DROP DATABASE \`${MAIN}_foreign\`"

# Too long: a 60-character main database name leaves room for 4 characters.
L=xdbl.test
LONG=$(printf 'l%.0s' $(seq 1 60))
cli site add --domain $L --profile generic --php 8.3 --create-db yes --db-name "$LONG" --confirm yes >/tmp/xdb-l 2>&1 || { bad 'long site add'; tail -5 /tmp/xdb-l; }
cli site db-extra-add --domain $L --name abcde --confirm yes >/tmp/xdb-long 2>&1 && bad 'too long name accepted' || { grep -q 'allows 64' /tmp/xdb-long && ok 'a name over 64 characters is refused' || bad "long: $(tail -3 /tmp/xdb-long)"; }
cli site db-extra-add --domain $L --name abc --confirm yes >/tmp/xdb-long2 2>&1 && ok 'a name of exactly 64 characters is fine' || { bad 'exact 64'; tail -3 /tmp/xdb-long2; }
cli site remove --domain $L --remove-files yes --drop-db yes --drop-db-user yes --last-backup no --confirm yes >/dev/null 2>&1
[[ -z "$(myq "SHOW DATABASES LIKE '${LONG}%'")" ]] && ok 'long site remove dropped main and extra' || bad "long left: $(myq "SHOW DATABASES LIKE '${LONG}%'")"

# Listing and describing.
cli site db-extra-add --domain $M --name cache --confirm yes >/dev/null 2>&1 || bad 'add cache'
[[ "$(envv $M DB_EXTRA)" == logs,cache ]] && ok 'two extras recorded' || bad "DB_EXTRA: $(envv $M DB_EXTRA)"
l=$(cli site db-extra-list --domain $M --output json 2>/dev/null)
[[ "$(j "[i['database'] for i in d['data']['items']]" <<<"$l")" == "['${MAIN}_logs', '${MAIN}_cache']" && "$(j "d['data']['engine']" <<<"$l")" == mysql ]] \
  && ok 'db-extra-list JSON' || bad "list: $(head -c 400 <<<"$l")"
cli site db-extra-list --domain $M 2>&1 | grep "${MAIN}_cache .*present" >/dev/null && ok 'db-extra-list human' || bad 'list human'
s=$(cli site describe --domain $M --output json 2>/dev/null)
[[ "$(j "d['data']['database']['extra']" <<<"$s")" == "['${MAIN}_logs', '${MAIN}_cache']" ]] && ok 'site describe shows the extra databases' || bad "describe: $(j "d['data']['database']" <<<"$s" 2>&1 | head -c 300)"
grep -q "$(envv $M DB_PASS)" <<<"$s" && bad 'password in site describe' || ok 'no password in site describe'
h=$(cli self describe --output json 2>/dev/null)
[[ "$(j "[x['database']['extra'] for x in d['data']['sites'] if x['domain'] == '$M'][0]" <<<"$h")" == "['${MAIN}_logs', '${MAIN}_cache']" ]] \
  && ok 'self describe shows the extra databases' || bad "self describe: $(head -c 300 <<<"$h")"
cli site db-credentials --domain $M --confirm yes >/tmp/xdb-cred 2>&1
grep -q "${MAIN}_logs, ${MAIN}_cache (same user and password)" /tmp/xdb-cred && ok 'db-credentials names the extras' || { bad 'credentials'; tail -15 /tmp/xdb-cred; }
cli site db-status --domain $M >/tmp/xdb-st 2>&1
grep -q "DB_EXTRA  : ${MAIN}_logs, ${MAIN}_cache" /tmp/xdb-st && ok 'db-status names the extras' || { bad 'db-status'; tail -15 /tmp/xdb-st; }
dl=$(cli db list --output json 2>/dev/null)
[[ "$(j "[r['kind'] for r in d['data']['databases'] if r['name'] == '${MAIN}_logs']" <<<"$dl")" == "['extra']" ]] && ok 'db list has the extra database' || bad "db list: $(head -c 300 <<<"$dl")"
cli site db-rotate --domain $M --confirm yes >/tmp/xdb-rot 2>&1 || { bad rotate; tail -5 /tmp/xdb-rot; }
[[ "$(envv $M DB_EXTRA)" == logs,cache ]] && ok 'db-rotate keeps DB_EXTRA' || bad "after rotate: $(envv $M DB_EXTRA)"
[[ "$(myuser $M "${MAIN}_logs" 'SELECT COUNT(*) FROM events')" == 2 ]] && ok 'the new password opens the extra database' || bad 'extra after rotate'

# Backup, verify, restore.
cli backup data --domain $M --confirm yes >/tmp/xdb-b1 2>&1 && ok 'backup data with extras' || { bad 'backup'; tail -5 /tmp/xdb-b1; }
B1=$(latest $M)
[[ -f $B1/db-extra-logs.sql.gz && -f $B1/db-extra-cache.sql.gz ]] && ok 'a dump per extra database' || bad "files: $(ls $B1)"
grep -qx 'db_extra=logs,cache' $B1/manifest.txt && ok 'manifest lists the extras' || bad "manifest: $(cat $B1/manifest.txt)"
grep -q 'db-extra-logs.sql.gz' $B1/SHA256SUMS && ok 'checksums cover the extra dumps' || bad 'SHA256SUMS'
cli backup data-verify --path $B1 --restore-test yes --confirm yes >/tmp/xdb-v1 2>&1 && ok 'verify with restore test' || { bad 'verify'; tail -8 /tmp/xdb-v1; }
grep -q 'PASS restore test of extra database logs (1 tables' /tmp/xdb-v1 && grep -q 'PASS db-extra-cache.sql.gz integrity' /tmp/xdb-v1 \
  && ok 'restore test covers the extra databases' || bad "verify out: $(cat /tmp/xdb-v1)"
bl=$(cli backup data-list --domain $M --output json 2>/dev/null)
[[ "$(j "d['data']['items'][0]['extra_databases']" <<<"$bl")" == "['logs', 'cache']" ]] && ok 'data-list shows the extras of a backup' || bad "data-list: $(head -c 300 <<<"$bl")"
# A corrupt extra dump fails the check.
cp -a $B1 /root/xdb-corrupt && printf 'junk' >/root/xdb-corrupt/db-extra-logs.sql.gz && resum /root/xdb-corrupt
cli backup data-verify --path /root/xdb-corrupt --confirm yes >/dev/null 2>&1 && bad 'a corrupt extra dump passed' || ok 'a corrupt extra dump fails verification'
rm -f /root/xdb-corrupt/db-extra-logs.sql.gz && resum /root/xdb-corrupt
cli backup data-verify --path /root/xdb-corrupt --confirm yes >/dev/null 2>&1 && bad 'a missing extra dump passed' || ok 'a listed but missing extra dump fails verification'
rm -rf /root/xdb-corrupt

myuser $M "${MAIN}_logs" 'DELETE FROM events'
myq "DROP DATABASE \`${MAIN}_cache\`"
cli backup data-restore --domain $M --path $B1 --files no >/tmp/xdb-rp 2>&1
cli backup data-restore --domain $M --path $B1 --files no --confirm yes >/tmp/xdb-r1 2>&1 && ok 'data-restore with extras' || { bad 'restore'; tail -8 /tmp/xdb-r1; }
[[ "$(myuser $M "${MAIN}_logs" 'SELECT COUNT(*) FROM events')" == 2 ]] && ok 'rows of the extra database are back' || bad 'extra rows not restored'
[[ "$(myq "SHOW DATABASES LIKE '${MAIN}_cache'")" == "${MAIN}_cache" ]] && myuser $M "${MAIN}_cache" 'SELECT 1' >/dev/null \
  && ok 'a missing extra database is created on restore, for the site user' || bad 'cache not recreated'
grep -q "Extra database ${MAIN}_cache restored" /tmp/xdb-r1 && ok 'restore names the extra databases' || bad "restore out: $(tail -5 /tmp/xdb-r1)"

# The old backup (no extras) still verifies and restores; extras stay.
cli backup data-verify --path $B0 --restore-test yes --confirm yes >/tmp/xdb-v0 2>&1 && ok 'old backup without extras verifies' || { bad 'verify b0'; tail -5 /tmp/xdb-v0; }
cli backup data-restore --domain $M --path $B0 --files no --confirm yes >/tmp/xdb-r0 2>&1 && ok 'old backup without extras restores' || { bad 'restore b0'; tail -5 /tmp/xdb-r0; }
[[ "$(myuser $M "${MAIN}_logs" 'SELECT COUNT(*) FROM events')" == 2 ]] && ok 'extras untouched by an old restore' || bad 'old restore touched extras'

# Drop.
cli site db-extra-drop --domain $M --name nope --confirm yes >/tmp/xdb-dn 2>&1 && bad 'unknown name dropped' || { grep -q 'has no extra database named nope' /tmp/xdb-dn && ok 'drop of an unknown name refused' || bad "unknown: $(tail -3 /tmp/xdb-dn)"; }
cli site db-extra-drop --domain $M --name logs >/tmp/xdb-dp 2>&1
grep -q 'First: last backup' /tmp/xdb-dp && [[ -n "$(myq "SHOW DATABASES LIKE '${MAIN}_logs'")" ]] && ok 'drop prints a plan and keeps the database' || bad "drop plan: $(tail -5 /tmp/xdb-dp)"
cli site db-extra-drop --domain $M --name logs --confirm yes >/tmp/xdb-d1 2>&1 && ok 'db-extra-drop logs' || { bad 'drop'; tail -8 /tmp/xdb-d1; }
[[ -z "$(myq "SHOW DATABASES LIKE '${MAIN}_logs'")" ]] && ok 'extra database dropped' || bad 'still there'
[[ "$(envv $M DB_EXTRA)" == cache ]] && ok 'record updated' || bad "DB_EXTRA: $(envv $M DB_EXTRA)"
[[ -z "$(myq "SELECT Db FROM mysql.db WHERE Db='${MAIN}_logs'")" ]] && ok 'grants on the dropped database are gone' || bad 'grants left'
H=$(latest $M)
grep -qx 'reason=db-extra-drop' $H/manifest.txt && [[ -f $H/db-extra-logs.sql.gz ]] && ok 'a held last backup with the dropped database' || bad "last backup: $(cat $H/manifest.txt 2>/dev/null)"
[[ "$(myuser $M "$MAIN" 'SELECT 1')" == 1 ]] && ok 'main database and user stay' || bad 'main database lost'

# --- Panel gateway ---------------------------------------------------------
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","lang":"ru","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
r=$(gate "$(req site:db-extra-add "{\"domain\":\"$M\",\"name\":\"Bad-Name\"}")")
[[ "$(j "d['status']" <<<"$r")" == refused && "$(j "d['reason']" <<<"$r")" == invalid_argument ]] && ok 'gateway refuses a bad name' || bad "gate bad: $(head -c 300 <<<"$r")"
r=$(gate "$(req site:db-extra-add "{\"domain\":\"$M\",\"name\":\"cache\"}")")
[[ "$(j "d['reason']" <<<"$r")" == name_taken && "$(j "d['message']" <<<"$r")" == "Это имя уже занято." ]] && ok 'gateway plan names name_taken' || bad "gate taken: $(head -c 400 <<<"$r")"
r=$(gate "$(req site:db-extra-drop "{\"domain\":\"$M\",\"name\":\"nope\"}")")
[[ "$(j "d['reason']" <<<"$r")" == name_unknown ]] && ok 'gateway plan names name_unknown' || bad "gate unknown: $(head -c 400 <<<"$r")"
r=$(gate "$(req site:db-extra-add "{\"domain\":\"$M\",\"name\":\"panel\"}")")
[[ "$(j "d['kind']" <<<"$r")" == plan && "$(j "d['data']['title']" <<<"$r")" == "Дополнительная база panel для $M" && "$(j "d['data']['untranslated']" <<<"$r")" == "[]" ]] \
  && ok 'gateway plan in Russian, nothing untranslated' || bad "gate plan: $(head -c 400 <<<"$r")"
job=$(gate "$(req site:db-extra-add "{\"domain\":\"$M\",\"name\":\"panel\"}" ',"confirm":true')" | j "d.get('job_id','')")
st=""
for _ in $(seq 1 120); do
  a=$(gate "$(req job:status "{\"job_id\":\"$job\"}")"); st=$(j "d['data']['state']" <<<"$a" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded && -n "$(myq "SHOW DATABASES LIKE '${MAIN}_panel'")" ]] && ok 'gateway job adds the extra database' || bad "gate job: $st $(head -c 300 <<<"$a")"
r=$(gate "$(req site:db-extra-list "{\"domain\":\"$M\"}")")
[[ "$(j "[i['name'] for i in d['data']['items']]" <<<"$r")" == "['cache', 'panel']" ]] && ok 'gateway lists the extra databases' || bad "gate list: $(head -c 400 <<<"$r")"

cli site remove --domain $M --remove-files yes --drop-db yes --drop-db-user yes --last-backup no --confirm yes >/tmp/xdb-rm 2>&1 || { bad 'mysql site remove'; tail -5 /tmp/xdb-rm; }
[[ -z "$(myq "SHOW DATABASES LIKE '${MAIN}%'")" ]] && ok 'site remove dropped the main and extra databases' || bad "left: $(myq "SHOW DATABASES LIKE '${MAIN}%'")"

# --- site db-drop drops the extras too ---------------------------------------
D2=xdbd.test
cli site add --domain $D2 --profile generic --php 8.3 --create-db yes --confirm yes >/dev/null 2>&1 || bad 'site add d2'
M2=$(envv $D2 DB_NAME)
cli site db-extra-add --domain $D2 --name one --confirm yes >/dev/null 2>&1 || bad 'add one'
cli site db-drop --domain $D2 --last-backup no --confirm yes >/tmp/xdb-dd 2>&1 || { bad 'db-drop'; tail -5 /tmp/xdb-dd; }
[[ -z "$(myq "SHOW DATABASES LIKE '${M2}%'")" && -z "$(envv $D2 DB_EXTRA)" ]] && ok 'site db-drop drops the extras and their record' || bad "db-drop left: $(myq "SHOW DATABASES LIKE '${M2}%'")"
cli site remove --domain $D2 --remove-files yes --confirm yes >/dev/null 2>&1

# --- PostgreSQL ------------------------------------------------------------
cli db pgsql-install --confirm yes >/tmp/xdb-pi 2>&1 || { bad 'pgsql-install'; tail -8 /tmp/xdb-pi; }
P=xdbp.test
cli site add --domain $P --profile generic --php 8.3 --create-db yes --db-engine pgsql --confirm yes >/tmp/xdb-pa 2>&1 \
  && ok 'pgsql site add' || { bad 'pgsql site add'; tail -8 /tmp/xdb-pa; }
PMAIN=$(envv $P DB_NAME); PUSER=$(envv $P DB_USER)
cli site db-extra-add --domain $P --name stats --confirm yes >/tmp/xdb-pe 2>&1 && ok 'pgsql db-extra-add' || { bad 'pgsql add'; tail -8 /tmp/xdb-pe; }
[[ "$(pgq "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='${PMAIN}_stats'")" == "$PUSER" ]] && ok 'the site role owns the extra database' || bad 'owner'
[[ "$(pgq "SELECT has_database_privilege('public','${PMAIN}_stats','CONNECT')")" == f ]] && ok 'PUBLIC cannot connect to the extra database' || bad 'public connect'
pguser $P "${PMAIN}_stats" "CREATE TABLE hits (id int); INSERT INTO hits VALUES (1),(2),(3);" >/dev/null \
  && ok 'site role writes to the extra database with its password' || bad 'pgsql user write'
[[ $((${#PMAIN} + 1 + 16)) -le 63 ]] || bad 'test assumption: short main name'
cli site db-extra-add --domain $P --name stats --confirm yes >/dev/null 2>&1 && bad 'pgsql duplicate accepted' || ok 'pgsql duplicate refused'
cli backup data --domain $P --confirm yes >/tmp/xdb-pb 2>&1 && ok 'pgsql backup with extras' || { bad 'pgsql backup'; tail -5 /tmp/xdb-pb; }
PB=$(latest $P)
cli backup data-verify --path $PB --restore-test yes --confirm yes >/tmp/xdb-pv 2>&1 && grep -q 'PASS restore test of extra database stats (1 tables' /tmp/xdb-pv \
  && ok 'pgsql restore test of the extra database' || { bad 'pgsql verify'; tail -8 /tmp/xdb-pv; }
pgq "DROP DATABASE \"${PMAIN}_stats\" WITH (FORCE)" >/dev/null
cli backup data-restore --domain $P --path $PB --files no --confirm yes >/tmp/xdb-pr 2>&1 && ok 'pgsql restore' || { bad 'pgsql restore'; tail -8 /tmp/xdb-pr; }
[[ "$(pguser $P "${PMAIN}_stats" 'SELECT count(*) FROM hits')" == 3 ]] && ok 'pgsql extra database recreated with its rows, site role reads it' || bad 'pgsql rows'
cli site db-extra-drop --domain $P --name stats --last-backup no --confirm yes >/tmp/xdb-pd 2>&1 && [[ -z "$(pgq "SELECT 1 FROM pg_database WHERE datname='${PMAIN}_stats'")" ]] \
  && ok 'pgsql db-extra-drop' || { bad 'pgsql drop'; tail -5 /tmp/xdb-pd; }
cli site db-extra-add --domain $P --name again --confirm yes >/dev/null 2>&1 || bad 'pgsql add again'
cli site remove --domain $P --remove-files yes --drop-db yes --drop-db-user yes --last-backup no --confirm yes >/tmp/xdb-prm 2>&1 || { bad 'pgsql site remove'; tail -5 /tmp/xdb-prm; }
[[ -z "$(pgq "SELECT 1 FROM pg_database WHERE datname LIKE '${PMAIN}%'")" && -z "$(pgq "SELECT 1 FROM pg_roles WHERE rolname='${PUSER}'")" ]] \
  && ok 'pgsql site remove dropped the extra database and the role' || bad "pgsql left: $(pgq "SELECT datname FROM pg_database WHERE datname LIKE '${PMAIN}%'")"

echo "failures=$fails"; exit $fails

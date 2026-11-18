#!/usr/bin/env bash
# shellcheck disable=SC2088,SC2164  # container test script: loose quoting/cd checks are fine here
# site transfer: a site of owner alpha (database, cron job) moves to owner
# bravo. bravo's SFTP view gets it, alpha's loses it, the site keeps
# answering and its database keeps working; describe shows the new owner.
# Refusals: unknown, blocked and same owner, the panel's own site. Gateway:
# plan with what moves, a named refusal, admin only, a confirmed job.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { COLUMNS=220 ./simai-admin.sh "$@"; }
http() { curl -s -H "Host: $1" "http://127.0.0.1$2"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
D=tr.test
root=/home/simai/www/$D

ssh-keygen -q -t ed25519 -N '' -f /root/ka; ssh-keygen -q -t ed25519 -N '' -f /root/kb
cli owner create --name alpha --pubkey-file /root/ka.pub --confirm yes >/tmp/t-o 2>&1 || { bad "owner create alpha"; tail /tmp/t-o; }
cli owner create --name bravo --pubkey-file /root/kb.pub --confirm yes >/dev/null 2>&1 || bad "owner create bravo"
cli owner create --name gamma --confirm yes >/dev/null 2>&1 || bad "owner create gamma"
cli owner block --name gamma --confirm yes >/dev/null 2>&1 || bad "owner block gamma"
cli site add --domain "$D" --profile generic --php 8.3 --create-db yes --owner alpha --confirm yes >/tmp/t-add 2>&1 \
  || { bad "site add for alpha"; tail -15 /tmp/t-add; }
cli cron job-add --domain "$D" --schedule '*/5 * * * *' --command 'true' --confirm yes >/tmp/t-cron 2>&1 || { bad "cron job-add"; tail /tmp/t-cron; }
grep -qE '^[^#].* alpha ' /etc/cron.d/simai-jobs-tr-test 2>/dev/null && ok "cron job runs as alpha" || bad "cron job user: $(cat /etc/cron.d/simai-jobs-tr-test 2>&1 | tail -2)"

# The application's database settings live in its own files (like .env).
db_name=$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D/db.env")
db_user=$(sed -n 's/^DB_USER=//p' "/etc/simai-env/sites/$D/db.env")
db_pass=$(sed -n 's/^DB_PASS=//p' "/etc/simai-env/sites/$D/db.env")
mysql -e "CREATE TABLE \`${db_name}\`.t (v VARCHAR(10)); INSERT INTO \`${db_name}\`.t VALUES ('moved');" || bad "seed database"
printf '[db]\nname=%s\nuser=%s\npass=%s\n' "$db_name" "$db_user" "$db_pass" >"$root/db.ini"
cat >"$root/public/p.php" <<'PHP'
<?php $c = parse_ini_file(dirname(__DIR__) . "/db.ini");
try { $p = new PDO("mysql:host=localhost;dbname={$c['name']}", $c['user'], $c['pass']);
  echo posix_getpwuid(posix_geteuid())["name"], ":", $p->query("SELECT v FROM t")->fetchColumn(); }
catch (Throwable $e) { echo "ERR ", $e->getMessage(); }
PHP
chown alpha:alpha "$root/db.ini" "$root/public/p.php"; chmod 0600 "$root/db.ini"
[[ "$(http "$D" /p.php)" == "alpha:moved" ]] && ok "site answers as alpha with its database" || bad "before: $(http "$D" /p.php)"

sshopt=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
sftp_ls() { printf 'ls -1 /home/%s/sites\n' "$1" | sftp "${sshopt[@]}" -i "$2" -b - "$1@127.0.0.1" 2>/dev/null; }
sftp_get() { printf 'get %s/public/p.php /tmp/t-get.%s\n' "$root" "$1" | sftp "${sshopt[@]}" -i "$2" -b - "$1@127.0.0.1" >/dev/null 2>&1; }
sftp_ls alpha /root/ka | grep -q "$D" && ok "alpha's SFTP view lists the site" || bad "alpha sftp before"
sftp_get alpha /root/ka && ok "alpha reads the site over SFTP" || bad "alpha sftp get before"

# Refusals.
cli site transfer --domain "$D" --owner nosuch >/tmp/t-r1 2>&1 && bad "unknown owner accepted" || { grep -q 'does not exist' /tmp/t-r1 && ok "unknown owner refused" || bad "unknown owner: $(cat /tmp/t-r1)"; }
cli site transfer --domain "$D" --owner gamma >/tmp/t-r2 2>&1 && bad "blocked owner accepted" || { grep -q 'is blocked' /tmp/t-r2 && ok "blocked owner refused" || bad "blocked owner: $(cat /tmp/t-r2)"; }
cli site transfer --domain "$D" --owner alpha --confirm yes >/tmp/t-r3 2>&1 && bad "same owner accepted" || { grep -q 'already belongs' /tmp/t-r3 && ok "same owner refused" || bad "same owner: $(cat /tmp/t-r3)"; }
install -d /etc/simai-env; echo "PANEL_DOMAIN=$D" >>/etc/simai-env/panel.env
cli site transfer --domain "$D" --owner bravo --confirm yes >/tmp/t-r4 2>&1 && bad "panel site accepted" || { grep -q "panel's own site" /tmp/t-r4 && ok "panel's own site refused" || bad "panel site: $(cat /tmp/t-r4)"; }
sed -i "/^PANEL_DOMAIN=${D}\$/d" /etc/simai-env/panel.env
[[ "$(cat "/etc/simai-env/site-users/tr-test")" == alpha ]] && ok "refusals changed nothing" || bad "registry changed by a refusal"

# Plan lists what moves and changes nothing.
cli site transfer --domain "$D" --owner bravo >/tmp/t-plan 2>&1
grep -q 'transfer from owner alpha to owner bravo' /tmp/t-plan && grep -q 'backup data' /tmp/t-plan \
  && grep -q "/home/bravo/sites/$D appears" /tmp/t-plan && grep -q "/home/alpha/sites/$D is removed" /tmp/t-plan \
  && grep -q 'PHP-FPM pool' /tmp/t-plan && grep -q 'cron jobs' /tmp/t-plan && grep -q "database ${db_name}" /tmp/t-plan \
  && ok "plan lists files, pool, cron, SFTP and database" || { bad "plan text"; cat /tmp/t-plan; }
[[ "$(stat -c %U "$root")" == alpha ]] && ok "plan changed nothing" || bad "plan changed the owner"

# Transfer while the site keeps answering.
( errs=0; for _ in $(seq 1 600); do [[ "$(http "$D" /p.php)" == *:moved ]] || errs=$((errs+1)); [[ -f /tmp/t-stop ]] && break; sleep 0.1; done; echo "$errs" >/tmp/t-errs ) &
poller=$!
cli site transfer --domain "$D" --owner bravo --confirm yes >/tmp/t-mv 2>&1 && ok "transfer to bravo" || { bad "transfer"; tail -25 /tmp/t-mv; }
touch /tmp/t-stop; wait "$poller"; rm -f /tmp/t-stop
errs=$(cat /tmp/t-errs); [[ "$errs" -le 2 ]] && ok "site kept answering during the transfer (failed requests: $errs)" || bad "site down during transfer: $errs failed requests"
ls /var/backups/simai/"$D"/*/db.sql.gz >/dev/null 2>&1 && ok "backup with database taken first" || bad "no backup: $(ls -R /var/backups/simai/"$D" 2>&1 | head)"

[[ "$(cat /etc/simai-env/site-users/tr-test)" == bravo ]] && ok "registry names bravo" || bad "registry"
[[ "$(stat -c '%U:%G' "$root")" == bravo:bravo && "$(stat -c '%U' "$root/public/p.php")" == bravo ]] && ok "files belong to bravo" || bad "files: $(stat -c '%U:%G' "$root")"
grep -q '^user = bravo' /etc/php/8.3/fpm/pool.d/tr-test.conf && ok "pool runs as bravo" || bad "pool user"
grep -qE '^[^#].* bravo ' /etc/cron.d/simai-jobs-tr-test && ! grep -qE '^[^#].* alpha ' /etc/cron.d/simai-jobs-tr-test \
  && ok "cron job runs as bravo" || bad "cron: $(cat /etc/cron.d/simai-jobs-tr-test)"
[[ "$(http "$D" /p.php)" == "bravo:moved" ]] && ok "site answers as bravo, database works" || bad "after: $(http "$D" /p.php)"
[[ -L "/home/bravo/sites/$D" && ! -e "/home/alpha/sites/$D" ]] && ok "~/sites link moved" || bad "links: $(ls -l /home/*/sites)"
sftp_ls bravo /root/kb | grep -q "$D" && ok "bravo's SFTP view lists the site" || bad "bravo sftp ls"
sftp_get bravo /root/kb && ok "bravo reads the site over SFTP" || bad "bravo sftp get"
sftp_ls alpha /root/ka | grep -q "$D" && bad "alpha still lists the site" || ok "alpha's SFTP view lost the site"
sftp_get alpha /root/ka && bad "alpha still reads the site" || ok "alpha cannot read the site over SFTP"
id alpha >/dev/null 2>&1 && ok "old owner account kept" || bad "alpha removed"
d=$(cli site describe --domain "$D" --output json 2>/dev/null)
[[ "$(j "d['data'].get('owner') or d['data'].get('site',{}).get('owner')" <<<"$d")" == bravo ]] && ok "site describe shows bravo" || bad "site describe: ${d:0:300}"
d=$(cli self describe --output json 2>/dev/null)
[[ "$(j "[s.get('owner') for s in d['data']['sites'] if s.get('domain')=='$D'][0]" <<<"$d")" == bravo ]] && ok "self describe shows bravo" || bad "self describe"
cli owner remove --name alpha --confirm yes >/dev/null 2>&1 && ok "alpha has no sites left" || bad "alpha still has sites"

# Panel gateway: plan, refusals by name, admin only, a confirmed job to owner delta.
cli owner create --name delta --confirm yes >/dev/null 2>&1 || bad "owner create delta"
cli panel gate-enable --confirm yes >/tmp/t-gate 2>&1 || { bad 'gate-enable'; tail -5 /tmp/t-gate; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"site:transfer","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req null "{\"domain\":\"$D\",\"owner\":\"delta\"}")")
[[ "$(j "d['kind']+'|'+d['data']['transfer']['from_owner']+'|'+d['data']['transfer']['to_owner']+'|'+str(len(d['data']['transfer']['moves'])>3)" <<<"$a")" == 'plan|bravo|delta|True' ]] \
  && ok "gateway plan lists what moves" || bad "gateway plan: ${a:0:600}"
a=$(gate "$(req null "{\"domain\":\"$D\",\"owner\":\"bravo\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:same_owner ]] && ok "gateway refuses same_owner" || bad "gateway same owner: ${a:0:300}"
a=$(gate "$(req null "{\"domain\":\"$D\",\"owner\":\"gamma\"}" ',"confirm":true')")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:owner_blocked ]] && ok "gateway confirm refuses owner_blocked" || bad "gateway blocked: ${a:0:300}"
a=$(gate "$(req '"bravo"' "{\"domain\":\"$D\",\"owner\":\"bravo\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:not_allowed ]] && ok "gateway: owners cannot transfer" || bad "gateway owner: ${a:0:300}"
a=$(gate "$(req null "{\"domain\":\"$D\",\"owner\":\"delta\"}" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a"); st=""
for _ in $(seq 1 120); do
  st=$(gate "$(printf '{"schema":"simai-panel-request/1","request_id":"r2","actor":{"user":"admin@x","owner":null},"command":"job:status","args":{"job_id":"%s"}}' "$jid")" | j "d['data']['state']" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok "gateway transfer job succeeds" || bad "gateway job: $st ${a:0:300}"
[[ "$(cat /etc/simai-env/site-users/tr-test)" == delta && -L "/home/delta/sites/$D" && ! -e "/home/bravo/sites/$D" ]] \
  && ok "job moved the site to delta" || bad "job result: $(cat /etc/simai-env/site-users/tr-test)"
[[ "$(http "$D" /p.php)" == "delta:moved" ]] && ok "site answers as delta" || bad "after job: $(http "$D" /p.php)"

# owner create with sites (1.63.1): one job, every site checked first.
E=tr2.test
cli site add --domain "$E" --profile generic --php 8.3 --confirm yes >/tmp/t-e 2>&1 || { bad "site add $E"; tail -5 /tmp/t-e; }
oreq() { printf '{"schema":"simai-panel-request/1","request_id":"r3","lang":"ru","actor":{"user":"admin@x","owner":null},"command":"owner:create","args":%s%s}' "$1" "${2:-}"; }
a=$(gate "$(oreq "{\"name\":\"echo\",\"sites\":\"$E,nosuch.test\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:site_missing ]] && ! id echo >/dev/null 2>&1 && ok "owner create refuses a missing site, creates nothing" || bad "site_missing: ${a:0:300}"
a=$(gate "$(oreq "{\"name\":\"echo\",\"sites\":\"$E,$D\"}")")
[[ "$(j "(d['data']['title'], d['data']['owner']['new'], [s['domain'] for s in d['data']['owner']['sites']])" <<<"$a")" == "('Новый аккаунт на сервере echo', True, ['$E', '$D'])" ]] \
  && ok "owner create plan lists the sites that move" || bad "owner plan: ${a:0:600}"
a=$(gate "$(oreq "{\"name\":\"echo\",\"sites\":\"$E,$D\"}" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a"); st=""
for _ in $(seq 1 240); do
  st=$(gate "$(printf '{"schema":"simai-panel-request/1","request_id":"r2","lang":"ru","actor":{"user":"admin@x","owner":null},"command":"job:status","args":{"job_id":"%s"}}' "$jid")" | j "d['data']['state']" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok "owner create with sites: one job" || bad "owner job: $st"
[[ "$(cat /etc/simai-env/site-users/tr-test)" == echo && "$(cat /etc/simai-env/site-users/tr2-test)" == echo && -L "/home/echo/sites/$E" && -L "/home/echo/sites/$D" && ! -e "/home/delta/sites/$D" ]] \
  && ok "both sites belong to echo" || bad "after owner create: $(cat /etc/simai-env/site-users/tr-test /etc/simai-env/site-users/tr2-test 2>&1)"
[[ "$(http "$D" /p.php)" == "echo:moved" ]] && ok "site answers as echo" || bad "after owner job: $(http "$D" /p.php)"
cli owner create --name echo --sites "$E,$D" --confirm yes >/tmp/t-again 2>&1 && ok "repeating is harmless (sites already moved)" || { bad "repeat"; tail -5 /tmp/t-again; }

echo "failures=$fails"; exit $fails

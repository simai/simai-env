#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Panel gateway: the panel account reaches simai-env only through one sudo
# rule and one JSON request on stdin; owners see only their own sites;
# actions answer a plan, and with confirm a job; anything else is refused.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }

ssh-keygen -q -t ed25519 -N '' -f /root/own
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
cli site add --domain open.test --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1
cli site add --domain acme.test --profile generic --php 8.3 --create-db no --owner acme --confirm yes >/dev/null 2>&1

cli panel gate-status 2>&1 | grep -q 'Enabled *| no' && ok "gate disabled by default" || bad "gate status before enable"
cli panel gate-enable --confirm yes >/tmp/p-en 2>&1 && ok "panel gate-enable" || { bad "gate-enable"; tail -5 /tmp/p-en; }
cli panel gate-status 2>&1 | grep -q 'Enabled *| yes' && ok "gate status enabled" || bad "gate status after enable"

# Requests as the panel account, through its only sudo rule.
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s}' "$1" "$2" "$3"; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }

a=$(gate "$(req null self:describe '{}')")
[[ "$(field 'd["status"]' <<<"$a")" == ok && "$(field 'len(d["data"]["sites"])' <<<"$a")" == 2 ]] && ok "admin describes the host" || bad "describe: $a"
[[ "$(field 'd["request_id"]' <<<"$a")" == r1 ]] && ok "answer carries the request id" || bad "request id"
a=$(gate "$(req null site:describe '{"domain":"acme.test"}')")
[[ "$(field 'd["data"]["domain"]' <<<"$a")" == acme.test ]] && ok "admin describes any site" || bad "site describe: $a"
a=$(gate "$(req null site:doctor '{"domain":"open.test"}')")
[[ "$(field 'd["status"]' <<<"$a")" == ok && "$(field '"checks" in d["data"]' <<<"$a")" == True ]] && ok "site doctor returns checks" || bad "doctor: ${a:0:300}"
a=$(gate "$(req null self:commands '{}')")
[[ "$(field 'd["status"]' <<<"$a")" == ok ]] && ok "command registry" || bad "commands"

# Owner scope.
a=$(gate "$(req '"acme"' self:describe '{}')")
[[ "$(field '[s["domain"] for s in d["data"]["sites"]]' <<<"$a")" == "['acme.test']" ]] && ok "owner sees only own sites" || bad "owner view: $a"
[[ "$(field '"isolation" in d["data"]' <<<"$a")" == False ]] && ok "owner view hides other owners" || bad "owner isolation leak"
a=$(gate "$(req '"acme"' site:describe '{"domain":"acme.test"}')")
[[ "$(field 'd["status"]' <<<"$a")" == ok ]] && ok "owner describes own site" || bad "owner own site: $a"
a=$(gate "$(req '"acme"' site:describe '{"domain":"open.test"}')")
[[ "$(field 'd["reason"]' <<<"$a")" == owner_scope ]] && ok "owner refused on another site" || bad "owner scope: $a"

# Refusals.
refused() { local a; a=$(gate "$2"); [[ "$(field 'd["status"]+":"+d["reason"]' <<<"$a")" == "refused:$1" ]] && ok "refused $1: $3" || bad "$3: $a"; }
refused not_allowed "$(req null self:bootstrap '{}')" "host repair"
refused not_allowed "$(req null db:drop '{}')" "database server command"
refused not_allowed "$(req null access:reset-password '{}')" "operator command"
refused invalid_argument "$(req null site:describe '{"domain":"x.test; id"}')" "shell metacharacters"
refused invalid_argument "$(req null site:describe '{"domain":"x.test","confirm":"yes"}')" "unknown argument"
refused invalid_argument "$(req null site:describe '{}')" "missing domain"
refused invalid_argument "$(req null site:describe '{"domain":["a.test"]}')" "non-string value"
refused bad_actor "$(req '"../root"' self:describe '{}')" "bad owner name"
refused bad_request 'not json' "malformed request"
refused bad_request '{"schema":"other","request_id":"r1"}' "wrong schema"
refused not_allowed '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"a"},"command":"self:describe","args":{},"confirm":true}' "confirm on a read command"
refused too_large "$(head -c 70000 /dev/zero | tr '\0' ' ')" "oversized request"

# Stage 2: certificate, backups and logs in the answers.
C=/root/tls; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=open.test" -addext "subjectAltName=DNS:open.test" -keyout $C/k.pem -out $C/c.pem >/dev/null 2>&1
cli ssl install --domain open.test --cert $C/c.pem --key $C/k.pem --confirm yes >/dev/null 2>&1
cli backup data-schedule --domain open.test --time 04:15 --keep 3 --confirm yes >/dev/null 2>&1
a=$(gate "$(req null site:describe '{"domain":"open.test"}')")
[[ "$(field 'd["data"]["certificate"]["names"]' <<<"$a")" == "['open.test']" ]] && ok "site card shows certificate names" || bad "certificate: ${a:0:400}"
days=$(field 'd["data"]["certificate"]["days_left"]' <<<"$a")
[[ "$days" -ge 28 && "$days" -le 30 ]] && ok "certificate days left (${days})" || bad "days_left: $days"
[[ "$(field 'd["data"]["backups"]["schedule"]["time"]' <<<"$a")" == 04:15 ]] && ok "backup schedule in the site card" || bad "schedule: $(field 'd["data"]["backups"]' <<<"$a")"
a=$(gate "$(req null self:describe '{}')")
[[ "$(field '[s["certificate"]["valid"] for s in d["data"]["sites"] if s["domain"]=="open.test"][0]' <<<"$a")" == True ]] && ok "host overview shows certificates" || bad "host certificate"
curl -s -o /dev/null -H 'Host: open.test' http://127.0.0.1/panel-probe
a=$(gate "$(req null logs:nginx '{"domain":"open.test","lines":"20"}')")
[[ "$(field 'any("panel-probe" in l for l in d["data"]["lines"])' <<<"$a")" == True ]] && ok "access log tail" || bad "logs: ${a:0:300}"
refused invalid_argument "$(req null logs:nginx '{"domain":"open.test","lines":"5000"}')" "too many log lines"

# Actions: a plan without confirm, a job with it.
a=$(gate "$(req null backup:data '{"domain":"open.test","db":"no"}')")
[[ "$(field 'd["kind"]+":"+d["data"]["lock"]' <<<"$a")" == plan:site ]] && ok "action without confirm answers a plan" || bad "plan: $a"
compgen -G "/var/backups/simai/open.test/*" >/dev/null && bad "plan created a backup" || ok "a plan changes nothing"
refused invalid_argument "$(req null ssl:letsencrypt '{"domain":"open.test"}')" "letsencrypt needs an email"
a=$(gate "$(req null ssl:letsencrypt '{"domain":"open.test","email":"ops@example.com","staging":"yes"}')")
[[ "$(field 'd["kind"]' <<<"$a")" == plan ]] && ok "letsencrypt plan" || bad "le plan: $a"
creq() { printf '{"schema":"simai-panel-request/1","request_id":"r2","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s,"confirm":true}' "$1" "$2" "$3"; }
wait_job() { local s _; for _ in {1..60}; do s=$(gate "$(req "$1" job:status "{\"job_id\":\"$2\"}")" | field 'd["data"]["state"]'); [[ "$s" != running ]] && { echo "$s"; return; }; sleep 1; done; echo timeout; }
a=$(gate "$(creq null backup:data '{"domain":"open.test","db":"no"}')")
job=$(field 'd["job_id"]' <<<"$a")
[[ "$(field 'd["kind"]' <<<"$a")" == job && -n "$job" ]] && ok "confirmed action starts a job" || bad "job start: $a"
[[ "$(wait_job null "$job")" == succeeded ]] && ok "backup job succeeded" || bad "job state"
a=$(gate "$(req null job:log "{\"job_id\":\"$job\"}")")
[[ "$(field 'd["data"]["next"] > 0 and any("open.test" in l for l in d["data"]["lines"])' <<<"$a")" == True ]] && ok "job log" || bad "job log: ${a:0:300}"
n=$(field 'd["data"]["next"]' <<<"$a")
a=$(gate "$(req null job:log "{\"job_id\":\"$job\",\"after\":\"$n\"}")")
[[ "$(field 'len(d["data"]["lines"])' <<<"$a")" == 0 ]] && ok "job log cursor" || bad "cursor"
a=$(gate "$(req null site:describe '{"domain":"open.test"}')")
[[ "$(field 'len(d["data"]["backups"]["items"])' <<<"$a")" == 1 ]] && ok "the new backup is listed" || bad "backup items"
refused not_running "$(req null job:cancel "{\"job_id\":\"$job\"}")" "cancel of a finished job"
[[ "$(gate "$(req null job:list '{}')" | field 'len(d["data"]["jobs"])')" -ge 1 ]] && ok "job list" || bad "job list"
[[ "$(stat -c %a /var/lib/simai-env/panel-jobs)" == 700 ]] && ok "jobs are root-only" || bad "jobs mode"

# Owner jobs: own site only, and admin jobs stay invisible.
refused owner_scope "$(creq '"acme"' backup:data '{"domain":"open.test","db":"no"}')" "owner action on another site"
refused unknown_job "$(req '"acme"' job:status "{\"job_id\":\"$job\"}")" "owner cannot see admin jobs"
a=$(gate "$(creq '"acme"' backup:data '{"domain":"acme.test","db":"no"}')")
ojob=$(field 'd["job_id"]' <<<"$a")
[[ "$(wait_job '"acme"' "$ojob")" == succeeded ]] && ok "owner job on own site" || bad "owner job: $a"
[[ "$(gate "$(req '"acme"' job:list '{}')" | field '[j["job_id"] for j in d["data"]["jobs"]]')" == "['$ojob']" ]] && ok "owner lists only own jobs" || bad "owner job list"

# Cancel a running job.
head -c 400M /dev/urandom >/home/simai/www/open.test/big.bin
a=$(gate "$(creq null backup:data '{"domain":"open.test","db":"no"}')")
cjob=$(field 'd["job_id"]' <<<"$a"); sleep 1
a=$(gate "$(req null job:cancel "{\"job_id\":\"$cjob\"}")")
[[ "$(field 'd["data"]["state"]' <<<"$a")" == cancelled ]] && ok "running job cancelled" || bad "cancel: $a"
systemctl is-active "simai-panel-job-${cjob}" >/dev/null 2>&1 && bad "job unit still running" || ok "job unit stopped"
rm -f /home/simai/www/open.test/big.bin

# Stage 3-4: creating sites, deploying archives, redirects, owners, removing.
job_ok() { local a j; a=$(gate "$2"); j=$(field 'd.get("job_id","")' <<<"$a"); [[ -n "$j" && "$(wait_job "$1" "$j")" == succeeded ]]; }
a=$(gate "$(req null site:add '{"domain":"new.test","profile":"static"}')")
[[ "$(field 'd["kind"]' <<<"$a")" == plan ]] && ok "site add answers a plan" || bad "site add plan: $a"
[[ -f /etc/nginx/sites-available/new.test.conf ]] && bad "plan created the site" || ok "site add plan changes nothing"
job_ok null "$(creq null site:add '{"domain":"new.test","profile":"static"}')" && ok "site add job" || bad "site add job"
gate "$(req null self:describe '{}')" | field '[s["domain"] for s in d["data"]["sites"]]' | grep -q new.test && ok "new site is listed" || bad "new site missing"

mkdir -p /root/rel && echo panel-release >/root/rel/index.html && tar -C /root/rel -czf /root/rel.tgz .
sum=$(sha256sum /root/rel.tgz | cut -d' ' -f1); size=$(stat -c %s /root/rel.tgz)
dreq() { printf '{"schema":"simai-panel-request/1","request_id":"d1","actor":{"user":"admin@x","owner":null},"command":"site:deploy","args":{"domain":"new.test"},"confirm":%s,"attachment":{"sha256":"%s","size":%s}}\n' "$1" "$2" "$3"; }
gate_with() { { printf '%s\n' "$1"; cat "$2"; } | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
a=$(gate "$(dreq false "$sum" "$size")")
[[ "$(field 'd["kind"]' <<<"$a")" == plan ]] && ok "deploy plan without the archive" || bad "deploy plan: $a"
a=$(gate_with "$(dreq true "$sum" "$size")" /root/rel.tgz)
j=$(field 'd.get("job_id","")' <<<"$a")
[[ -n "$j" && "$(wait_job null "$j")" == succeeded ]] && ok "archive deploy through the gateway" || { bad "archive deploy: $a"; gate "$(req null job:log "{\"job_id\":\"$j\"}")" | field '"\n".join(d["data"]["lines"][-8:])'; }
[[ "$(curl -s -H 'Host: new.test' http://127.0.0.1/)" == panel-release ]] && ok "deployed release is served" || bad "release not served"
[[ -z "$(ls /var/lib/simai-env/panel-jobs/"$j"/release.tar.gz 2>/dev/null)" ]] && ok "uploaded archive removed after the job" || bad "archive left behind"
a=$(gate_with "$(dreq true "$(printf '0%.0s' {1..64})" "$size")" /root/rel.tgz)
[[ "$(field 'd["status"]+":"+d["reason"]' <<<"$a")" == refused:attachment_mismatch ]] && ok "refused attachment_mismatch: wrong sha256" || bad "sha mismatch: $a"
a=$(gate_with "$(dreq true "$sum" $((size + 10)))" /root/rel.tgz)
[[ "$(field 'd["reason"]' <<<"$a")" == attachment_mismatch ]] && ok "refused attachment_mismatch: short archive" || bad "short archive: $a"
refused invalid_argument "$(req null site:deploy '{"domain":"new.test"}')" "deploy without archive or git"
refused invalid_argument "$(req null site:deploy '{"domain":"new.test","git":"https://github.com/x/y"}')" "git without ref"
refused invalid_argument "$(req null site:deploy '{"domain":"new.test","git":"ext::sh -c id","ref":"main"}')" "unsafe git url"
refused invalid_argument '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"a","owner":null},"command":"backup:data","args":{"domain":"new.test"},"attachment":{"sha256":"'"$sum"'","size":1}}' "attachment on another command"
a=$(gate_with "$(req null self:describe '{}')" /root/rel.tgz)
[[ "$(field 'd["reason"]' <<<"$a")" == bad_request ]] && ok "refused bad_request: data after a plain request" || bad "trailing data: $a"

job_ok null "$(creq null site:redirect-add '{"domain":"new.test","from":"/old","to":"/","code":"301"}')" && ok "redirect-add job" || bad "redirect-add job"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: new.test' http://127.0.0.1/old)" == 301 ]] && ok "redirect answers 301" || bad "redirect"
refused invalid_argument "$(req null site:redirect-add '{"domain":"new.test","from":"/x;return 200","to":"/"}')" "unsafe redirect path"

# Owners through the panel.
key=$(ssh-keygen -q -t ed25519 -N '' -f /root/beta && cat /root/beta.pub)
job_ok null "$(creq null owner:create "{\"name\":\"beta\",\"pubkey\":\"${key}\"}")" && ok "owner create with a key" || bad "owner create"
[[ "$(gate "$(req null self:describe '{}')" | field '"beta" in [o["name"] for o in d["data"]["isolation"]["owners"]]')" == True ]] && ok "new owner listed" || bad "owner missing"
refused invalid_argument "$(req null owner:create '{"name":"gamma","pubkey":"ssh-ed25519 AAAA\"; id"}')" "malformed public key"
job_ok '"acme"' "$(creq '"acme"' site:add '{"domain":"own.test","profile":"generic","php":"8.3","create-db":"no"}')" && ok "owner creates a site" || bad "owner site add"
[[ "$(gate "$(req null site:describe '{"domain":"own.test"}')" | field 'd["data"]["owner"]')" == acme ]] && ok "owner's new site belongs to the owner" || bad "owner of new site"
refused owner_scope "$(creq '"acme"' site:add '{"domain":"x2.test","profile":"static","owner":"beta"}')" "owner creates a site for another owner"
refused not_allowed "$(creq '"acme"' owner:create '{"name":"evil"}')" "owner creates owners"
refused owner_scope "$(creq '"acme"' site:remove '{"domain":"new.test"}')" "owner removes another site"

job_ok null "$(creq null site:remove '{"domain":"new.test","remove-files":"yes"}')" && ok "site remove job" || bad "site remove"
[[ -f /etc/nginx/sites-available/new.test.conf ]] && bad "site still configured" || ok "site removed"
job_ok null "$(creq null owner:remove '{"name":"beta"}')" && ok "owner remove job" || bad "owner remove"

# Stage 9: capabilities, metrics, PHP, backups, databases and a log filter.
a=$(gate "$(req null self:describe '{}')")
[[ "$(field '"self:metrics" in d["data"]["gate"]["commands"] and "backup:data-restore" in d["data"]["gate"]["commands"]' <<<"$a")" == True ]] && ok "the gate lists its commands" || bad "gate commands: $(field 'd["data"].get("gate")' <<<"$a")"
a=$(gate "$(req '"acme"' self:describe '{}')")
[[ "$(field '"self:metrics" not in d["data"]["gate"]["commands"] and "site:php-ini-set" in d["data"]["gate"]["commands"]' <<<"$a")" == True ]] && ok "an owner's list leaves out admin commands" || bad "owner gate commands"
a=$(gate "$(req null self:metrics '{}')")
[[ "$(field 'd["data"]["cpu"]["cores"] > 0 and d["data"]["memory"]["total_bytes"] > 0 and len(d["data"]["disk"]) > 0' <<<"$a")" == True ]] && ok "server metrics" || bad "metrics: ${a:0:300}"
refused not_allowed "$(req '"acme"' self:metrics '{}')" "owner reads host metrics"
a=$(gate "$(req '"acme"' php:extensions '{"php":"8.3"}')")
[[ "$(field '{e["name"]: e["enabled"] for e in d["data"]["extensions"]}.get("mbstring")' <<<"$a")" == True ]] && ok "PHP extensions" || bad "extensions: ${a:0:300}"

service mysql start >/dev/null 2>&1 || true
cli site add --domain db.test --profile generic --php 8.3 --create-db yes --owner acme --confirm yes >/dev/null 2>&1
dbn=$(sed -n 's/^DB_NAME=//p' /etc/simai-env/sites/db.test/db.env)
mysql -uroot -e "CREATE TABLE \`${dbn}\`.t (id INT PRIMARY KEY); INSERT INTO \`${dbn}\`.t VALUES (1);"
rows() { mysql -uroot -N -e "SELECT COUNT(*) FROM \`${dbn}\`.t"; }

[[ "$(gate "$(req '"acme"' site:php-ini-set '{"domain":"db.test","name":"memory_limit","value":"256M"}')" | field 'd["kind"]')" == plan ]] && ok "php ini plan" || bad "php ini plan"
job_ok '"acme"' "$(creq '"acme"' site:php-ini-set '{"domain":"db.test","name":"memory_limit","value":"256M"}')" && ok "owner sets a PHP setting" || bad "php-ini-set job"
a=$(gate "$(req '"acme"' site:php-ini-list '{"domain":"db.test"}')")
[[ "$(field 'd["data"]["settings"] == [{"key": "memory_limit", "value": "256M", "source": "site"}] and "upload_max_filesize" in d["data"]["editable"]' <<<"$a")" == True ]] && ok "PHP settings listed" || bad "php-ini-list: ${a:0:300}"
grep -q 'php_admin_value\[memory_limit\] = 256M' /etc/php/8.3/fpm/pool.d/db-test.conf && ok "the setting reached the pool" || bad "pool: $(grep -c memory_limit /etc/php/8.3/fpm/pool.d/db-test.conf 2>&1)"
refused invalid_argument "$(req '"acme"' site:php-ini-set '{"domain":"db.test","name":"open_basedir","value":"/"}')" "a PHP setting outside the list"
refused invalid_argument "$(req '"acme"' site:php-ini-set '{"domain":"db.test","name":"memory_limit","value":"99G"}')" "a value outside the rule"
job_ok '"acme"' "$(creq '"acme"' site:php-ini-unset '{"domain":"db.test","name":"memory_limit"}')" && ok "owner removes a PHP setting" || bad "php-ini-unset job"
[[ "$(gate "$(req '"acme"' site:php-ini-list '{"domain":"db.test"}')" | field 'd["data"]["settings"]')" == "[]" ]] && ok "no PHP settings left" || bad "php-ini-list after unset"

job_ok '"acme"' "$(creq '"acme"' backup:data '{"domain":"db.test","files":"no"}')" && ok "database backup" || bad "db backup"
bk=$(gate "$(req '"acme"' site:describe '{"domain":"db.test"}')" | field 'd["data"]["backups"]["items"][0]["path"].rsplit("/", 1)[1]')
[[ "$(gate "$(req '"acme"' backup:data-verify "{\"domain\":\"db.test\",\"backup\":\"${bk}\"}")" | field 'd["kind"]')" == plan ]] && ok "verify plan" || bad "verify plan"
a=$(gate "$(creq '"acme"' backup:data-verify "{\"domain\":\"db.test\",\"backup\":\"${bk}\"}")"); j=$(field 'd["job_id"]' <<<"$a")
[[ "$(wait_job '"acme"' "$j")" == succeeded ]] && gate "$(req '"acme"' job:log "{\"job_id\":\"$j\"}")" | field '"\n".join(d["data"]["lines"])' | grep -q 'PASS restore test' && ok "verify with a restore test" || bad "verify job"
sleep 1; mysql -uroot -e "INSERT INTO \`${dbn}\`.t VALUES (2);"
a=$(gate "$(req '"acme"' backup:data-restore "{\"domain\":\"db.test\",\"backup\":\"${bk}\",\"files\":\"no\"}")")
[[ "$(field 'd["kind"]' <<<"$a")" == plan ]] && ok "restore plan" || bad "restore plan: $a"
job_ok '"acme"' "$(creq '"acme"' backup:data-restore "{\"domain\":\"db.test\",\"backup\":\"${bk}\",\"files\":\"no\"}")" && ok "restore job" || bad "restore job"
[[ "$(rows)" == 1 ]] && ok "the database is back to the backup" || bad "rows after restore: $(rows)"
[[ "$(gate "$(req '"acme"' site:describe '{"domain":"db.test"}')" | field 'len(d["data"]["backups"]["items"])')" == 2 ]] && ok "the state before the restore is a new backup" || bad "safety backup not listed"
refused invalid_argument "$(req '"acme"' backup:data-restore '{"domain":"db.test","backup":"../x"}')" "bad backup name"
refused owner_scope "$(req '"acme"' backup:data-restore "{\"domain\":\"open.test\",\"backup\":\"${bk}\"}")" "owner restores another site"
job_ok '"acme"' "$(creq '"acme"' backup:data-schedule '{"domain":"db.test","time":"02:30","keep":"14"}')" && ok "backup schedule job" || bad "schedule job"
[[ "$(gate "$(req '"acme"' site:describe '{"domain":"db.test"}')" | field 'd["data"]["backups"]["schedule"]["time"] + "/" + d["data"]["backups"]["schedule"]["keep"]')" == "02:30/14" ]] && ok "the schedule is in the site card" || bad "schedule"
refused invalid_argument "$(req '"acme"' backup:data-schedule '{"domain":"db.test","keep":"365"}')" "keep beyond 90"

a=$(gate "$(req null db:list '{}')")
[[ "$(field '[(x["engine"], isinstance(x["size_bytes"], int)) for x in d["data"]["databases"] if x["site"] == "db.test"]' <<<"$a")" == "[('mysql', True)]" ]] && ok "database list" || bad "db:list: ${a:0:300}"
a=$(gate "$(req '"acme"' db:list '{}')")
[[ "$(field 'sorted({x["site"] for x in d["data"]["databases"]})' <<<"$a")" == "['db.test']" ]] && ok "owner sees only own databases" || bad "owner db:list: ${a:0:300}"
grep -qi pass <<<"$a" && bad "database list mentions a password" || ok "no passwords in the database list"
envf=/home/simai/www/db.test/.env; before=$(stat -c '%U:%G %a' "$envf" 2>/dev/null)
job_ok '"acme"' "$(creq '"acme"' site:db-rotate '{"domain":"db.test"}')" && ok "owner rotates the database password" || bad "db-rotate job"
newpass=$(sed -n 's/^DB_PASS=//p' /etc/simai-env/sites/db.test/db.env)
grep -q "^DB_PASSWORD=\"\{0,1\}${newpass}" "$envf" && ok "the new password is in .env" || bad "env not updated"
[[ -z "$before" || "$(stat -c '%U:%G %a' "$envf")" == "$before" ]] && ok ".env keeps its owner" || bad ".env owner: $before -> $(stat -c '%U:%G %a' "$envf")"
grep -rqF -- "$newpass" /var/lib/simai-env/panel-jobs /var/log/simai-panel-gate.log && bad "the password leaked into a log" || ok "the password is in no job log"

curl -s -o /dev/null -H 'Host: open.test' http://127.0.0.1/needle-9 >/dev/null
a=$(gate "$(req null logs:nginx '{"domain":"open.test","match":"needle-9"}')")
[[ "$(field 'len(d["data"]["lines"]) >= 1 and all("needle-9" in l for l in d["data"]["lines"])' <<<"$a")" == True ]] && ok "log filter" || bad "log match: ${a:0:300}"
refused invalid_argument "$(req null logs:nginx '{"domain":"open.test","match":"a\nb"}')" "log filter with a new line"

# Stage 10 (1.30.0): backups by default and checked on schedule, certificate
# renewals, and a site's SFTP accounts (key only).
[[ -f /etc/cron.d/simai-backup-open-test ]] && ok "a new site gets the daily backup" || bad "no default backup schedule"
cli site add --domain nobk.test --profile static --backup no --confirm yes >/dev/null 2>&1
[[ -d /home/simai/www/nobk.test && ! -f /etc/cron.d/simai-backup-nobk-test ]] && ok "backup no skips the schedule" || bad "backup no"
cli site add --domain gone.test --profile static --confirm yes >/dev/null 2>&1
cli site remove --domain gone.test --remove-files yes --confirm yes >/dev/null 2>&1
[[ ! -f /etc/cron.d/simai-backup-gone-test ]] && ok "removing a site drops its backup schedule" || bad "backup cron left after site remove"
job_ok '"acme"' "$(creq '"acme"' backup:data-schedule '{"domain":"db.test","time":"02:30","keep":"14","verify":"yes"}')" && ok "schedule with a check" || bad "schedule verify job"
[[ "$(gate "$(req '"acme"' site:describe '{"domain":"db.test"}')" | field 'd["data"]["backups"]["schedule"]["verify"]')" == True ]] && ok "the check is in the site card" || bad "schedule verify flag"
bash -c "$(grep -v '^#' /etc/cron.d/simai-backup-db-test | cut -d' ' -f7-)" && ok "the scheduled line runs" || bad "scheduled line failed: $(tail -3 /var/log/simai-backup.log)"
a=$(gate "$(req '"acme"' site:describe '{"domain":"db.test"}')")
[[ "$(field 'd["data"]["backups"]["last_verify"]["ok"] and d["data"]["backups"]["last_verify"]["restore_test"] and d["data"]["backups"]["last_verify"]["backup"] == d["data"]["backups"]["items"][0]["path"].rsplit("/", 1)[1]' <<<"$a")" == True ]] && ok "the newest copy was checked with a restore test" || bad "last_verify: $(field 'd["data"]["backups"]' <<<"$a")"
[[ "$(gate "$(req '"acme"' self:describe '{}')" | field '[s["last_verify"]["ok"] for s in d["data"]["sites"] if s["domain"] == "db.test"]')" == "[True]" ]] && ok "the check result is in the site list" || bad "last_verify in the list"
grep -q 'restore-test auto' /etc/cron.d/simai-backup-db-test && ok "a site without a database is checked without a restore test" || bad "verify mode"

C=/root/tls; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=open.test" -addext "subjectAltName=DNS:open.test" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain open.test --cert $C/cert.pem --key $C/key.pem --confirm yes >/dev/null 2>&1
[[ "$(gate "$(req null site:describe '{"domain":"open.test"}')" | field 'd["data"]["certificate"]["last_renew"]')" == None ]] && ok "no renewal recorded yet" || bad "last_renew before"
mkdir -p /var/lib/simai-env/ssl-renew; printf '{"at":"2026-11-01T03:00:00Z","ok":false}\n' >/var/lib/simai-env/ssl-renew/open.test.json
[[ "$(gate "$(req null site:describe '{"domain":"open.test"}')" | field 'd["data"]["certificate"]["last_renew"]')" == "{'at': '2026-11-01T03:00:00Z', 'ok': False}" ]] && ok "a failed renewal is in the certificate facts" || bad "last_renew"

command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
ssh-keygen -q -t ed25519 -N '' -f /root/staff; ssh-keygen -q -t ed25519 -N '' -f /root/staff2
staff=$(cat /root/staff.pub); staff2=$(cat /root/staff2.pub)
sftpk() { sftp -i "$1" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR -b - "$2@127.0.0.1"; }
[[ "$(gate "$(req '"acme"' access:create-project "{\"domain\":\"db.test\",\"login\":\"dbstaff\",\"pubkey\":\"${staff}\"}")" | field 'd["kind"]')" == plan ]] && ok "SFTP account plan" || bad "access plan"
job_ok '"acme"' "$(creq '"acme"' access:create-project "{\"domain\":\"db.test\",\"login\":\"dbstaff\",\"pubkey\":\"${staff}\"}")" && ok "owner creates an SFTP account" || bad "access create job"
[[ "$(getent shadow dbstaff | cut -d: -f2)" == '!'* ]] && ok "the account has no password" || bad "password set: $(getent shadow dbstaff | cut -d: -f2 | head -c 3)"
a=$(gate "$(req '"acme"' access:list '{}')")
[[ "$(field '[(x["login"], x["domain"], x["auth"], x["enabled"], x["sftp_path"]) for x in d["data"]["accesses"]]' <<<"$a")" == "[('dbstaff', 'db.test', 'key', True, '/site')]" ]] && ok "owner lists the site's SFTP accounts" || bad "access list: ${a:0:300}"
printf 'put /etc/hostname /site/up.txt\nls /site\n' | sftpk /root/staff dbstaff >/tmp/sftp1 2>&1 && grep -q up.txt /tmp/sftp1 && ok "SFTP with the key into the site" || bad "sftp: $(tail -3 /tmp/sftp1)"
sudo -u acme cat /home/simai/www/db.test/up.txt >/dev/null && ok "the site reads an uploaded file" || bad "uploaded file not readable by the site"
getfacl -p /home/simai/www/db.test 2>/dev/null | grep -q '^user:simai:' && bad "the shared account got access to an isolated site" || ok "no shared-account access to the isolated site"
refused owner_scope "$(req '"acme"' access:create-project "{\"domain\":\"open.test\",\"login\":\"x-staff\",\"pubkey\":\"${staff}\"}")" "owner creates an account on another site"
refused invalid_argument "$(req '"acme"' access:create-project '{"domain":"db.test","login":"pwstaff","password":"secret123"}')" "an account with a password"
refused invalid_argument "$(req '"acme"' access:create-project '{"domain":"db.test","login":"nokey"}')" "an account without a key"
refused invalid_argument "$(req '"acme"' access:disable '{"login":"site-db-test"}')" "a site user as login"
refused unknown_access "$(req null access:disable '{"login":"nobody1"}')" "an unknown login"
cli access create-global --login globstaff --confirm yes >/dev/null 2>&1
refused not_allowed "$(req null access:disable '{"login":"globstaff"}')" "a global account through the panel"
[[ "$(gate "$(req null access:list '{}')" | field 'sorted(x["login"] for x in d["data"]["accesses"])')" == "['dbstaff', 'globstaff']" ]] && ok "admin lists every account" || bad "admin access list"
[[ "$(gate "$(req '"acme"' access:list '{}')" | field 'len(d["data"]["accesses"])')" == 1 ]] && ok "owner does not see global accounts" || bad "owner sees global"
job_ok '"acme"' "$(creq '"acme"' access:disable '{"login":"dbstaff"}')" && ok "owner disables the account" || bad "access disable"
printf 'ls /site\n' | sftpk /root/staff dbstaff >/dev/null 2>&1 && bad "a disabled account still connects" || ok "a disabled account cannot connect"
job_ok '"acme"' "$(creq '"acme"' access:enable '{"login":"dbstaff"}')" && ok "owner enables the account" || bad "access enable"
printf 'ls /site\n' | sftpk /root/staff dbstaff >/dev/null 2>&1 && ok "the key works again" || bad "enabled key-only account cannot connect"
job_ok '"acme"' "$(creq '"acme"' access:add-key "{\"login\":\"dbstaff\",\"pubkey\":\"${staff2}\"}")" && ok "owner adds a key" || bad "access add-key"
printf 'ls /site\n' | sftpk /root/staff2 dbstaff >/dev/null 2>&1 && ok "the second key connects" || bad "second key"
job_ok '"acme"' "$(creq '"acme"' access:remove '{"login":"dbstaff"}')" && ok "owner removes the account" || bad "access remove"
! getent passwd dbstaff >/dev/null && ok "the account is gone" || bad "dbstaff still exists"
grep -rqF -- "${staff#* }" /var/log/simai-panel-gate.log && bad "a key reached the gate log" || ok "keys are not in the gate log"
cli access remove --login globstaff --confirm yes >/dev/null 2>&1
# A removed account leaves no entry behind: the next user with its uid would
# inherit access to every site.
gacl=$(getfacl -Rcp /home/simai/www 2>/dev/null | grep -E '^(default:)?user:[0-9]+:' | sort -u)
[[ -z "$gacl" ]] && ok "removed accounts leave no access entries on the sites" || bad "stale entries: ${gacl}"

# Site answers, disk and the last backup in one self:describe (stage 2 list).
cli self status-refresh --confirm yes >/dev/null 2>&1 && ok "self status-refresh" || bad "status-refresh"
a=$(gate "$(req null self:describe '{}')")
[[ "$(field 'all(isinstance(s["answers"]["http"], int) and s["answers"]["checked_at"] for s in d["data"]["sites"])' <<<"$a")" == True ]] && ok "every site has an HTTP answer" || bad "answers: $(field '[s.get("answers") for s in d["data"]["sites"]]' <<<"$a")"
[[ "$(field 'all(isinstance(s["disk"]["bytes"], int) for s in d["data"]["sites"])' <<<"$a")" == True ]] && ok "every site has its disk use" || bad "disk: $(field '[s.get("disk") for s in d["data"]["sites"]]' <<<"$a")"
[[ "$(field '[s["last_backup"] is not None for s in d["data"]["sites"] if s["domain"] == "open.test"]' <<<"$a")" == "[True]" ]] && ok "last backup time in the list" || bad "last_backup: $a"
[[ "$(field '[o["sites_disk_bytes"] for o in d["data"]["isolation"]["owners"] if o["name"] == "acme"][0] > 0' <<<"$a")" == True ]] && ok "disk use per owner" || bad "owner disk"
[[ "$(stat -c '%U %a' /var/lib/simai-env/site-status.json)" == "root 644" ]] && ok "status file is root's" || bad "status file: $(stat -c '%U %a' /var/lib/simai-env/site-status.json)"
cli self migrate --confirm yes >/dev/null 2>&1; grep -q 'self status-refresh' /etc/cron.d/simai-site-status && ok "status refreshed by cron" || bad "no status cron"

# Server alerts and load history (1.31.0): kept by the 5-minute status run,
# so they work while the panel is closed or down.
[[ -f /var/lib/simai-env/alerts.json && -s /var/lib/simai-env/metrics-history.jsonl ]] && ok "the status run keeps alerts and history" || bad "no alerts or history file"
mkdir -p /var/lib/simai-env/backup-runs; echo '{"at":"2026-11-01T00:00:00Z","ok":false}' >/var/lib/simai-env/backup-runs/db.test.json
cli self status-refresh --confirm yes >/dev/null 2>&1
a=$(gate "$(req null self:alerts '{}')")
[[ "$(field '[(x["kind"], x["state"], x["domain"]) for x in d["data"]["alerts"] if x["kind"] == "backup_failed"]' <<<"$a")" == "[('backup_failed', 'open', 'db.test')]" ]] && ok "a failed backup opens an alert" || bad "alerts: ${a:0:400}"
a=$(gate "$(req '"acme"' self:alerts '{}')")
[[ "$(field 'all(x["domain"] in ("db.test", "acme.test", "own.test") for x in d["data"]["alerts"]) and "channel" not in d["data"]' <<<"$a")" == True ]] && ok "an owner sees only their sites' alerts" || bad "owner alerts: ${a:0:300}"
rm -f /var/lib/simai-env/backup-runs/db.test.json
pub=$(gate "$(req null site:describe '{"domain":"acme.test"}')" | field 'd["data"]["root"] + "/" + (d["data"]["public_dir"] or "public")')
mkdir -p "$pub"; [[ -f "$pub/index.php" ]] && cp "$pub/index.php" /root/acme-index.bak
echo '<?php http_response_code(503);' >"$pub/index.php"; chmod 0644 "$pub/index.php"
sleep 3  # PHP's opcache rechecks files every two seconds
cli self status-refresh --confirm yes >/dev/null 2>&1
[[ "$(gate "$(req null self:alerts '{}')" | field '[x["state"] for x in d["data"]["alerts"] if x["kind"] == "site_down"]')" == "[]" ]] && ok "one failed check does not alert yet" || bad "site_down after one check"
cli self status-refresh --confirm yes >/dev/null 2>&1
a=$(gate "$(req null self:alerts '{}')")
sid=$(field '[x["id"] for x in d["data"]["alerts"] if x["kind"] == "site_down" and x["domain"] == "acme.test"][0]' <<<"$a")
[[ -n "$sid" && "$(field '[x["message"] for x in d["data"]["alerts"] if x["kind"] == "site_down"][0]' <<<"$a")" == "acme.test answers HTTP 503" ]] && ok "a site answering 503 twice opens an alert" || bad "site_down: ${a:0:400}"
[[ "$(field '[x["state"] for x in d["data"]["alerts"] if x["kind"] == "backup_failed"]' <<<"$a")" == "['resolved']" ]] && ok "a cleared problem is resolved" || bad "backup_failed not resolved"
[[ "$(gate "$(req '"acme"' self:alerts-ack "{\"id\":\"${sid}\"}")" | field 'd["kind"]')" == plan ]] && ok "alert ack plan" || bad "ack plan"
job_ok '"acme"' "$(creq '"acme"' self:alerts-ack "{\"id\":\"${sid}\"}")" && ok "owner acknowledges an alert of their site" || bad "ack job"
[[ "$(gate "$(req null self:alerts '{}')" | field '[(x["state"], x["acked_by"]) for x in d["data"]["alerts"] if x["id"] == "'"$sid"'"]')" == "[('acked', 'admin@x')]" ]] && ok "the alert is acknowledged by the panel user" || bad "acked state"
refused unknown_alert "$(req '"acme"' self:alerts-ack '{"id":"000000000000"}')" "an unknown alert"
if [[ -f /root/acme-index.bak ]]; then cp /root/acme-index.bak "$pub/index.php"; else rm -f "$pub/index.php"; fi
sleep 3
cli self status-refresh --confirm yes >/dev/null 2>&1
[[ "$(gate "$(req null self:alerts '{}')" | field '[x["state"] for x in d["data"]["alerts"] if x["id"] == "'"$sid"'"]')" == "['resolved']" ]] && ok "the site answers again: resolved" || bad "site_down not resolved"

# Delivery: a webhook (a local receiver here) and Telegram, whose token never comes back.
cat >/root/hook.py <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open("/root/hook.log", "ab").write(body + b"\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18999), H).serve_forever()
PY
python3 /root/hook.py & hookpid=$!; sleep 1
job_ok null "$(creq null self:alerts-channel '{"kind":"webhook","target":"http://127.0.0.1:18999/secret-path"}')" && ok "admin sets a webhook" || bad "channel job"
job_ok null "$(creq null self:alerts-test '{}')" && ok "test message job" || bad "alerts-test job"
grep -q '"event": "test"' /root/hook.log 2>/dev/null && ok "the webhook received the test" || bad "webhook: $(cat /root/hook.log 2>&1 | head -c 200)"
a=$(gate "$(req null self:alerts '{}')")
[[ "$(field 'd["data"]["channel"]["kind"] + " " + d["data"]["channel"]["target_hint"]' <<<"$a")" == "webhook http://127.0.0.1:18999/…" ]] && ok "the channel shows without its path" || bad "channel: $(field 'd["data"]["channel"]' <<<"$a")"
grep -q secret-path <<<"$a" && bad "the webhook path leaked" || ok "the webhook path is not shown"
kill $hookpid 2>/dev/null
tok="123456789:AAFakeFakeFakeFakeFakeFakeFakeFake12"
a=$(gate "$(creq null self:alerts-channel "{\"kind\":\"telegram\",\"target\":\"-1001234567\",\"token\":\"${tok}\"}")"); j=$(field 'd["job_id"]' <<<"$a")
[[ "$(wait_job null "$j")" == succeeded ]] && ok "admin sets a Telegram channel" || bad "telegram job"
[[ "$(stat -c '%U %a' /etc/simai-env/alerts-telegram.token)" == "root 600" ]] && ok "the bot token is root-only" || bad "token file mode"
grep -rqF -- "$tok" /var/lib/simai-env/panel-jobs /var/log/simai-panel-gate.log && bad "the bot token is in a job record or log" || ok "the bot token is in no job record or log"
gate "$(req null job:status "{\"job_id\":\"$j\"}")" | grep -qF -- "${tok#*:}" && bad "job status returns the token" || ok "job status hides the token"
gate "$(req null self:alerts '{}')" | grep -qF -- "${tok#*:}" && bad "alerts return the token" || ok "alerts do not return the token"
job_ok null "$(creq null self:alerts-channel '{"kind":"off"}')" && [[ ! -f /etc/simai-env/alerts-telegram.token ]] && ok "channel off removes the token" || bad "channel off"
refused invalid_argument "$(req null self:alerts-channel '{"kind":"webhook","target":"file:///etc/passwd"}')" "a non-HTTP webhook"
refused not_allowed "$(req '"acme"' self:alerts-channel '{"kind":"off"}')" "an owner sets the channel"

a=$(gate "$(req null self:metrics-history '{"period":"day"}')")
[[ "$(field 'd["data"]["step_seconds"] == 300 and len(d["data"]["points"]) >= 3 and d["data"]["points"][-1]["memory_total_bytes"] > 0' <<<"$a")" == True ]] && ok "a day of 5-minute load points" || bad "history day: ${a:0:300}"
[[ "$(gate "$(req null self:metrics-history '{"period":"week"}')" | field 'd["data"]["step_seconds"] == 3600 and len(d["data"]["points"]) >= 1')" == True ]] && ok "a week of hourly points" || bad "history week"
refused not_allowed "$(req '"acme"' self:metrics-history '{"period":"day"}')" "an owner reads the host history"

# Host services and site profiles (1.33.0).
a=$(gate "$(req null service:list '{}')")
[[ "$(field '{s["name"]: s["active"] for s in d["data"]["services"]}.get("nginx")' <<<"$a")" == active ]] && ok "service list shows nginx running" || bad "service list: ${a:0:300}"
[[ "$(field 'any(s["name"].startswith("php") and s["name"].endswith("-fpm") for s in d["data"]["services"])' <<<"$a")" == True ]] && ok "service list shows PHP-FPM" || bad "no php-fpm in the list"
a=$(gate "$(req null service:log '{"name":"nginx","lines":"20"}')")
[[ "$(field 'd["data"]["name"] == "nginx" and isinstance(d["data"]["lines"], list)' <<<"$a")" == True ]] && ok "service log reads the journal" || bad "service log: ${a:0:300}"
[[ "$(gate "$(req null service:restart '{"name":"nginx"}')" | field 'd["kind"]')" == plan ]] && ok "service restart answers a plan" || bad "restart plan"
job_ok null "$(creq null service:reload '{"name":"nginx"}')" && ok "nginx reload job" || bad "nginx reload"
php_unit=$(gate "$(req null service:list '{}')" | field '[s["name"] for s in d["data"]["services"] if s["name"].startswith("php")][0]')
job_ok null "$(creq null service:restart "{\"name\":\"${php_unit}\"}")" && systemctl is-active --quiet "$php_unit" && ok "PHP-FPM restart job" || bad "php-fpm restart"
echo 'this is not nginx;' >/etc/nginx/conf.d/zz-broken.conf
j=$(gate "$(creq null service:restart '{"name":"nginx"}')" | field 'd["job_id"]')
[[ "$(wait_job null "$j")" == failed ]] && systemctl is-active --quiet nginx && ok "a broken nginx config refuses the restart, nginx keeps running" || bad "restart with a broken config"
gate "$(req null job:log "{\"job_id\":\"$j\"}")" | grep -q 'configuration test failed' && ok "the job says why" || bad "broken config log"
rm -f /etc/nginx/conf.d/zz-broken.conf
refused not_allowed "$(req '"acme"' service:restart '{"name":"nginx"}')" "an owner restarts a service"
refused not_allowed "$(req '"acme"' service:list '{}')" "an owner lists services"
refused invalid_argument "$(req null service:restart '{"name":"ssh"}')" "a service outside the list"
a=$(gate "$(req null service:log '{"name":"mariadb"}')")
[[ "$(field 'd["status"]' <<<"$a")" != ok ]] && ok "a service not on this host is not read" || bad "absent service read: ${a:0:200}"

for p in proxy bitrix; do cli profile enable --id "$p" --confirm yes >/dev/null 2>&1 || true; done
a=$(gate "$(req '"acme"' self:profiles '{}')")
ids=$(field 'sorted(p["id"] for p in d["data"]["profiles"])' <<<"$a")
[[ "$ids" == *proxy* && "$ids" == *bitrix* && "$ids" != *alias* ]] && ok "profiles for the wizard: proxy and bitrix, no alias" || bad "profiles: $ids"
[[ "$(field '[a["name"] for p in d["data"]["profiles"] if p["id"] == "proxy" for a in p["args"] if a.get("required")]' <<<"$a")" == "['domain', 'upstream-port']" ]] && ok "proxy needs a domain and an upstream port" || bad "proxy args: $(field '[p for p in d["data"]["profiles"] if p["id"] == "proxy"]' <<<"$a")"
[[ "$(field '[a["values"] for p in d["data"]["profiles"] if p["id"] == "bitrix" for a in p["args"] if a["name"] == "bitrix-files"]' <<<"$a")" == "[['none', 'setup', 'restore']]" ]] && ok "bitrix has its own argument" || bad "bitrix args"
[[ "$(field '[p["php"]["default"] for p in d["data"]["profiles"] if p["id"] == "generic"][0] in d["data"]["php_installed"] and len(d["data"]["php_installed"]) > 0' <<<"$a")" == True ]] && ok "PHP versions come from this host" || bad "php versions: $(field 'd["data"]["php_installed"]' <<<"$a")"

mkdir -p /root/upstream/app && echo upstream-ok >/root/upstream/app/index.html
(cd /root/upstream && exec python3 -m http.server 18777 --bind 127.0.0.1 >/dev/null 2>&1) &
uppid=$!; sleep 1
job_ok null "$(creq null site:add '{"domain":"px.test","profile":"proxy","upstream-port":"18777","upstream-path":"/app/","websockets":"yes"}')" && ok "a proxy site" || bad "proxy site add"
[[ "$(curl -s -H 'Host: px.test' http://127.0.0.1/)" == upstream-ok ]] && ok "the proxy site serves the local service" || bad "proxy answer: $(curl -s -H 'Host: px.test' http://127.0.0.1/ | head -c 200)"
grep -q 'proxy_set_header Upgrade' /etc/nginx/sites-available/px.test.conf && ! grep -q '# *proxy_set_header Upgrade' /etc/nginx/sites-available/px.test.conf && ok "websockets yes upgrades connections" || bad "websocket lines"
job_ok null "$(creq null site:add '{"domain":"px2.test","profile":"proxy","upstream-port":"18777"}')" && grep -q '# *proxy_set_header Upgrade' /etc/nginx/sites-available/px2.test.conf && ok "without websockets the upgrade is off" || bad "proxy without websockets"
j=$(gate "$(creq null site:add '{"domain":"px3.test","profile":"proxy","upstream-port":"443"}')" | field 'd["job_id"]')
[[ "$(wait_job null "$j")" == failed && ! -f /etc/nginx/sites-available/px3.test.conf ]] && ok "the proxy refuses nginx's own port" || bad "proxy to 443"
refused invalid_argument "$(req null site:add '{"domain":"px4.test","profile":"proxy","upstream-port":"8080","upstream-host":"10.0.0.1"}')" "a proxy to another host"
job_ok null "$(creq null site:remove '{"domain":"px.test","remove-files":"yes"}')" && job_ok null "$(creq null site:remove '{"domain":"px2.test","remove-files":"yes"}')" && [[ ! -f /etc/simai-env/sites/px.test/proxy.env ]] && ok "proxy sites are removed with their settings" || bad "proxy remove"
kill "$uppid" 2>/dev/null

# A site's own cron jobs (1.34.0): run as the site user in the site directory.
a=$(gate "$(creq '"acme"' cron:job-add '{"domain":"acme.test","schedule":"*/5 * * * *","command":"echo hello-$(id -un) in $(pwd); echo 50% done"}')"); j=$(field 'd.get("job_id","")' <<<"$a")
[[ "$(wait_job '"acme"' "$j")" == succeeded ]] && ok "owner adds a cron job" || bad "cron job-add: $a"
a=$(gate "$(req '"acme"' cron:list '{"domain":"acme.test"}')")
cid=$(field 'd["data"]["jobs"][0]["id"]' <<<"$a")
[[ "$(field 'd["data"]["jobs"][0]["schedule"] + "|" + str(d["data"]["jobs"][0]["enabled"])' <<<"$a")" == "*/5 * * * *|True" ]] && ok "the list shows the job" || bad "cron list: ${a:0:300}"
line=$(grep -v '^#' /etc/cron.d/simai-jobs-acme-test 2>/dev/null | grep "$cid")
cuser=$(awk '{print $6}' <<<"$line")
[[ -n "$cuser" && "$cuser" != root && "$line" == *"/usr/local/lib/simai-env/cron-job-run acme.test ${cid}" ]] && ok "the cron line runs the wrapper as ${cuser}, never root" || bad "cron line: ${line}"
[[ "$(stat -c '%U %a' /etc/simai-env/cron-jobs/acme.test/jobs.json)" == "root 600" ]] && ok "the job list is root-only" || bad "jobs.json mode"
grep -q '50%' /etc/cron.d/simai-jobs-acme-test && bad "the command reached the cron line" || ok "the command stays out of the cron line"
sudo -u "$cuser" /usr/local/lib/simai-env/cron-job-run acme.test "$cid"
a=$(gate "$(req '"acme"' cron:job-runs "{\"id\":\"${cid}\"}")")
[[ "$(field 'd["data"]["runs"][0]["exit_code"]' <<<"$a")" == 0 && "$(field 'd["data"]["runs"][0]["output"][0]' <<<"$a")" == "hello-${cuser} in /home/simai/www/acme.test" ]] && ok "a run is recorded with its output, as the site user in the site directory" || bad "runs: ${a:0:400}"
[[ "$(gate "$(req '"acme"' cron:list '{"domain":"acme.test"}')" | field 'd["data"]["jobs"][0]["last_run"]["exit_code"]')" == 0 ]] && ok "the list shows the last run" || bad "last run"
a=$(gate "$(creq '"acme"' cron:job-add '{"domain":"acme.test","schedule":"0 3 * * *","command":"echo failing; exit 3"}')"); j=$(field 'd.get("job_id","")' <<<"$a"); wait_job '"acme"' "$j" >/dev/null
fid=$(gate "$(req '"acme"' cron:list '{"domain":"acme.test"}')" | field '[x["id"] for x in d["data"]["jobs"] if "exit 3" in x["command"]][0]')
sudo -u "$cuser" /usr/local/lib/simai-env/cron-job-run acme.test "$fid"
[[ "$(gate "$(req '"acme"' cron:job-runs "{\"id\":\"${fid}\"}")" | field 'd["data"]["runs"][0]["exit_code"]')" == 3 ]] && ok "a failing run keeps its exit code" || bad "failing run"
job_ok '"acme"' "$(creq '"acme"' cron:job-disable "{\"id\":\"${cid}\"}")" && ! grep -q "$cid" /etc/cron.d/simai-jobs-acme-test && ok "a disabled job leaves the cron file" || bad "disable"
job_ok '"acme"' "$(creq '"acme"' cron:job-enable "{\"id\":\"${cid}\"}")" && grep -q "$cid" /etc/cron.d/simai-jobs-acme-test && ok "and comes back when enabled" || bad "enable"
j=$(gate "$(creq '"acme"' cron:job-add '{"domain":"acme.test","schedule":"61 * * * *","command":"true"}')" | field 'd["job_id"]')
[[ "$(wait_job '"acme"' "$j")" == failed ]] && ok "an impossible schedule fails" || bad "schedule 61"
refused invalid_argument "$(req '"acme"' cron:job-add '{"domain":"acme.test","schedule":"* * * * *","command":"-rf /"}')" "a command that starts with a dash"
refused invalid_argument "$(req '"acme"' cron:job-add '{"domain":"acme.test","schedule":"@reboot","command":"true"}')" "a schedule that is not five fields"
refused owner_scope "$(req '"acme"' cron:job-add '{"domain":"open.test","schedule":"* * * * *","command":"true"}')" "an owner adds a job to another site"
cli cron job-add --domain open.test --schedule '0 1 * * *' --command 'true' --confirm yes >/dev/null 2>&1
oid=$(python3 -c 'import json;print(json.load(open("/etc/simai-env/cron-jobs/open.test/jobs.json"))["jobs"][0]["id"])')
refused owner_scope "$(req '"acme"' cron:job-runs "{\"id\":\"${oid}\"}")" "an owner reads another site's job"
refused owner_scope "$(req '"acme"' cron:job-remove "{\"id\":\"${oid}\"}")" "an owner removes another site's job"
refused unknown_cron_job "$(req null cron:job-runs '{"id":"00000000"}')" "an unknown job"
job_ok '"acme"' "$(creq '"acme"' cron:job-remove "{\"id\":\"${fid}\"}")" && [[ ! -e /var/lib/simai-env/cron-runs/acme.test/${fid}.jsonl ]] && ok "removing a job drops its records" || bad "job remove"
cli site remove --domain open.test --remove-files yes --confirm yes >/dev/null 2>&1
[[ ! -e /etc/simai-env/cron-jobs/open.test && ! -e /etc/cron.d/simai-jobs-open-test ]] && ok "a removed site takes its cron jobs along" || bad "jobs after site remove"
cli site add --domain open.test --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1

# Safe update (1.32.0): a plan with versions and checks, then a job that puts
# the previous toolkit back when a site stops answering. A stand-in updater
# replaces the network download: it archives the tree like update.sh and
# changes VERSION; with /root/break-sites it also stops PHP-FPM.
long_job() { local s _; for _ in {1..180}; do s=$(gate "$(req null job:status "{\"job_id\":\"$1\"}")" | field 'd["data"]["state"]'); [[ "$s" != running ]] && { echo "$s"; return; }; sleep 1; done; echo timeout; }
cp update.sh /root/update.sh.real
cat > update.sh <<'UPD'
#!/usr/bin/env bash
set -e
mkdir -p /root/simai-backups
a="/root/simai-backups/simai-env-preupdate-test-$$.tar.gz"
tar -czf "$a" -C "$INSTALL_DIR" .
echo "Pre-update backup created: $a"
[[ -f /root/slow-update ]] && sleep 6
echo 9.9.9 > "$INSTALL_DIR/VERSION"
[[ -f /root/break-sites ]] && systemctl stop 'php*-fpm.service'
echo "Version: old -> 9.9.9"
UPD
chmod +x update.sh
before=$(cat VERSION)
python3 -I lib/site_status.py >/dev/null 2>&1
a=$(gate "$(req null self:update-plan '{"target":"env"}')")
[[ "$(field 'd["data"]["schema"] == "simai-update-plan/1" and d["data"]["current"] == "'"$before"'" and d["data"]["restarts"] == []' <<<"$a")" == True ]] && ok "update plan for simai-env" || bad "env plan: ${a:0:400}"
[[ "$(field '"open.test" in d["data"]["checks"]' <<<"$a")" == True ]] && ok "the plan lists the sites it checks" || bad "plan checks: $(field 'd["data"]["checks"]' <<<"$a")"
a=$(gate "$(req null self:update-plan '{"target":"panel"}')")
[[ "$(field 'd["data"]["blocked"]' <<<"$a")" == not_installed ]] && ok "panel plan without a panel says so" || bad "panel plan: ${a:0:300}"
a=$(gate "$(req null self:update '{"target":"env"}')")
[[ "$(field 'd["kind"] == "plan" and d["data"]["args"]["target"] == "env" and d["data"]["update"]["target"] == "env"' <<<"$a")" == True ]] && ok "update answers a plan with the update details" || bad "update plan: ${a:0:400}"
[[ "$(cat VERSION)" == "$before" ]] && ok "the plan changed nothing" || bad "plan applied"
refused not_allowed "$(req '"acme"' self:update-plan '{"target":"env"}')" "an owner reads the update plan"
refused not_allowed "$(req '"acme"' self:update '{"target":"env"}')" "an owner updates the host"
refused invalid_argument "$(req null self:update '{"target":"all"}')" "an unknown update target"

j=$(gate "$(creq null self:update '{"target":"env"}')" | field 'd["job_id"]')
[[ "$(long_job "$j")" == succeeded && "$(cat VERSION)" == 9.9.9 ]] && ok "update job replaces the toolkit" || { bad "update job: $(cat VERSION)"; gate "$(req null job:log "{\"job_id\":\"$j\"}")" | field '"\n".join(d["data"]["lines"][-15:])'; }
gate "$(req null job:log "{\"job_id\":\"$j\"}")" | grep -q 'still answer' && ok "the job checked the sites after the update" || bad "no site check in the log"
echo "$before" > VERSION

touch /root/slow-update
j=$(gate "$(creq null self:update '{"target":"env"}')" | field 'd["job_id"]')
sleep 2
refused not_cancellable "$(req null job:cancel "{\"job_id\":\"$j\"}")" "cancelling an update midway"
rm -f /root/slow-update
[[ "$(long_job "$j")" == succeeded ]] && ok "the update finished after the refused cancel" || bad "update after cancel"
echo "$before" > VERSION

touch /root/break-sites
j=$(gate "$(creq null self:update '{"target":"env"}')" | field 'd["job_id"]')
[[ "$(long_job "$j")" == failed ]] && ok "an update that breaks sites fails" || bad "broken update state"
cd /root/simai-env  # the rollback put a new directory in place of the one this shell stood in
[[ "$(cat VERSION)" == "$before" ]] && ok "the previous toolkit is back" || bad "not rolled back: $(cat VERSION)"
gate "$(req null job:log "{\"job_id\":\"$j\"}")" | grep -q 'stopped answering after the update: .*open.test' && ok "the log names the sites that stopped" || bad "rollback log"
rm -f /root/break-sites
for u in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}'); do systemctl start "$u" >/dev/null 2>&1; done
cp /root/update.sh.real update.sh

# Blocking an owner: no SSH or panel access, the sites keep serving.
refused not_allowed "$(req '"acme"' owner:block '{"name":"acme"}')" "an owner cannot block"
[[ "$(gate "$(req null owner:block '{"name":"acme"}')" | field 'd["kind"]')" == plan ]] && ok "owner block answers a plan" || bad "block plan"
job_ok null "$(creq null owner:block '{"name":"acme"}')" && ok "owner block job" || bad "owner block"
[[ "$(getent shadow acme | cut -d: -f8)" == 1 ]] && ok "the blocked account has expired" || bad "expiry: $(getent shadow acme | cut -d: -f8)"
refused owner_blocked "$(req '"acme"' self:describe '{}')" "requests as a blocked owner"
[[ "$(gate "$(req null self:describe '{}')" | field '[o["blocked"] for o in d["data"]["isolation"]["owners"] if o["name"] == "acme"]')" == "[True]" ]] && ok "the list shows the block" || bad "blocked flag"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: acme.test' http://127.0.0.1/)" =~ ^[23] ]] && ok "the blocked owner's site keeps serving" || bad "acme.test down"
cli owner list 2>&1 | grep -q 'acme.*blocked' && ok "owner list shows the block" || bad "owner list"
job_ok null "$(creq null owner:unblock '{"name":"acme"}')" && ok "owner unblock job" || bad "owner unblock"
[[ -z "$(getent shadow acme | cut -d: -f8)" ]] && [[ "$(gate "$(req '"acme"' self:describe '{}')" | field 'd["status"]')" == ok ]] && ok "unblocked owner works again" || bad "after unblock"

# DNS-01 through Cloudflare: the token is stored once, root-only, and never shown.
cat >/usr/local/bin/certbot <<'SH'
#!/bin/sh
echo "$*" >>/root/certbot.args
case "$1" in
  plugins) echo "* dns-cloudflare" ;;
  certonly) mkdir -p /etc/letsencrypt/live/open.test
    cp /root/tls/cert.pem /etc/letsencrypt/live/open.test/fullchain.pem
    cp /root/tls/cert.pem /etc/letsencrypt/live/open.test/chain.pem
    cp /root/tls/key.pem /etc/letsencrypt/live/open.test/privkey.pem ;;
esac
exit 0
SH
chmod +x /usr/local/bin/certbot; rm -f /root/certbot.args
cft="cfFakeFakeFakeFakeFakeFakeFakeFake12345"
refused not_allowed "$(req '"acme"' ssl:dns-credentials "{\"provider\":\"cloudflare\",\"token\":\"${cft}\"}")" "an owner stores a DNS token"
refused invalid_argument "$(req null ssl:dns-credentials '{"provider":"cloudflare","token":"short"}')" "a malformed DNS token"
a=$(gate "$(req null ssl:dns-status '{}')")
[[ "$(field 'd["data"]["providers"][0]["configured"]' <<<"$a")" == False ]] && ok "dns status before a token" || bad "dns status: $a"
job_ok null "$(creq null ssl:letsencrypt '{"domain":"open.test","email":"ops@example.com","challenge":"dns"}')" && bad "a DNS challenge ran without a token" || ok "a DNS challenge needs a stored token"
a=$(gate "$(creq null ssl:dns-credentials "{\"provider\":\"cloudflare\",\"token\":\"${cft}\"}")"); j=$(field 'd["job_id"]' <<<"$a")
[[ "$(wait_job null "$j")" == succeeded ]] && ok "admin stores a Cloudflare token" || bad "dns-credentials job: $a"
[[ "$(stat -c '%U %a' /etc/simai-env/dns/cloudflare.ini 2>&1)" == "root 600" ]] && grep -qF "dns_cloudflare_api_token = ${cft}" /etc/simai-env/dns/cloudflare.ini && ok "the token file is root-only" || bad "token file: $(stat -c '%U %a' /etc/simai-env/dns/cloudflare.ini 2>&1)"
grep -rqF -- "$cft" /var/lib/simai-env/panel-jobs /var/log/simai-panel-gate.log && bad "the DNS token is in a job record or log" || ok "the DNS token is in no job record or log"
a=$(gate "$(req null ssl:dns-status '{}')")
[[ "$(field 'd["data"]["providers"][0]["configured"]' <<<"$a")" == True ]] && ! grep -qF -- "$cft" <<<"$a" && ok "dns status shows the token is set, not the token" || bad "dns status after: $a"
a=$(gate "$(creq null ssl:letsencrypt '{"domain":"open.test","email":"ops@example.com","challenge":"dns","staging":"yes"}')"); j=$(field 'd["job_id"]' <<<"$a")
[[ "$(wait_job null "$j")" == succeeded ]] && ok "letsencrypt with a DNS challenge" || bad "dns letsencrypt job: $(gate "$(req null job:log "{\"job_id\":\"$j\"}")" | head -c 600)"
grep -q -- 'certonly --cert-name open.test --dns-cloudflare --dns-cloudflare-credentials /etc/simai-env/dns/cloudflare.ini -d open.test ' /root/certbot.args && ! grep -q -- '--webroot' /root/certbot.args && ok "certbot uses the stored token, no webroot" || bad "certbot args: $(cat /root/certbot.args)"
refused invalid_argument "$(req null ssl:letsencrypt '{"domain":"open.test","email":"ops@example.com","challenge":"tls"}')" "an unknown challenge"
: >/root/certbot.args
cli ssl renew --domain open.test --confirm yes >/tmp/p-dnsrenew 2>&1 && grep -q -- '--dns-cloudflare-credentials /etc/simai-env/dns/cloudflare.ini' /root/certbot.args && ! grep -q -- '\*\.open\.test\|--webroot' /root/certbot.args && ok "renewal keeps the DNS challenge" || bad "dns renew: $(tail -3 /tmp/p-dnsrenew) / $(cat /root/certbot.args)"
job_ok null "$(creq null ssl:dns-credentials '{"provider":"cloudflare","remove":"yes"}')" && [[ ! -f /etc/simai-env/dns/cloudflare.ini ]] && ok "the token can be removed" || bad "dns-credentials remove"
rm -f /usr/local/bin/certbot /root/certbot.args

# The account has no other way in.
sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate extra </dev/null >/dev/null 2>&1 && bad "gateway accepted arguments" || ok "gateway takes no arguments"
sudo -n -u simai-panel sudo -n /root/simai-env/simai-admin.sh self describe >/dev/null 2>&1 && bad "panel account ran simai-admin.sh" || ok "panel account cannot run simai-admin.sh"
sudo -n -u simai-panel sudo -n /bin/true >/dev/null 2>&1 && bad "panel account has wider sudo" || ok "no other sudo rights"
[[ "$(stat -c %a /var/log/simai-panel-gate.log)" == 600 ]] && ok "gateway log is root-only" || bad "log mode"
grep -q '"reason": "owner_scope"' /var/log/simai-panel-gate.log && ok "refusals are logged" || bad "gate log"

# Over SSH with a forced command.
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
ssh-keygen -q -t ed25519 -N '' -f /root/panel
cli panel gate-enable --pubkey-file /root/panel.pub --confirm yes >/tmp/p-ssh 2>&1 && ok "gate-enable with an SSH key" || { bad "gate-enable ssh"; tail -5 /tmp/p-ssh; }
sshp() { ssh -i /root/panel -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR simai-panel@127.0.0.1 "$@"; }
a=$(req null site:describe '{"domain":"open.test"}' | sshp)
[[ "$(field 'd["data"]["domain"]' <<<"$a")" == open.test ]] && ok "request over SSH" || bad "ssh request: $a"
a=$(req null self:describe '{}' | sshp 'id; cat /etc/shadow')
[[ "$(field 'd["status"]' <<<"$a")" == ok ]] && ok "SSH command is ignored, only the gateway runs" || bad "ssh forced command: $a"
cli panel gate-status 2>&1 | grep -q 'SSH keys *| 1' && ok "one SSH key listed" || bad "key count"

cli panel gate-disable --confirm yes >/dev/null 2>&1 && ok "gate-disable" || bad "gate-disable"
gate "$(req null self:describe '{}')" >/dev/null 2>&1 && bad "gateway still reachable" || ok "gateway gone after disable"
req null self:describe '{}' | sshp >/dev/null 2>&1 && bad "SSH still reaches the gateway" || ok "SSH key removed"

echo "failures=${fails}"
exit $(( fails > 0 ))

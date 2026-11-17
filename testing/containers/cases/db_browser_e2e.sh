#!/usr/bin/env bash
# Database browser (site db-browser, 1.58.0): refused without HTTPS, plan
# first, Adminer opens on the site's HTTPS address signed in to the site's
# database only (other databases and users from the address are ignored),
# not over HTTP, not on another token; files readable by the site user only;
# a new opening kills the old address; past the deadline the wrapper answers
# 410 and the status refresh removes it; close and site remove clean up; the
# gateway hands the address out once.
set -uo pipefail
rm -rf /root/simai-env-dbb
cp -r /src /root/simai-env-dbb
cd /root/simai-env-dbb || exit 1
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
D=dbb.test
https() { curl -sk --resolve "$D:443:127.0.0.1" "https://$D$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --resolve "$D:443:127.0.0.1" "https://$D$1"; }
# A closed address falls back to the site's own rules: 404, or 403 where the
# template denies dot paths.
gone() { local c; c=$(code "$1"); [[ "$c" == 404 || "$c" == 403 ]]; }
cli profile enable --id generic --confirm yes >/dev/null 2>&1

cli site add --domain $D --profile generic --php 8.3 --create-db yes --confirm yes >/tmp/dbb-add 2>&1 || { bad 'site add'; tail -5 /tmp/dbb-add; }
db=$(sed -n 's/^DB_NAME=//p' /etc/simai-env/sites/$D/db.env)
mysql -e "CREATE TABLE \`$db\`.notes (id INT PRIMARY KEY, body VARCHAR(50)); INSERT INTO \`$db\`.notes VALUES (1, 'from-the-test');"
project=$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$D.conf | head -n1)

cli site db-browser --domain $D >/tmp/dbb-nossl 2>&1 && bad 'opened without HTTPS' || { grep -q 'HTTPS' /tmp/dbb-nossl && ok 'refused without HTTPS' || bad "refusal: $(tail -2 /tmp/dbb-nossl)"; }
C=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain $D --cert $C/cert.pem --key $C/key.pem --confirm yes >/tmp/dbb-ssl 2>&1 || { bad 'ssl install'; tail -5 /tmp/dbb-ssl; }

cli site db-browser --domain $D --minutes 4 >/dev/null 2>&1 && bad '4 minutes accepted' || ok 'minutes below 5 refused'
cli site db-browser --domain $D >/tmp/dbb-plan 2>&1 && grep -q 'Rerun with --confirm yes' /tmp/dbb-plan && ok 'plan without confirm' || { bad 'plan'; tail -5 /tmp/dbb-plan; }
[[ ! -e /etc/nginx/simai-tools/$project.conf ]] && ok 'the plan changes nothing' || bad 'plan wrote the location'

cli site db-browser --domain $D --confirm yes >/tmp/dbb-open 2>&1 && ok 'open' || { bad 'open'; tail -10 /tmp/dbb-open; }
url=$(grep -o "https://$D/.simai-db/[a-f0-9]*/" /tmp/dbb-open | head -n1)
path=${url#https://$D}
[[ -n "$path" ]] && ok 'address printed' || bad "no address: $(tail -5 /tmp/dbb-open)"
page=$(https "$path")
[[ "$page" == *notes* && "$page" == *"$db"* ]] && ok 'Adminer shows the site database' || bad "page: $(echo "$page" | head -c 400)"
[[ "$(https "${path}?select=notes")" == *from-the-test* ]] && ok 'table rows are shown' || bad 'rows'
other=$(https "${path}?server=127.0.0.1&username=root&db=mysql")
[[ "$other" == *notes* && "$other" != *innodb_index_stats* ]] && ok 'another user or database from the address is ignored' || bad "pinning: $(echo "$other" | head -c 300)"
[[ "$(https "${path}?sqlite=/etc/passwd&username=x")" != *root:x:* ]] && ok 'another driver from the address is ignored' || bad 'sqlite driver reached'
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $D" "http://127.0.0.1${path}")" == 404 ]] && ok 'not over HTTP' || bad 'served over HTTP'
[[ "$(code /.simai-db/0123456789abcdef/)" == 404 ]] && ok 'another token is 404' || bad 'other token'
h=$(curl -sk -D - -o /dev/null --resolve "$D:443:127.0.0.1" "https://$D$path")
[[ "$h" == *"no-referrer"* && "$h" == *"no-store"* && "$h" == *noindex* ]] && ok 'no-referrer, no-store, noindex' || bad "headers: $h"
w=/etc/simai-env/db-browser/$project.php
[[ "$(stat -c '%U %a' $w)" == "root 640" && "$(stat -c %a /etc/simai-env/db-browser/$project.env)" == 600 ]] && ok 'wrapper 640 root, state 600' || bad "perms: $(stat -c '%U:%G %a' $w /etc/simai-env/db-browser/$project.env)"
grep -q "$(sed -n 's/^DB_PASS=//p' /etc/simai-env/sites/$D/db.env)" /tmp/dbb-open && bad 'password printed' || ok 'password not printed'
[[ "$(cli site db-browser-status --domain $D --output json 2>/dev/null | j "d['data']['open'] if 'data' in d else d['open']")" == True ]] && ok 'status: open' || bad "status: $(cli site db-browser-status --domain $D --output json 2>&1 | head -c 300)"

# Opening again: a new address, the old one is gone.
cli site db-browser --domain $D --minutes 30 --confirm yes >/tmp/dbb-again 2>&1 || bad 'open again'
path2=$(grep -o "/.simai-db/[a-f0-9]*/" /tmp/dbb-again | head -n1)
[[ -n "$path2" && "$path2" != "$path" && "$(code "$path2")" == 200 ]] && gone "$path" && ok 'a new opening replaces the old address' || bad "reopen: $path2 $(code "$path") $(code "$path2")"

# Past the deadline: the wrapper refuses, the status refresh removes it.
sed -i -E 's/^if \(time\(\) > [0-9]+\)/if (time() > 1)/' $w
[[ "$(code "$path2")" == 410 ]] && ok 'past the deadline: 410' || bad "deadline: $(code "$path2")"
sed -i -E 's/^EXPIRES=.*/EXPIRES=1/' /etc/simai-env/db-browser/$project.env
SIMAI_ADMIN_MENU=0 timeout 300 bash ./simai-admin.sh self status-refresh --confirm yes >/dev/null 2>&1
[[ ! -e $w && ! -e /etc/nginx/simai-tools/$project.conf ]] && gone "$path2" && ok 'status refresh removes an expired browser' || bad "expired left: $(ls /etc/simai-env/db-browser /etc/nginx/simai-tools 2>&1)"

# Close.
cli site db-browser --domain $D --confirm yes >/tmp/dbb-3 2>&1 || bad 'open 3'
path3=$(grep -o "/.simai-db/[a-f0-9]*/" /tmp/dbb-3 | head -n1)
cli site db-browser-close --domain $D --confirm yes >/dev/null 2>&1 || bad 'close'
[[ ! -e $w ]] && gone "$path3" && ok 'close removes it' || bad 'close left it'
[[ "$(cli site db-browser-status --domain $D --output json 2>/dev/null | j "d['data']['open'] if 'data' in d else d['open']")" == False ]] && ok 'status: closed' || bad 'status closed'

# A site without a database is refused.
cli site add --domain dbbnodb.test --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1
cli site db-browser --domain dbbnodb.test --confirm yes >/tmp/dbb-nodb 2>&1 && bad 'no-db site opened' || { grep -q 'no database' /tmp/dbb-nodb && ok 'a site without a database is refused' || bad "nodb: $(tail -2 /tmp/dbb-nodb)"; }

# Gateway: plan, bad minutes, the address once.
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
[[ "$(gate "$(req site:db-browser "{\"domain\":\"$D\",\"minutes\":\"15\"}")" | j "d['status']+'/'+d.get('kind','')")" == ok/plan ]] && ok 'gateway plan' || bad 'gateway plan'
[[ "$(gate "$(req site:db-browser "{\"domain\":\"$D\",\"minutes\":\"999\"}")" | j "d['status']+'/'+d.get('reason','')")" == refused/invalid_argument ]] && ok 'gateway refuses 999 minutes' || bad 'gateway minutes'
job=$(gate "$(req site:db-browser "{\"domain\":\"$D\"}" ',"confirm":true')" | j "d.get('job_id','')")
# The first answer after the job ends carries the address; later ones do not.
for _ in $(seq 1 60); do
  a=$(gate "$(req job:status "{\"job_id\":\"$job\"}")")
  st=$(j "d['data']['state']" <<<"$a" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
first=$(j "(d['data']['result'] or {}).get('browser_url','')" <<<"$a")
second=$(gate "$(req job:status "{\"job_id\":\"$job\"}")" | j "(d['data']['result'] or {}).get('browser_url','')")
[[ "$first" == https://$D/.simai-db/* && -z "$second" ]] && ok 'gateway hands the address out once' || bad "once: [$st] [$first] [$second]"
gate "$(req job:log "{\"job_id\":\"$job\"}")" | grep -q '.simai-db/[a-f0-9]' && bad 'address in the job log' || ok 'address not in the job log'
[[ "$(gate "$(req site:db-browser-status "{\"domain\":\"$D\"}")" | j "d['data']['open']")" == True ]] && ok 'gateway status read' || bad 'gateway status'

# Site remove takes the browser with it.
cli site remove --domain $D --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/dev/null 2>&1
[[ ! -e /etc/simai-env/db-browser/$project.php && ! -e /etc/nginx/simai-tools/$project.conf ]] && ok 'site remove closes the browser' || bad 'left after remove'
cli site remove --domain dbbnodb.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=$fails"; exit "$fails"

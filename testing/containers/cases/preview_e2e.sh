#!/usr/bin/env bash
# Temporary site link (site preview-link, 1.65.0): plan first; the site opens
# on its own port of the server address only after the key link (cookie);
# HTTPS sites are proxied without a redirect loop; the key never reaches the
# status or site describe; a second call renews (same port and key, new
# deadline); past the deadline the status refresh closes it; close and
# site remove clean up; the gateway hands the link out once.
set -uo pipefail
rm -rf /root/simai-env-pv && cp -r /src /root/simai-env-pv && cd /root/simai-env-pv || exit 1
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
export SIMAI_PREVIEW_IP=127.0.0.1
D=pv.test
cli profile enable --id static --confirm yes >/dev/null 2>&1
cli site add --domain $D --profile static --confirm yes >/tmp/pv-add 2>&1 || { bad 'site add'; tail -5 /tmp/pv-add; }
root=$(cli site describe --domain $D --output json 2>/dev/null | j 'd["data"]["root"]')
pub=$root/public; [[ -d $pub ]] || pub=$root
echo "hello-preview" >"$pub/index.html"
project=$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$D.conf | head -n1)

cli site preview-link --domain $D --minutes 5 >/dev/null 2>&1 && bad '5 minutes accepted' || ok 'minutes below 10 refused'
cli site preview-link --domain $D >/tmp/pv-plan 2>&1 && grep -q 'Rerun with --confirm yes' /tmp/pv-plan && ok 'plan without confirm' || { bad 'plan'; tail -5 /tmp/pv-plan; }
[[ ! -e /etc/simai-env/preview/$project.env ]] && ok 'the plan changes nothing' || bad 'plan opened a link'
out=$(cli site preview-link --domain $D --minutes 30 --confirm yes --output json 2>/dev/null)
url=$(j 'd["data"]["url"]' <<<"$out"); port=$(sed -n 's/^PORT=//p' /etc/simai-env/preview/$project.env)
key=$(sed -n 's/^KEY=//p' /etc/simai-env/preview/$project.env)
[[ "$url" == "http://127.0.0.1:${port}/.simai-preview/${key}" && "$port" -ge 7700 && "$port" -le 7799 ]] && ok 'the link is the server address, a port of the range and the key' || bad "url: $out"
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/)" == 403 ]] && ok 'without the key: 403' || bad 'open without key'
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/.simai-preview/0000)" == 403 ]] && ok 'a wrong key: 403' || bad 'wrong key'
J=$(mktemp)
curl -s -c "$J" -o /dev/null "$url"
[[ "$(curl -s -b "$J" http://127.0.0.1:$port/)" == hello-preview ]] && ok 'after the key link the site opens with the cookie' || bad "site via link: $(curl -s -b "$J" -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/)"
[[ "$(stat -c '%a %U' /etc/nginx/simai-preview/$project.conf) $(stat -c '%a' /etc/simai-env/preview/$project.env)" == "600 root 600" ]] && ok 'the key files are root-only' || bad 'modes'
st=$(cli site preview-link-status --domain $D --output json 2>/dev/null)
[[ "$(j 'd["data"]["preview_link"]["url"]' <<<"$st")" == "http://127.0.0.1:${port}/" && "$st" != *"$key"* ]] && ok 'status shows the address without the key' || bad "status: $st"
ds=$(cli site describe --domain $D --output json 2>/dev/null)
[[ "$(j 'd["data"]["preview_link"]["url"]' <<<"$ds")" == "http://127.0.0.1:${port}/" && "$ds" != *"$key"* ]] && ok 'site describe has preview_link without the key' || bad 'describe preview_link'
exp1=$(sed -n 's/^EXPIRES=//p' /etc/simai-env/preview/$project.env)
sleep 1
r=$(cli site preview-link --domain $D --minutes 60 --confirm yes --output json 2>/dev/null)
[[ "$(j 'd["data"]["renewed"]' <<<"$r")" == True && "$(j 'd["data"]["url"]' <<<"$r")" == "$url" && "$(sed -n 's/^EXPIRES=//p' /etc/simai-env/preview/$project.env)" -gt "$exp1" ]] \
  && ok 'a second call renews: same link, later deadline' || bad "renew: $r"
systemctl list-timers --all 2>/dev/null | grep -q "simai-preview-$project" && ok 'a closing timer runs' || bad 'no timer'

# HTTPS site: proxied over HTTPS, no redirect loop.
C=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain $D --cert $C/cert.pem --key $C/key.pem --redirect yes --confirm yes >/tmp/pv-ssl 2>&1 || { bad 'ssl install'; tail -3 /tmp/pv-ssl; }
cli site preview-link --domain $D --confirm yes >/tmp/pv-renew 2>&1 || { bad 'renew after ssl'; tail -3 /tmp/pv-renew; }
grep -q 'proxy_pass https://' /etc/nginx/simai-preview/$project.conf && ok 'an HTTPS site is proxied over HTTPS' \
  || bad "upstream: $(grep -E 'proxy_pass|listen' /etc/nginx/simai-preview/$project.conf | tr '\n' ' ') site: $(grep -E '^\s*listen' /etc/nginx/sites-available/$D.conf | tr '\n' ' ')"
[[ "$(curl -s -b "$J" --max-redirs 3 -L http://127.0.0.1:$port/)" == hello-preview ]] && ok 'an HTTPS site with a redirect opens through the link' || bad "https: $(curl -s -b "$J" -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1:$port/)"

# Deadline: the status refresh closes it.
sed -i 's/^EXPIRES=.*/EXPIRES=1/' /etc/simai-env/preview/$project.env
cli self status-refresh --confirm yes >/dev/null 2>&1
[[ ! -e /etc/nginx/simai-preview/$project.conf && "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/ 2>/dev/null)" != 200 ]] && ok 'past the deadline the status refresh closes the link' || bad 'not expired'
[[ "$(cli site preview-link-status --domain $D --output json 2>/dev/null | j 'd["data"]["preview_link"]')" == None ]] && ok 'a closed link is null' || bad 'status after close'

# Gateway: plan, a job, the link once.
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
p=$(gate "$(req site:preview-link "{\"domain\":\"$D\",\"minutes\":\"30\"}")")
[[ "$(j "d['kind']+'|'+d['data']['preview']['mode']+'|'+str(d['data']['preview']['renew'])" <<<"$p")" == 'plan|ip_port|False' ]] && ok 'gateway plan names the address mode' || bad "gate plan: $p"
[[ "$(gate "$(req site:preview-link "{\"domain\":\"$D\",\"minutes\":\"5\"}")" | j "d['status']+'/'+d.get('reason','')")" == refused/invalid_argument ]] && ok 'gateway refuses 5 minutes' || bad 'gate minutes'
job=$(gate "$(req site:preview-link "{\"domain\":\"$D\"}" ',"confirm":true')" | j "d.get('job_id','')")
for _ in $(seq 1 60); do a=$(gate "$(req job:status "{\"job_id\":\"$job\"}")"); [[ "$(j "d['data']['state']" <<<"$a")" != running ]] && break; sleep 1; done
first=$(j "(d['data']['result'] or {}).get('preview_url','')" <<<"$a")
second=$(gate "$(req job:status "{\"job_id\":\"$job\"}")" | j "(d['data']['result'] or {}).get('preview_url','')")
[[ "$first" == http://*:77*/.simai-preview/* && ${#first} -gt 50 && -z "$second" ]] && ok 'the gateway hands the link out once' || bad "once: $first / $second"
grep -rq '.simai-preview/[0-9a-f]\{32\}' /var/log/simai-admin.log /var/lib/simai-env/panel-jobs/*/log 2>/dev/null && bad 'the key reached a log' || ok 'the key is in no log'
c=$(gate "$(req site:preview-link-close "{\"domain\":\"$D\"}" ',"confirm":true')" | j "d.get('job_id','')")
for _ in $(seq 1 60); do s=$(gate "$(req job:status "{\"job_id\":\"$c\"}")" | j "d['data']['state']"); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded && ! -e /etc/simai-env/preview/$project.env ]] && ok 'preview-link-close through the gateway' || bad "gate close: $s"
cli panel gate-disable --confirm yes >/dev/null 2>&1

# Site remove takes the link with it.
cli site preview-link --domain $D --confirm yes >/dev/null 2>&1
cli site remove --domain $D --remove-files yes --last-backup no --confirm yes >/dev/null 2>&1
[[ ! -e /etc/simai-env/preview/$project.env && ! -e /etc/nginx/simai-preview/$project.conf ]] && ok 'site remove closes the link' || bad 'left after remove'
echo "failures=$fails"; exit "$fails"

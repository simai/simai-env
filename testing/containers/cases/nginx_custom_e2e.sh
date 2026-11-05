#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# A site's own nginx directives: applied only when nginx accepts them and the
# site still answers, undone unless confirmed in time, kept when confirmed,
# removed with the site; the same through the panel gateway (admin only).
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
show() { cli site nginx-custom-show --domain custom.test --output json 2>/dev/null | js "d['data']$1"; }
body() { curl -s -H 'Host: custom.test' "http://127.0.0.1$1"; }
# An nginx reload takes a moment; wait for the answer $2 at $1.
until_body() { local _; for _ in {1..10}; do [[ "$(body "$1")" == "$2" ]] && return 0; sleep 0.5; done; return 1; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')
conf=/etc/nginx/sites-available/custom.test.conf

cli site add --domain custom.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
project=$(sed -n 's/^# simai-project: *//p' "$conf" | head -1)
file="/etc/nginx/simai-custom/${project}.conf"
[[ "$(show '["present"]')" == False && "$(show '["included"]')" == True ]] && ok "a new site includes its own directives file, empty" || bad "show new"

printf 'location = /custom-check {\n    return 200 "custom-ok";\n}\n' >/tmp/d1
cli site nginx-custom --domain custom.test --content-file /tmp/d1 >/tmp/o 2>&1; [[ ! -e "$file" ]] && ok "without confirm only a plan" || bad "plan wrote"
cli site nginx-custom --domain custom.test --content-file /tmp/d1 --confirm yes >/tmp/o 2>&1 && until_body /custom-check custom-ok \
  && ok "the directives apply" || { bad "apply"; tail -5 /tmp/o; }
id1=$(sed -n 's/.*change confirm --id \([a-f0-9]\{12\}\).*/\1/p' /tmp/o | head -1)
[[ "$(show '["pending_change"]["change_id"]')" == "$id1" && "$(show '["content"]')" == "$(cat /tmp/d1)" ]] && ok "show returns them with the pending change" || bad "show pending"
cli change confirm --id "$id1" --confirm yes >/dev/null 2>&1 && [[ "$(show '["pending_change"]')" == None ]] && ok "change confirm keeps them" || bad "confirm"

# Refused before anything changes: nginx rejects, or the site stops answering.
printf 'no_such_directive on;\n' >/tmp/bad
cli site nginx-custom --domain custom.test --content-file /tmp/bad --confirm yes >/tmp/o 2>&1 && bad "nginx accepted a bad directive" \
  || { grep -q 'no_such_directive' /tmp/o && [[ "$(body /custom-check)" == custom-ok ]] && ok "a directive nginx rejects changes nothing and says why" || { bad "bad directive"; tail -3 /tmp/o; }; }
printf 'return 503;\n' >/tmp/down
cli site nginx-custom --domain custom.test --content-file /tmp/down --confirm yes >/tmp/o 2>&1 && bad "kept directives that take the site down" \
  || { grep -q 'stopped answering' /tmp/o && until_body /custom-check custom-ok && ok "directives that take the site down are undone" || { bad "down"; tail -3 /tmp/o; }; }

# Not confirmed in time: the timer puts the previous directives back.
printf 'location = /custom-check {\n    return 200 "second";\n}\n' >/tmp/d2
cli site nginx-custom --domain custom.test --content-file /tmp/d2 --window 30 --confirm yes >/dev/null 2>&1
until_body /custom-check second && ok "the second version applies" || bad "second"
for _ in {1..30}; do sleep 2; [[ "$(body /custom-check)" == custom-ok ]] && break; done
[[ "$(body /custom-check)" == custom-ok ]] && ok "an unconfirmed change is undone by its timer" || bad "timer undo: $(body /custom-check)"

# A site rendered before 1.41.0 gets the include on first use.
sed -i '/simai-custom\//d' "$conf"; nginx -s reload
cli site nginx-custom --domain custom.test --content-file /tmp/d2 --confirm yes >/tmp/o 2>&1 && grep -qF "simai-custom/${project}[.]conf" "$conf" && until_body /custom-check second \
  && ok "an older vhost gets the include" || { bad "include ensure"; tail -3 /tmp/o; }
cli change confirm --id "$(show '["pending_change"]["change_id"]')" --confirm yes >/dev/null 2>&1
: >/tmp/empty
cli site nginx-custom --domain custom.test --content-file /tmp/empty --confirm yes >/tmp/o 2>&1 && [[ ! -e "$file" && "$(body /custom-check)" != second ]] \
  && ok "empty directives remove the file" || bad "empty"
cli change confirm --id "$(show '["pending_change"]["change_id"]')" --confirm yes >/dev/null 2>&1

# Through the panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
[[ "$(gate "$(req null site:nginx-custom-show '{"domain":"custom.test"}')" | js 'd["data"]["schema"]')" == simai-nginx-custom/1 ]] && ok "site:nginx-custom-show through the gateway" || bad "gate show"
[[ "$(gate "$(req '"acme"' site:nginx-custom-show '{"domain":"custom.test"}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot read nginx directives" || bad "owner show"
[[ "$(gate "$(req null site:nginx-custom '{"domain":"custom.test","content":"gzip on;\n"}')" | js 'd["kind"]')" == plan ]] && ok "site:nginx-custom answers a plan" || bad "gate plan"
a=$(gate "$(req null site:nginx-custom '{"domain":"custom.test","content":"location = /g {\n return 200 \"gate\";\n}\n"}' 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..60}; do st=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")"); s=$(js 'd["data"]["state"]' <<<"$st"); [[ "$s" != running ]] && break; sleep 1; done
cid=$(js 'd["data"]["result"]["change_id"]' <<<"$st")
[[ "$s" == succeeded ]] && until_body /g gate && [[ "$cid" =~ ^[a-f0-9]{12}$ ]] && ok "the job applies them and returns the change id" || bad "gate job: $s ${st:0:300}"
a=$(gate "$(req null change:confirm "{\"change_id\":\"$cid\"}" 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..30}; do s=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded && "$(show '["pending_change"]')" == None ]] && ok "change:confirm keeps them" || bad "gate confirm: $s"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain custom.test --remove-files yes --confirm yes >/dev/null 2>&1
[[ ! -e "$file" ]] && ok "removing the site removes its directives" || bad "file left after site remove"
echo "failures=${fails}"
exit $(( fails > 0 ))

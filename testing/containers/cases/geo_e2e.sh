#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Country blocking: deny and allow lists in their own nftables table, local
# addresses never dropped, risky modes undone unless confirmed, rules kept
# across reboots, lookups, the real DB-IP database, the panel gateway.
# The container's own address stands for a country "ZZ" in a test database.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

D=geo.test
cli site add --domain "$D" --profile static --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["root"]')
echo hello >"$root/public/index.html"
ip=$(hostname -I | awk '{print $1}')
hit() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $D" "http://$1/"; }
printf '%s,%s,ZZ\n10.200.0.0,10.200.255.255,AA\n2001:db8::,2001:db8::ffff,AA\n' "$ip" "$ip" | gzip >/root/geo.csv.gz
export SIMAI_GEO_DB_URL=file:///root/geo.csv.gz SIMAI_GEO_MIN_ROWS=1 SIMAI_GEO_NO_EXEMPT=1
[[ "$(hit "$ip")" == 200 ]] && ok "the site answers before" || bad "site: $(hit "$ip")"

cli security geo --mode deny --countries zz >/tmp/g 2>&1
grep -q 'Plan: drop connections from ZZ' /tmp/g && ! nft list table inet simai_geo >/dev/null 2>&1 && ok "without confirm only a plan" || { bad "plan"; cat /tmp/g; }
cli security geo --mode deny --countries ZZ --confirm yes >/tmp/g 2>&1 && ok "deny ZZ applies" || { bad "deny"; tail -5 /tmp/g; }
[[ "$(hit "$ip")" == 000 ]] && ok "connections from ZZ are dropped" || bad "ZZ not dropped: $(hit "$ip")"
[[ "$(hit 127.0.0.1)" == 200 ]] && ok "this server's loopback is never dropped" || bad "loopback dropped"
s=$(cli security geo-status --output json 2>/dev/null)
[[ "$(js '(d["data"]["mode"], d["data"]["countries"], d["data"]["active"], d["data"]["dropped_packets"] > 0)' <<<"$s")" == "('deny', ['ZZ'], True, True)" ]] \
  && ok "geo-status shows the mode and dropped packets" || bad "status: ${s:0:300}"
[[ "$(js 'd["data"]["attribution"]' <<<"$s")" == *DB-IP* ]] && ok "the database is attributed" || bad "attribution"
systemctl is-enabled simai-geo.service >/dev/null 2>&1 && ok "the rules load again after a reboot" || bad "unit not enabled"
nft delete table inet simai_geo; systemctl restart simai-geo.service
[[ "$(hit "$ip")" == 000 ]] && ok "the boot unit restores the rules" || bad "unit restore"
[[ "$(cli security geo-lookup --ip "$ip" --output json 2>/dev/null | js 'd["data"]["country"]')" == ZZ ]] && ok "geo-lookup finds the country" || bad "lookup"
[[ "$(cli security status --output json 2>/dev/null | js 'd["data"]["geo"]["mode"]')" == deny ]] && ok "security status shows country blocking" || bad "status geo"

# Allow mode can lock out: it is undone unless confirmed.
cli security geo --mode allow --countries AA --window 30 --confirm yes >/tmp/g 2>&1 || bad "allow: $(tail -3 /tmp/g)"
cid=$(sed -n 's/.*Change *| *\([a-f0-9]\{12\}\).*/\1/p' /tmp/g | head -1)
[[ -n "$cid" && "$(hit "$ip")" == 000 ]] && ok "allow AA drops the rest (a timed change)" || bad "allow: $(cat /tmp/g)"
cli change restore --id "$cid" --confirm yes >/dev/null 2>&1
[[ "$(sed -n 's/^MODE=//p' /etc/simai-env/geo/geo.env)" == deny && "$(hit "$ip")" == 000 && "$(hit 127.0.0.1)" == 200 ]] && ok "an unconfirmed change goes back to the previous rules" || bad "restore: $(cat /etc/simai-env/geo/geo.env)"
cli security geo --mode allow --countries ZZ --window 30 --confirm yes >/tmp/g 2>&1
cid=$(sed -n 's/.*Change *| *\([a-f0-9]\{12\}\).*/\1/p' /tmp/g | head -1)
cli change confirm --id "$cid" --confirm yes >/dev/null 2>&1
[[ "$(hit "$ip")" == 200 && "$(sed -n 's/^MODE=//p' /etc/simai-env/geo/geo.env)" == allow ]] && ok "a confirmed allow list stays and lets ZZ in" || bad "confirm"

cli security geo --mode deny --countries RUS --confirm yes >/dev/null 2>&1 && bad "a bad country code accepted" || ok "bad country codes are refused"
cli security geo --mode off --confirm yes >/dev/null 2>&1
! nft list table inet simai_geo >/dev/null 2>&1 && [[ "$(hit "$ip")" == 200 ]] && ! systemctl is-enabled simai-geo.service >/dev/null 2>&1 \
  && ok "off removes the rules" || bad "off"

# The real database.
unset SIMAI_GEO_DB_URL SIMAI_GEO_MIN_ROWS
if cli security geo-update --confirm yes >/tmp/u 2>&1; then
  rows=$(cli security geo-status --output json 2>/dev/null | js 'd["data"]["database"]["rows"]')
  (( rows > 100000 )) && ok "the DB-IP database downloads ($rows ranges)" || bad "rows $rows"
  [[ "$(cli security geo-lookup --ip 8.8.8.8 --output json 2>/dev/null | js 'd["data"]["country"]')" == US ]] && ok "8.8.8.8 is in the US" || bad "lookup 8.8.8.8"
else
  echo "INFO the DB-IP download is unreachable from the container: $(tail -1 /tmp/u)"
fi

# Panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s}' "$1" "$2" "$3"; }
[[ "$(gate "$(req '"acme"' security:geo-status '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot see country blocking" || bad "owner"
[[ "$(gate "$(req null security:geo-status '{}')" | js 'd["data"]["schema"]')" == simai-geo/1 ]] && ok "security:geo-status reads" || bad "gate status"
[[ "$(gate "$(req null security:geo '{"mode":"deny","countries":"CN,KP"}')" | js 'd["kind"]')" == plan ]] && ok "security:geo answers a plan" || bad "gate plan"
[[ "$(gate "$(req null security:geo '{"mode":"deny","countries":"CN;rm"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "bad countries are refused by the gateway" || bad "gate bad"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain "$D" --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

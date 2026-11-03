#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Firewall rules, address blocks and panel access through the panel gateway:
# every change is timed, a confirmed change stays, an unconfirmed one undoes
# itself (by its timer, or by the status refresh when the timer is gone), and
# SSH, HTTP and HTTPS cannot be closed.
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
cli panel gate-enable --confirm yes >/dev/null 2>&1
cli self firewall-ensure --confirm yes >/tmp/fw 2>&1 && ok "firewall enabled" || { bad "firewall-ensure"; tail -5 /tmp/fw; }

gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s}' "$1" "$2" "$3"; }
creq() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s,"confirm":true}' "$1" "$2" "$3"; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
refused() { local a; a=$(gate "$2"); [[ "$(field 'd["status"]+":"+d["reason"]' <<<"$a")" == "refused:$1" ]] && ok "refused $1: $3" || bad "$3: $a"; }
wait_job() {
  local s
  for _ in $(seq 1 60); do
    s=$(gate "$(req null job:status "{\"job_id\":\"$1\"}")" | field 'd["data"]["state"]')
    [[ "$s" == running ]] || { echo "$s"; return; }
    sleep 1
  done
  echo timeout
}
# Runs an action as a job; prints the job's result object (empty when it failed).
job() {
  local a j
  a=$(gate "$(creq null "$1" "$2")"); j=$(field 'd.get("job_id","")' <<<"$a")
  [[ -n "$j" && "$(wait_job "$j")" == succeeded ]] || { echo ""; return 1; }
  gate "$(req null job:status "{\"job_id\":\"$j\"}")" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]["result"] or {}))'
}
status() { gate "$(req null firewall:status '{}')"; }
confirm() { job change:confirm "{\"change_id\":\"$1\"}" >/dev/null; }

a=$(status)
[[ "$(field 'd["data"]["schema"] + "|" + str(d["data"]["active"]) + "|" + str(d["data"]["ssh_ports"])' <<<"$a")" == "simai-firewall/1|True|[22]" ]] && ok "status: ufw active, SSH port" || bad "status: ${a:0:400}"
[[ "$(field '[r["protected"] for r in d["data"]["rules"] if r["port"] == "22"][0]' <<<"$a")" == True ]] && ok "the SSH rule is protected" || bad "ssh rule: ${a:0:400}"
refused not_allowed "$(req '"acme"' firewall:status '{}')" "an owner reads the firewall"

# A confirmed change stays.
r=$(job firewall:rule-add '{"port":"8080","proto":"tcp"}')
cid=$(field 'd["change_id"]' <<<"$r" 2>/dev/null)
[[ "$(field 'd["kind"]' <<<"$r" 2>/dev/null)" == firewall && -n "$cid" ]] && ok "rule-add answers a change id" || bad "rule-add result: $r"
ufw show added | grep -qx 'ufw allow 8080/tcp' && ok "the rule is applied" || bad "8080 not in ufw"
[[ "$(status | field 'd["data"]["pending_change"]["change_id"]')" == "$cid" ]] && ok "status shows the change waiting" || bad "pending change"
systemctl list-timers --all --no-legend | grep -q "simai-change-${cid}" && ok "an undo timer runs" || bad "no undo timer"
refused invalid_argument "$(creq null firewall:rule-add '{"port":"8081","proto":"tcp","window":"30"}')" "the panel cannot set the window"
r=$(job firewall:rule-add '{"port":"8082","proto":"tcp"}'); [[ -z "$r" ]] && ok "a second change waits for the first" || bad "second change while pending: $r"
confirm "$cid" && [[ "$(gate "$(req null change:status "{\"change_id\":\"$cid\"}")" | field 'd["data"]["state"]')" == confirmed ]] && ok "change:confirm keeps it" || bad "confirm"
! systemctl list-timers --all --no-legend | grep -q "simai-change-${cid}" && ok "the timer is gone" || bad "timer still there"
ufw show added | grep -qx 'ufw allow 8080/tcp' && ok "the confirmed rule stays" || bad "8080 lost"

# An unconfirmed change undoes itself.
cli firewall rule-add --port 9090 --proto tcp --window 30 --confirm yes >/tmp/c1 2>&1
uid=$(sed -nE 's/^\| Change +\| ([a-f0-9]{12}) .*/\1/p' /tmp/c1)
ufw show added | grep -qx 'ufw allow 9090/tcp' && ok "unconfirmed rule applied" || bad "9090 not applied"
sleep 35
! ufw show added | grep -qx 'ufw allow 9090/tcp' && [[ "$(cli change status --id "$uid" 2>/dev/null | awk '$1 == "state" {print $2}')" == restored ]] && ok "the timer undoes an unconfirmed change" || bad "9090 still there: $(cli change status --id "$uid" 2>&1 | tail -3)"
r=$(job change:confirm "{\"change_id\":\"$uid\"}"); [[ -z "$r" ]] && ok "an undone change cannot be confirmed" || bad "confirmed after restore"

# Without its timer (after a reboot) the status refresh undoes it.
cli firewall rule-add --port 9091 --proto udp --window 30 --confirm yes >/tmp/c2 2>&1
uid=$(sed -nE 's/^\| Change +\| ([a-f0-9]{12}) .*/\1/p' /tmp/c2)
systemctl stop "simai-change-${uid}.timer" >/dev/null 2>&1
sleep 31
ufw show added | grep -qx 'ufw allow 9091/udp' && ok "with no timer the rule is still there" || bad "9091 gone too early"
cli self status-refresh --confirm yes >/dev/null 2>&1
! ufw show added | grep -qx 'ufw allow 9091/udp' && ok "the status refresh undoes it" || bad "9091 not undone"

# SSH, HTTP and HTTPS cannot be closed.
id22=$(status | field '[r["id"] for r in d["data"]["rules"] if r["port"] == "22"][0]')
r=$(job firewall:rule-remove "{\"id\":\"${id22}\"}"); [[ -z "$r" ]] && ufw show added | grep -qx 'ufw allow 22/tcp' && ok "the SSH rule cannot be removed" || bad "ssh removed!"
r=$(job firewall:rule-add '{"port":"443","proto":"tcp","action":"deny"}'); [[ -z "$r" ]] && ok "HTTPS cannot be denied for everyone" || bad "443 denied"
[[ -z "$(python3 /root/simai-env/lib/timed_change.py pending firewall)" ]] && ok "a refused change leaves nothing pending" || bad "pending after refusal"

# Remove by id, deny from one address.
id80=$(status | field '[r["id"] for r in d["data"]["rules"] if r["port"] == "8080"][0]')
r=$(job firewall:rule-remove "{\"id\":\"${id80}\"}") && confirm "$(field 'd["change_id"]' <<<"$r")" && ! ufw show added | grep -q '8080' && ok "rule-remove by id" || bad "remove 8080: $r"
r=$(job firewall:rule-add '{"port":"3306","proto":"tcp","from":"192.0.2.0/24","action":"allow"}') && confirm "$(field 'd["change_id"]' <<<"$r")" \
  && ufw show added | grep -q 'allow from 192.0.2.0/24 to any port 3306 proto tcp' && ok "allow a port from a network" || bad "3306 from net: $r"
refused invalid_argument "$(req null firewall:rule-add '{"port":"22","proto":"tcp","from":"1.2.3.4; reboot"}')" "an address with shell text"

# Blocks.
r=$(job firewall:block '{"address":"203.0.113.7","ttl":"600"}') && confirm "$(field 'd["change_id"]' <<<"$r")" || bad "block: $r"
[[ "$(ufw show added | grep -c 'deny from 203.0.113.7')" == 1 && "$(status | field 'd["data"]["blocks"][0]["address"]')" == 203.0.113.7 ]] && ok "an address is blocked and listed" || bad "block state"
ufw status numbered | grep -m1 -E '^\[ *1\]' | grep -q 203.0.113.7 && ok "the block comes before the allow rules" || bad "block order: $(ufw status numbered | head -6)"
python3 - <<'PY'
import json; p="/etc/simai-env/firewall/blocks.json"; d=json.load(open(p))
for b in d["blocks"]: b["until"] = 1
json.dump(d, open(p, "w"))
PY
cli self status-refresh --confirm yes >/dev/null 2>&1
! ufw show added | grep -q 'deny from 203.0.113.7' && [[ "$(status | field 'len(d["data"]["blocks"])')" == 0 ]] && ok "an expired block ends" || bad "expired block still there"
r=$(job firewall:block '{"address":"2001:db8::5"}') && confirm "$(field 'd["change_id"]' <<<"$r")" && ufw show added | grep -q 'deny from 2001:db8::5' && ok "an IPv6 address is blocked" || bad "v6 block: $r"
r=$(job firewall:unblock '{"address":"2001:db8::5"}') && confirm "$(field 'd["change_id"]' <<<"$r")" && ! ufw show added | grep -q '2001:db8::5' && ok "unblock" || bad "unblock: $r"

# Panel access by address: open.test stands in for the panel site. Its
# configuration is rendered without the include, as before 1.35.0.
printf 'PANEL_DOMAIN=open.test\n' >>/etc/simai-env/panel.env
conf=/etc/nginx/sites-available/open.test.conf
sed -i '/simai-access/d' "$conf" && nginx -s reload
me=$(hostname -I | awk '{print $1}')
code() { curl -s -o /dev/null -w '%{http_code}' -H 'Host: open.test' "http://$1/"; }
[[ "$(code "$me")" == 200 ]] && ok "the site answers before" || bad "site before: $(code "$me")"
r=$(job panel:access '{"allow":["198.51.100.1","192.0.2.0/24"]}')
pid=$(field 'd["change_id"]' <<<"$r" 2>/dev/null); [[ "$(field 'd["kind"]' <<<"$r" 2>/dev/null)" == panel_access ]] && ok "panel:access takes a list" || bad "panel access: $r"
grep -q 'simai-access/open-test\[.\]conf' "$conf" && ok "an older configuration gets the include" || bad "include missing"
[[ "$(code "$me")" == 403 && "$(code 127.0.0.1)" == 200 ]] && ok "other addresses are refused, local checks still answer" || bad "access codes: $(code "$me") $(code 127.0.0.1)"
[[ "$(status | field 'd["data"]["panel_access"]["allow"]')" == "['198.51.100.1', '192.0.2.0/24']" ]] && ok "status shows panel access" || bad "status panel access"
curl -s -o /dev/null -w '%{http_code}' -H 'Host: open.test' "http://${me}/.well-known/acme-challenge/x" | grep -qv 403 && ok "certificate checks still reach the site" || bad "acme blocked"
cli change restore --id "$pid" --confirm yes >/dev/null 2>&1; sleep 1
[[ "$(code "$me")" == 200 ]] && ! grep -q 'simai-access' "$conf" && ok "an undone panel access opens the panel again" || bad "after undo: $(code "$me")"
r=$(job panel:access "{\"allow\":\"${me},198.51.100.1\"}") && confirm "$(field 'd["change_id"]' <<<"$r")" && [[ "$(code "$me")" == 200 ]] && ok "allowed addresses get in (comma list)" || bad "allowed: $r $(code "$me")"
r=$(job panel:access '{"allow":"any"}') && confirm "$(field 'd["change_id"]' <<<"$r")" && [[ ! -e /etc/nginx/simai-access/open-test.conf && "$(code "$me")" == 200 ]] && ok "allow any removes the limit" || bad "any: $r"
refused invalid_argument "$(req null panel:access '{"allow":"1.2.3.4;"}')" "an address list with nginx text"
refused invalid_argument "$(req null panel:access '{"allow":[1,2]}')" "a list of numbers"
r=$(job panel:access '{"allow":"300.1.1.1"}'); [[ -z "$r" ]] && ok "an impossible address fails the job" || bad "300.1.1.1 accepted"
cli site add --domain new.test --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1
grep -q 'simai-access/new-test\[.\]conf' /etc/nginx/sites-available/new.test.conf && ok "new sites include their access file" || bad "template include"

# Leave the container as later cases expect it.
sed -i '/^PANEL_DOMAIN=open.test$/d' /etc/simai-env/panel.env
for d in open.test new.test; do cli site remove --domain "$d" --remove-files yes --confirm yes >/dev/null 2>&1; done
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli panel gate-disable --confirm yes >/dev/null 2>&1; rm -f /root/own /root/own.pub
ufw --force reset >/dev/null 2>&1; rm -f /etc/simai-env/firewall/blocks.json; rm -rf /var/lib/simai-env/changes

echo "failures=${fails}"
exit $((fails > 0))

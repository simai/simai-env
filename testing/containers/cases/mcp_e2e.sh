#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2086  # container test script: loose cd checks and word-split ssh options are fine here
# MCP access: an AI client logs in over SSH with a key whose forced command
# fixes the role; the MCP server speaks JSON-RPC and goes through the panel
# gateway: reads, plan then confirm with a one-time token, jobs, owner scope,
# the audit log, and code running as the owner cannot reach it.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
sshopt="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

for k in own adm ai ai2 evil; do ssh-keygen -q -t ed25519 -N '' -f "/root/$k" <<<y >/dev/null 2>&1; done
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
cli owner create --name beta --confirm yes >/dev/null 2>&1
cli site add --domain a.test --owner acme --profile static --confirm yes >/dev/null 2>&1
cli site add --domain b.test --owner beta --profile static --confirm yes >/dev/null 2>&1

cli mcp enable >/tmp/m 2>&1
grep -q '^Plan: let AI assistants' /tmp/m && ! id simai-mcp >/dev/null 2>&1 && ok "without confirm only a plan" || { bad "plan"; cat /tmp/m; }
cli mcp enable --confirm yes >/tmp/m 2>&1 && ok "mcp enable" || { bad "enable"; tail -5 /tmp/m; }
cli mcp key-add --pubkey-file /root/ai.pub --owner acme --confirm yes >/tmp/m 2>&1 && ok "a key for owner acme" || { bad "key-add owner"; tail -3 /tmp/m; }
cli mcp key-add --pubkey-file /root/adm.pub --admin yes --confirm yes >/dev/null 2>&1 && ok "a key for the administrator" || bad "key-add admin"
cli mcp key-add --pubkey-file /root/ai2.pub --owner nobody --confirm yes >/dev/null 2>&1 && bad "a key for a missing owner" || ok "keys only for existing owners"
cli mcp key-add --pubkey-file /root/ai.pub --admin yes --confirm yes >/dev/null 2>&1 && bad "a key added twice" || ok "a key cannot be added twice"
s=$(cli mcp status --output json 2>/dev/null)
[[ "$(js '(d["data"]["enabled"], len(d["data"]["keys"]), sorted(k["role"] for k in d["data"]["keys"]))' <<<"$s")" == "(True, 2, ['administrator', 'owner'])" ]] \
  && ok "mcp status lists the keys" || bad "status: ${s:0:300}"
[[ "$(js 'd["data"]["clients"]["claude_code"]' <<<"$s")" == "claude mcp add simai -- ssh -T simai-mcp@"* ]] && ok "status shows how to connect a client" || bad "clients"

# A session: newline-delimited JSON-RPC over ssh.
mcp() { # key, then requests one per argument
  local key="$1"; shift
  local init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
  { echo "$init"; echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'; printf '%s\n' "$@"; } \
    | ssh $sshopt -i "/root/$key" simai-mcp@127.0.0.1 2>/dev/null
}
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
nth() { sed -n "$(( $1 + 1 ))p"; }   # answer number N (0 = initialize)

out=$(mcp ai '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[[ "$(nth 0 <<<"$out" | js '(d["result"]["serverInfo"]["name"], d["result"]["protocolVersion"], "tools" in d["result"]["capabilities"])')" == "('simai-env', '2025-06-18', True)" ]] \
  && ok "initialize over SSH" || bad "initialize: ${out:0:300}"
[[ "$(nth 1 <<<"$out" | js 'sorted(t["name"] for t in d["result"]["tools"])')" == "['simai_confirm', 'simai_job', 'simai_overview', 'simai_plan', 'simai_read']" ]] \
  && ok "tools/list" || bad "tools: ${out:0:300}"
out=$(mcp ai "$(call 1 simai_overview '{}')")
o=$(nth 1 <<<"$out")
[[ "$(js '(d["result"]["structuredContent"]["data"]["role"], d["result"]["structuredContent"]["data"]["owner"])' <<<"$o")" == "('owner', 'acme')" ]] \
  && ok "the key's role: owner acme" || bad "overview: ${o:0:300}"
cmds=$(js '[c["command"] for c in d["result"]["structuredContent"]["data"]["commands"]]' <<<"$o")
[[ "$cmds" == *site:describe* && "$cmds" != *owner:create* && "$cmds" != *security:geo* && "$cmds" != *mcp:* ]] \
  && ok "an owner sees no administrator commands" || bad "owner commands: ${cmds:0:300}"

out=$(mcp ai "$(call 1 simai_read '{"command":"site:describe","args":{"domain":"a.test"}}')" \
             "$(call 2 simai_read '{"command":"site:describe","args":{"domain":"b.test"}}')" \
             "$(call 3 simai_read '{"command":"cron:add","args":{"domain":"a.test"}}')" \
             "$(call 4 simai_read '{"command":"owner:list","args":{}}')")
[[ "$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["data"]["domain"]')" == a.test ]] && ok "the owner reads their site" || bad "read own: $(nth 1 <<<"$out" | head -c 300)"
[[ "$(nth 2 <<<"$out" | js '(d["result"]["isError"], d["result"]["structuredContent"]["reason"])')" == "(True, 'owner_scope')" ]] && ok "another owner's site is refused" || bad "scope: $(nth 2 <<<"$out" | head -c 300)"
[[ "$(nth 3 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == not_a_read_use_plan ]] && ok "an action cannot run as a read" || bad "read action: $(nth 3 <<<"$out" | head -c 300)"
[[ "$(nth 4 <<<"$out" | js 'd["result"]["structuredContent"]["status"]')" == refused ]] && ok "an owner cannot read administrator data" || bad "admin read"

# Plan, then confirm with the token.
out=$(mcp ai "$(call 1 simai_plan '{"command":"backup:data","args":{"domain":"a.test"}}')")
p=$(nth 1 <<<"$out")
token=$(js 'd["result"]["structuredContent"].get("plan_token", "")' <<<"$p")
[[ ${#token} == 32 && "$(js 'd["result"]["structuredContent"]["kind"]' <<<"$p")" == plan ]] && ok "simai_plan returns a plan and a token" || bad "plan: ${p:0:400}"
[[ -z "$(ls /var/backups/simai/a.test 2>/dev/null)" ]] && ok "a plan changes nothing" || bad "plan ran"
out=$(mcp adm "$(call 1 simai_confirm "{\"plan_token\":\"$token\"}")")
[[ "$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == token_of_another_account ]] && ok "another key cannot confirm the plan" || bad "cross confirm: $(nth 1 <<<"$out" | head -c 300)"
out=$(mcp ai "$(call 1 simai_plan '{"command":"backup:data","args":{"domain":"a.test"}}')")
token=$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["plan_token"]')
out=$(mcp ai "$(call 1 simai_confirm "{\"plan_token\":\"$token\"}")" "$(call 2 simai_confirm "{\"plan_token\":\"$token\"}")")
job=$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"].get("job_id", "")')
[[ ${#job} == 24 ]] && ok "simai_confirm starts a job" || bad "confirm: $(nth 1 <<<"$out" | head -c 400)"
[[ "$(nth 2 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == unknown_or_expired_token ]] && ok "a token works once" || bad "token reuse"
state=""
for _ in $(seq 1 60); do
  state=$(mcp ai "$(call 1 simai_job "{\"job_id\":\"$job\"}")" | nth 1 | js 'd["result"]["structuredContent"]["data"]["state"]' 2>/dev/null)
  [[ "$state" == running || "$state" == queued || -z "$state" ]] || break
  sleep 2
done
[[ "$state" == succeeded && -n "$(ls /var/backups/simai/a.test 2>/dev/null)" ]] && ok "the job succeeds: a backup exists" || bad "job state: $state"
lg=$(mcp ai "$(call 1 simai_job "{\"job_id\":\"$job\",\"log\":true}")" | nth 1)
[[ "$(js 'd["result"]["structuredContent"]["status"]' <<<"$lg")" == ok ]] && ok "simai_job reads the log" || bad "job log: ${lg:0:300}"
out=$(mcp ai "$(call 1 simai_plan '{"command":"backup:data","args":{"domain":"b.test"}}')")
[[ "$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == owner_scope ]] && ok "no plan for another owner's site" || bad "plan scope"
grep -q '"user": "mcp:acme:' /var/log/simai-panel-gate.log && ok "the audit log names the MCP key" || bad "audit"

# The administrator, and MCP cannot hand out MCP access.
out=$(mcp adm "$(call 1 simai_overview '{}')" "$(call 2 simai_read '{"command":"security:geo-status","args":{}}')" \
              "$(call 3 simai_plan '{"command":"mcp:key-add","args":{"pubkey":"x"}}')")
[[ "$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["data"]["role"]')" == administrator ]] && ok "the administrator key" || bad "admin role"
[[ "$(nth 2 <<<"$out" | js 'd["result"]["structuredContent"]["data"]["schema"]')" == simai-geo/1 ]] && ok "the administrator reads host data" || bad "admin read: $(nth 2 <<<"$out" | head -c 300)"
[[ "$(nth 3 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == not_over_mcp ]] && ok "MCP keys are not managed over MCP" || bad "mcp over mcp"

# The panel hands out keys (administrators only).
cli panel gate-enable --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:-}"; }
pk=$(cut -d' ' -f1,2 /root/ai2.pub)
[[ "$(gate "$(req '"acme"' mcp:status '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot manage MCP in the panel" || bad "owner mcp:status"
[[ "$(gate "$(req null mcp:status '{}')" | js 'len(d["data"]["keys"])')" == 2 ]] && ok "mcp:status reads" || bad "gate status"
[[ "$(gate "$(req null mcp:key-add "{\"pubkey\":\"$pk\",\"owner\":\"beta\"}")" | js 'd["kind"]')" == plan ]] && ok "mcp:key-add answers a plan" || bad "gate plan"
a=$(gate "$(req null mcp:key-add "{\"pubkey\":\"$pk\",\"owner\":\"beta\"}" ',"confirm":true')")
j=$(js 'd.get("job_id", "")' <<<"$a"); for _ in $(seq 1 30); do grep -q "simai-mcp:beta:" /etc/ssh/simai-mcp-keys/simai-mcp && break; sleep 1; done
[[ -n "$j" && "$(mcp ai2 "$(call 1 simai_overview '{}')" | nth 1 | js 'd["result"]["structuredContent"]["data"]["owner"]')" == beta ]] \
  && ok "a key added in the panel works for owner beta" || bad "gate key-add: ${a:0:300}"

# The forced command wins; the account has nothing else.
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' | ssh $sshopt -i /root/ai simai-mcp@127.0.0.1 'id; cat /etc/shadow' 2>/dev/null)
[[ "$(js 'd["result"]' <<<"$out")" == "{}" ]] && ok "the client's command is ignored" || bad "forced command: ${out:0:200}"
ssh $sshopt -i /root/evil simai-mcp@127.0.0.1 true </dev/null 2>/dev/null && bad "an unknown key logs in" || ok "unknown keys are refused"
sudo -n -u acme sudo -n /usr/local/sbin/simai-mcp-session admin local </dev/null >/dev/null 2>&1 && bad "the owner (PHP) runs the session" || ok "code running as the owner cannot start a session"
sudo -n -u simai-mcp sudo -n /bin/true >/dev/null 2>&1 && bad "the MCP account has wider sudo" || ok "no other sudo rights"

# A blocked owner, removing keys, disable.
cli owner block --name acme --confirm yes >/dev/null 2>&1
out=$(mcp ai "$(call 1 simai_read '{"command":"site:describe","args":{"domain":"a.test"}}')")
[[ "$(nth 1 <<<"$out" | js 'd["result"]["structuredContent"]["reason"]')" == owner_blocked ]] && ok "a blocked owner is refused" || bad "blocked: ${out:0:300}"
cli owner unblock --name acme --confirm yes >/dev/null 2>&1
fp=$(ssh-keygen -lf /root/ai.pub | awk '{print $2}')
cli mcp key-remove --fingerprint "$fp" --confirm yes >/dev/null 2>&1
[[ -z "$(mcp ai '{"jsonrpc":"2.0","id":1,"method":"ping"}')" ]] && ok "a removed key cannot log in" || bad "key-remove"
cli mcp disable --confirm yes >/dev/null 2>&1
[[ -z "$(mcp adm '{"jsonrpc":"2.0","id":1,"method":"ping"}')" && ! -e /etc/sudoers.d/simai-mcp ]] && ok "disable removes access" || bad "disable"
printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | python3 -I admin/mcp_server.py admin local >/dev/null 2>/tmp/m; grep -q mcp_disabled /tmp/m \
  && ok "the session refuses when MCP is off" || bad "local after disable: $(cat /tmp/m)"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli site remove --domain a.test --remove-files yes --confirm yes >/dev/null 2>&1
cli site remove --domain b.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

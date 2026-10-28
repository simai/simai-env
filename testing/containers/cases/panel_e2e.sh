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
refused not_allowed "$(req null site:add '{"domain":"x.test"}')" "write command"
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

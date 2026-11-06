#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Security center: the passive check finds the problems of a fresh server
# (no firewall, password SSH, no Fail2ban, no automatic updates, no daily
# backup, a site with a vulnerable package), one-click fixes resolve them and
# raise the score, the status refresh keeps the report and opens alerts for
# serious problems, and the panel gateway serves it to administrators only.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
command -v sshd >/dev/null || apt-get install -y -qq openssh-server >/dev/null 2>&1
mkdir -p /run/sshd; systemctl start ssh >/dev/null 2>&1
printf 'PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/50-cloud-init.conf
rm -f /etc/apt/apt.conf.d/20auto-upgrades
apt-get remove -y -qq fail2ban unattended-upgrades >/dev/null 2>&1
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys

D=sec.test
cli site add --domain "$D" --profile generic --php "$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')" \
  --create-db no --backup no --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["root"]')
# A dependency with published vulnerabilities (guzzlehttp/guzzle 7.4.0: CVE-2022-29248 and others).
cat >"$root/composer.lock" <<'EOF'
{"packages": [{"name": "guzzlehttp/guzzle", "version": "7.4.0"}, {"name": "../../etc/passwd", "version": "1.0"}], "packages-dev": []}
EOF
chown simai "$root/composer.lock"

st() { cli security status --output json 2>/dev/null; }
s=$(st)
[[ "$(js 'd["data"]["schema"]' <<<"$s")" == simai-security/1 ]] && ok "security status answers simai-security/1" || { bad "status: ${s:0:400}"; }
score0=$(js 'd["data"]["score"]' <<<"$s")
c() { js "[(x['status'], (x['fix'] or {}).get('command')) for x in d['data']['checks'] if x['id'] == '$1']" <<<"$s"; }
[[ "$(c firewall)" == "[('risk', 'self:firewall-ensure')]" ]] && ok "no firewall is a risk with a one-click fix" || bad "firewall: $(c firewall)"
[[ "$(c ssh_password)" == "[('warn', None)]" ]] && ok "password SSH without any key offers no fix (lockout)" || bad "ssh: $(c ssh_password)"
[[ "$(c fail2ban)" == "[('warn', 'security:fix')]" ]] && ok "no Fail2ban is found" || bad "fail2ban: $(c fail2ban)"
[[ "$(c auto_updates)" == "[('warn', 'security:fix')]" ]] && ok "no automatic updates is found" || bad "auto: $(c auto_updates)"
[[ "$(c "backup_schedule:$D")" == "[('warn', 'backup:data-schedule')]" ]] && ok "a site without daily backup is found" || bad "backup: $(c "backup_schedule:$D")"
[[ "$(js '{x["id"]: x["status"] for x in d["data"]["checks"]}[d["data"]["recommendations"][0]]' <<<"$s")" == risk ]] && ok "risks come first in the recommendations" || bad "order"
cli security status >/tmp/h 2>&1 && grep -q 'Security score' /tmp/h && grep -q 'fix: simai-admin.sh self firewall-ensure' /tmp/h && ok "the human answer lists fixes" || { bad "human"; head -12 /tmp/h; }

# The online scan finds the vulnerable package; invalid names are ignored.
cli security scan --confirm yes >/tmp/sc 2>&1 || bad "scan: $(tail -3 /tmp/sc)"
s=$(st)
v=$(js "[x['package'] for x in d['data']['vulnerabilities'].get('$D', [])]" <<<"$s")
if [[ "$(js 'd["data"]["online"]["error"]' <<<"$s")" != None ]]; then
  echo "INFO vulnerability database unreachable from the container: $(js 'd["data"]["online"]["error"]' <<<"$s")"
else
  [[ "$v" == *guzzlehttp/guzzle* ]] && ok "the scan finds the vulnerable package" || bad "vulns: $v"
  [[ "$v" != *passwd* ]] && ok "invalid package names from the lock file are ignored" || bad "bad name used"
  [[ "$(c "site_components:$D")" == *risk* ]] && ok "a vulnerable component is a risk of the site" || bad "component: $(c "site_components:$D")"
fi

# One-click fixes.
cli security fix --check fail2ban >/tmp/p 2>&1; grep -q 'Plan:' /tmp/p && ! command -v fail2ban-client >/dev/null && ok "fix without confirm is a plan" || bad "plan"
cli security fix --check fail2ban --confirm yes >/tmp/f 2>&1 && fail2ban-client status sshd >/dev/null 2>&1 && ok "Fail2ban fix guards SSH" || { bad "fail2ban fix"; tail -5 /tmp/f; }
cli security fix --check auto_updates --confirm yes >/tmp/f 2>&1 && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && ok "automatic security updates are on" || { bad "auto fix"; tail -5 /tmp/f; }
cli security fix --check ssh_password --confirm yes >/tmp/f 2>&1 && bad "SSH passwords turned off without a key" || { grep -q 'locked out' /tmp/f && ok "SSH fix refused without a key" || bad "ssh refuse: $(tail -2 /tmp/f)"; }
mkdir -p /root/.ssh; ssh-keygen -q -t ed25519 -N '' -f /root/k <<<y >/dev/null 2>&1; cat /root/k.pub >>/root/.ssh/authorized_keys
cli security fix --check ssh_password --confirm yes >/tmp/f 2>&1 && [[ "$(sshd -T | awk '$1=="passwordauthentication"{print $2}')" == no ]] && ok "SSH accepts keys only" || { bad "ssh fix"; tail -5 /tmp/f; }
cli backup data-schedule --domain "$D" --enabled yes --confirm yes >/dev/null 2>&1
s=$(st)
[[ "$(c fail2ban)" == "[('ok', None)]" && "$(c auto_updates)" == "[('ok', None)]" && "$(c ssh_password)" == "[('ok', None)]" && -z "$(js "[x for x in d['data']['checks'] if x['id'] == 'backup_schedule:$D']" <<<"$s" | tr -d '[]')" ]] \
  && ok "fixed problems are ok" || bad "after fix: $(c fail2ban) $(c auto_updates) $(c ssh_password)"
score1=$(js 'd["data"]["score"]' <<<"$s")
(( score1 > score0 )) && ok "the score rises after the fixes ($score0 -> $score1)" || bad "score $score0 -> $score1"

# Site files: web shells are found, quarantined and can be put back.
pub="$root/public"
printf '<?php eval(base64_decode("ZWNobyAxOw=="));\n' >"$pub/shell.php"
printf '<?php echo "fine";\n' >"$pub/ok.php"
chown simai:www-data "$pub/shell.php" "$pub/ok.php"; chmod 0640 "$pub/shell.php"
ln -sf /etc/passwd "$pub/link.php"
cli security files-scan --domain "$D" --confirm yes >/tmp/fs 2>&1 || bad "files-scan: $(tail -3 /tmp/fs)"
f=$(cli security files --output json 2>/dev/null)
[[ "$(js "[x['path'] for x in d['data']['sites']['$D']['found']]" <<<"$f")" == "['public/shell.php']" ]] && ok "the file scan finds the web shell only" || bad "files: ${f:0:400}"
s=$(st)
[[ "$(c "malware:$D")" == "[('risk', None)]" && "$(js "[x['severity'] for x in d['data']['checks'] if x['id'] == 'malware:$D']" <<<"$s")" == "['critical']" ]] && ok "a web shell is a critical risk" || bad "malware: $(c "malware:$D")"
cli security quarantine --domain "$D" --path ../../etc/passwd --confirm yes >/dev/null 2>&1 && bad "a path outside the site was quarantined" || ok "a path outside the site is refused"
cli security quarantine --domain "$D" --path public/link.php --confirm yes >/dev/null 2>&1 && bad "a symlink was quarantined" || { [[ -f /etc/passwd ]] && ok "a symlink is refused"; }
cli security quarantine --domain "$D" --path public/shell.php >/tmp/q 2>&1; grep -q 'Plan:' /tmp/q && [[ -f "$pub/shell.php" ]] && ok "quarantine without confirm is a plan" || bad "quarantine plan"
cli security quarantine --domain "$D" --path public/shell.php --confirm yes >/tmp/q 2>&1 && [[ ! -e "$pub/shell.php" ]] && ok "the shell goes to the quarantine" || { bad "quarantine"; tail -3 /tmp/q; }
q=$(cli security quarantine-list --output json 2>/dev/null); qid=$(js 'd["data"]["files"][0]["id"]' <<<"$q")
[[ "$(stat -c %a "/var/lib/simai-env/quarantine/$D/$qid/file")" == 600 && "$q" != *'"root"'* ]] && ok "the quarantined file is root-only" || bad "quarantine list: ${q:0:300}"
s=$(st); [[ -z "$(js "[x for x in d['data']['checks'] if x['id'] == 'malware:$D']" <<<"$s" | tr -d '[]')" ]] && ok "a quarantined file no longer counts" || bad "still counted"
cli security quarantine-restore --id "$qid" --confirm yes >/dev/null 2>&1 && [[ "$(stat -c '%U %a' "$pub/shell.php")" == "simai 640" ]] && ok "restore puts it back with its owner and mode" || bad "restore: $(stat -c '%U %a' "$pub/shell.php" 2>&1)"
cli security quarantine-restore --id "$qid" --confirm yes >/dev/null 2>&1 && bad "restored twice" || ok "a restored file cannot be restored again"
rm -f "$pub/shell.php" "$pub/link.php"

# ClamAV adds its signatures (a test signature here; real ones come from freshclam).
cli security fix --check antivirus --confirm yes >/tmp/av 2>&1 && command -v clamscan >/dev/null && ok "the antivirus fix installs ClamAV" || { bad "antivirus"; tail -5 /tmp/av; }
systemctl stop clamav-freshclam clamav-daemon >/dev/null 2>&1
printf 'simai-clamav-test-content-0001\n' >"$pub/sample.txt"
printf '%s:%s:Simai.Test.Signature\n' "$(md5sum "$pub/sample.txt" | cut -d' ' -f1)" "$(stat -c %s "$pub/sample.txt")" >/var/lib/clamav/simai-test.hdb
cli security files-scan --domain "$D" --confirm yes >/tmp/fs 2>&1
f=$(cli security files --output json 2>/dev/null)
[[ "$(js "[(x['path'], x['engine']) for x in d['data']['sites']['$D']['found']]" <<<"$f")" == "[('public/sample.txt', 'clamav')]" ]] && ok "ClamAV signatures are used by the file scan" || bad "clamav: ${f:0:400} $(tail -3 /tmp/fs)"
s=$(st); [[ "$(c antivirus)" == "[('ok', None)]" ]] && ok "the antivirus check is ok" || bad "antivirus check: $(c antivirus)"
rm -f "$pub/sample.txt" /var/lib/clamav/simai-test.hdb

# The status refresh keeps the report; serious problems open alerts.
rm -rf /var/lib/simai-env/security
cli self status-refresh --confirm yes >/dev/null 2>&1
for _ in {1..60}; do [[ -s /var/lib/simai-env/security/report.json ]] && break; sleep 1; done
[[ "$(stat -c %a /var/lib/simai-env/security/report.json 2>/dev/null)" == 600 ]] && ok "the status refresh writes the report (root-only)" || bad "no report"
cli self status-refresh --confirm yes >/dev/null 2>&1
a=$(cli self alerts --output json 2>/dev/null)
[[ "$(js '[x["target"] for x in d["data"]["alerts"] if x["kind"] == "security_risk" and x["state"] == "open"]' <<<"$a")" == *firewall* ]] \
  && ok "a serious problem opens an alert" || bad "alerts: ${a:0:400}"

# Web protection: limits per address, scanners slowed, this server exempt.
ip=$(hostname -I | awk '{print $1}')
hit() { curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 -H "Host: $D" "$@"; }
cli security web-protect --enabled yes --rate 2 --burst 10 >/tmp/w 2>&1; grep -q 'Plan:' /tmp/w && [[ ! -e /etc/nginx/conf.d/simai-protect.conf ]] && ok "web-protect without confirm is a plan" || bad "web plan"
cli security web-protect --enabled yes --rate 2 --burst 10 --confirm yes >/tmp/w 2>&1 && nginx -t >/dev/null 2>&1 && ok "web protection applies" || { bad "web apply"; tail -5 /tmp/w; }
n=$(for _ in $(seq 1 40); do hit "http://$ip/ok.php"; done | grep -c 429)
(( n > 0 )) && ok "a flood from one address gets 429 ($n of 40)" || bad "no 429 for a flood"
n=$(for _ in $(seq 1 40); do hit "http://127.0.0.1/ok.php"; done | grep -c 429)
(( n == 0 )) && ok "this server's own address is never limited" || bad "local limited: $n"
sleep 6
n=$(for _ in $(seq 1 8); do hit -A 'sqlmap/1.7' "http://$ip/ok.php"; done | grep -c 429)
(( n >= 4 )) && ok "an attack scanner is slowed ($n of 8 refused)" || bad "scanner refused only $n"
fail2ban-client status nginx-limit-req >/dev/null 2>&1 && ok "Fail2ban watches the request limit" || bad "no nginx-limit-req jail"
s=$(st); [[ "$(c web_protect)" == "[('ok', None)]" ]] && ok "the web protection check is ok" || bad "web check: $(c web_protect)"

# Protection levels.
cli security level --set enhanced >/tmp/l 2>&1; grep -q 'ClamAV' /tmp/l && grep -q 'keys only' /tmp/l && ok "a level shows its steps first" || { bad "level plan"; cat /tmp/l; }
cli security level --set enhanced --confirm yes >/tmp/l 2>&1 && grep -q 'rate=30r/s' /etc/nginx/conf.d/simai-protect.conf && ufw status | grep -q 'Status: active' \
  && ok "the enhanced level applies its bundle" || { bad "level apply"; tail -5 /tmp/l; }
[[ "$(st | js 'd["data"]["level"]["current"]')" == enhanced ]] && ok "security status shows the level" || bad "level in status"
hit "http://$ip/ok.php" | grep -q 200 && ok "sites still answer through the firewall" || bad "site down after level"
cli security level --set basic --confirm yes >/dev/null 2>&1 && [[ ! -e /etc/nginx/conf.d/simai-protect.conf ]] && ok "the basic level removes the web limits" || bad "basic"

# Panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
[[ "$(gate "$(req '"acme"' security:status '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot read the security center" || bad "owner"
g=$(gate "$(req null security:status '{}')")
[[ "$(js 'd["data"]["schema"]' <<<"$g")" == simai-security/1 ]] && ok "security:status reads" || bad "gate status: ${g:0:300}"
[[ "$(gate "$(req null security:fix '{"check":"fail2ban"}')" | js 'd["kind"]')" == plan ]] && ok "security:fix answers a plan" || bad "gate fix plan"
[[ "$(gate "$(req null security:fix '{"check":"rm -rf"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "an unknown fix is refused" || bad "gate bad fix"
g=$(gate "$(req null security:files '{}')"); [[ "$(js 'd["data"]["schema"]' <<<"$g")" == simai-file-scan/1 ]] && ok "security:files reads" || bad "gate files: ${g:0:300}"
g=$(gate "$(req null security:quarantine-list '{}')"); [[ "$(js 'd["data"]["schema"]' <<<"$g")" == simai-quarantine/1 ]] && ok "security:quarantine-list reads" || bad "gate qlist: ${g:0:300}"
[[ "$(gate "$(req null security:quarantine "{\"domain\":\"$D\",\"path\":\"public/ok.php\"}")" | js 'd["kind"]')" == plan ]] && ok "security:quarantine answers a plan" || bad "gate quarantine plan"
[[ "$(gate "$(req null self:firewall-ensure '{}')" | js 'd["kind"]')" == plan ]] && ok "self:firewall-ensure answers a plan" || bad "gate firewall plan"
[[ "$(gate "$(req null security:level '{"set":"strict"}')" | js 'd["kind"]')" == plan ]] && ok "security:level answers a plan" || bad "gate level plan"
[[ "$(gate "$(req null security:web-protect '{"enabled":"yes","rate":"1"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "a rate below 2 is refused" || bad "gate rate"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain "$D" --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

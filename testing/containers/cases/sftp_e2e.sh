#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
command -v sshd >/dev/null || { apt-get install -y -qq openssh-server >/dev/null 2>&1; systemctl start ssh; }
./simai-admin.sh access create-project --domain alpha.test --login alphadev --password 'Xy7-test-pass-123' --confirm yes >/tmp/acc 2>&1 || { bad "access create-project"; tail -20 /tmp/acc; }
A=/home/simai/www/alpha.test
getfacl -p "$A" 2>/dev/null | grep -q '^user:site-alpha-test:rwx' && ok "ACL grants site user" || { bad "ACL"; getfacl -p "$A"; }
getfacl -p "$A" 2>/dev/null | grep -q '^user:simai:' && bad "ACL still grants shared simai" || ok "no ACL for shared simai"
sudo -u alphadev bash -c "echo uploaded > $A/public/up.txt" 2>/dev/null || sudo -u alphadev bash -c "echo uploaded > /var/lib/simai-env/x" 2>/dev/null
[[ -f "$A/public/up.txt" ]] || runuser -u alphadev -- sh -c "echo uploaded > $A/public/up.txt"
out=$(curl -s -H 'Host: alpha.test' "http://127.0.0.1/probe.php?f=$A/public/up.txt")
echo "$out" | grep -q '=READ' && ok "site PHP reads SFTP-uploaded file" || bad "site cannot read upload: $out"
[[ "$(curl -s -H 'Host: alpha.test' http://127.0.0.1/up.txt)" == uploaded ]] && ok "nginx serves SFTP-uploaded file" || bad "nginx cannot serve upload"
out=$(curl -s -H 'Host: legacy.test' "http://127.0.0.1/probe.php?f=$A/public/up.txt")
echo "$out" | grep -q '=DENIED' && ok "other site cannot read upload" || bad "other site reads upload: $out"
echo "failures=$fails"; exit $fails

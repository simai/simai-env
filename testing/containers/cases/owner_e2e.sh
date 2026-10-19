#!/usr/bin/env bash
# shellcheck disable=SC2088,SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { local arg; for arg; do if [[ "$arg" == --confirm || "$arg" == --confirm=* ]]; then ./simai-admin.sh "$@"; return; fi; done; ./simai-admin.sh "$@" --confirm yes; }
http() { curl -s -H "Host: $1" "http://127.0.0.1$2"; }

ssh-keygen -q -t ed25519 -N '' -f /root/k1; ssh-keygen -q -t ed25519 -N '' -f /root/k2
cli owner create --name acme --pubkey-file /root/k1.pub >/tmp/o1 2>&1 && ok "owner create acme" || { bad "owner create"; tail /tmp/o1; }
cli owner create --name beta --pubkey-file /root/k2.pub >/dev/null 2>&1 && ok "owner create beta" || bad "owner create beta"
cli owner create --name root >/dev/null 2>&1 && bad "reserved name accepted" || ok "reserved name refused"
[[ "$(stat -c '%U %a' /etc/ssh/simai-owner-keys/acme)" == "root 644" ]] && ok "keys file root-owned" || bad "keys perms"

add() { cli site add --domain "$1" --profile generic --php 8.3 --create-db no "${@:2}" >/tmp/add.$1 2>&1 && ok "site add $1 ${2:-} ${3:-}" || { bad "site add $1"; tail -15 /tmp/add.$1; }; }
add a1.test --owner acme
add a2.test --owner acme
add b1.test --owner beta
add solo.test
grep -q '^user = acme' /etc/php/8.3/fpm/pool.d/a1-test.conf && grep -q '^user = acme' /etc/php/8.3/fpm/pool.d/a2-test.conf && ok "both acme sites run as acme" || bad "acme pools"
[[ -L /home/acme/sites/a1.test ]] && ok "~/sites link for owner" || bad "no sites link"
cli site info --domain a1.test 2>/dev/null | grep -q 'Runs as.*acme' && ok "site info shows owner" || bad "site info"

probe='<?php foreach (explode(",", $_GET["f"]) as $f) echo $f, "=", (@file_get_contents($f)===false?"DENIED":"READ"), "\n";'
for s in a1 a2 b1 solo; do d=/home/simai/www/$s.test; printf '%s' "$probe" >$d/public/p.php; echo s >$d/secret.txt; o=$(stat -c %U $d); chown $o:$o $d/public/p.php $d/secret.txt; done
out=$(http a1.test "/p.php?f=/home/simai/www/a2.test/secret.txt,/home/simai/www/b1.test/secret.txt,/home/simai/www/solo.test/secret.txt")
echo "$out" | grep -q 'a2.test/secret.txt=READ' && ok "same owner: a1 reads a2" || bad "a1 cannot read a2: $out"
echo "$out" | grep -q 'b1.test/secret.txt=DENIED' && ok "other owner: a1 cannot read b1" || bad "a1 reads b1"
echo "$out" | grep -q 'solo.test/secret.txt=DENIED' && ok "a1 cannot read per-site user solo" || bad "a1 reads solo"

# SSH as owner with managed key; key planted by PHP is ignored.
sshopt="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
[[ "$(ssh $sshopt -i /root/k1 acme@127.0.0.1 whoami 2>/dev/null)" == acme ]] && ok "owner SSH login with managed key" || bad "owner ssh login"
ssh $sshopt -i /root/k1 acme@127.0.0.1 "echo deployed > /home/simai/www/a1.test/public/deploy.txt" 2>/dev/null
[[ "$(http a1.test /deploy.txt)" == deployed ]] && ok "owner deploys into own site over SSH" || bad "deploy failed"
ssh $sshopt -i /root/k1 acme@127.0.0.1 "echo x > /home/simai/www/b1.test/public/x.txt" 2>/dev/null && bad "owner wrote into other owner's site" || ok "owner cannot write other owner's site"
ssh-keygen -q -t ed25519 -N '' -f /root/evil
plant='<?php @mkdir(getenv("HOME")."/.ssh",0700); $h=posix_getpwuid(posix_geteuid())["dir"]; @mkdir("$h/.ssh",0700); echo file_put_contents("$h/.ssh/authorized_keys", $_GET["k"]) ? "planted" : "fail";'
printf '%s' "$plant" >/home/simai/www/a1.test/public/plant.php; chown acme:acme /home/simai/www/a1.test/public/plant.php
http a1.test "/plant.php?k=$(sed 's/ /%20/g;s/+/%2B/g' /root/evil.pub)" >/tmp/pl; echo "  php plant: $(cat /tmp/pl)"
ssh $sshopt -i /root/evil acme@127.0.0.1 whoami >/dev/null 2>&1 && bad "PHP-planted key grants SSH" || ok "PHP-planted key is ignored by sshd"
cli owner add-key --name acme --pubkey-file /root/k2.pub >/dev/null 2>&1; [[ "$(ssh $sshopt -i /root/k2 acme@127.0.0.1 whoami 2>/dev/null)" == acme ]] && ok "owner add-key works" || bad "add-key"

# Move a per-site user site to an owner.
cli site isolate --domain solo.test --owner acme --confirm yes >/tmp/mv 2>&1 && ok "move solo.test to acme" || { bad "move"; tail /tmp/mv; }
id site-solo-test >/dev/null 2>&1 && bad "old site user kept" || ok "old site-solo-test removed"
[[ "$(stat -c %U /home/simai/www/solo.test)" == acme ]] && grep -q '^user = acme' /etc/php/8.3/fpm/pool.d/solo-test.conf && ok "solo now owned by acme" || bad "solo owner"
[[ "$(http solo.test '/p.php?f=/home/simai/www/a1.test/secret.txt')" == *READ* ]] && ok "solo (now acme) reads a1" || bad "solo read a1"

# Remove semantics.
cli owner remove --name acme --confirm yes >/dev/null 2>&1 && bad "removed owner with sites" || ok "owner with sites is protected"
cli site remove --domain a2.test --remove-files yes --confirm yes >/dev/null 2>&1
id acme >/dev/null 2>&1 && ok "site remove keeps the owner" || bad "owner deleted with site"
[[ ! -e /home/acme/sites/a2.test ]] && ok "owner link removed with site" || bad "stale link"
cli owner list 2>/dev/null | grep -q 'acme.*a1-test' && ok "owner list shows projects" || bad "owner list"
cli site remove --domain b1.test --remove-files yes --confirm yes >/dev/null 2>&1
cli owner remove --name beta --confirm yes >/dev/null 2>&1 && ! id beta >/dev/null 2>&1 && ok "empty owner removed" || bad "owner remove"
echo "failures=$fails"; exit $fails

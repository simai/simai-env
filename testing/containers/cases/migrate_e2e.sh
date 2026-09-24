#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
id simai >/dev/null 2>&1 || useradd -m simai
chown simai:www-data /home
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
printf 'server {\n    listen 80 default_server;\n    server_name _;\n    return 444;\n}\n' >/etc/nginx/sites-available/000-catchall.conf
ln -sf /etc/nginx/sites-available/000-catchall.conf /etc/nginx/sites-enabled/000-catchall.conf
systemctl reload nginx
L=/home/simai/runtime-observer/rim1-ru/repo
mkdir -p "$L/.git/hooks" "$L/.git/info" /home/simai/runtime-observer/rim1-ru/state
git -C "$L" init -q 2>/dev/null || true
printf '#!/bin/sh\ntouch /tmp/pwned-hook\n' >"$L/.git/hooks/pre-commit"; chmod +x "$L/.git/hooks/pre-commit"
printf '[filter "x"]\n\tclean = touch /tmp/pwned-filter\n' >>"$L/.git/config"
echo '* filter=x' >"$L/.git/info/attributes"
chown -R root:root /home/simai/runtime-observer
bash ./simai-admin.sh self migrate >/tmp/m 2>&1 || { bad "self migrate rc"; tail /tmp/m; }
[[ "$(stat -c %U /home)" == root ]] && ok "/home owner repaired" || bad "/home owner"
T=/var/lib/simai-env/runtime-observer/rim1-ru
[[ -d "$T/repo/.git" && ! -e /home/simai/runtime-observer ]] && ok "observer storage moved" || bad "observer not moved"
grep -q filter "$T/repo/.git/config" && bad "malicious git config kept" || ok "git config sanitized"
[[ ! -e "$T/repo/.git/hooks" && ! -e "$T/repo/.git/info/attributes" ]] && ok "hooks/attributes removed" || bad "hooks kept"
touch "$T/repo/f"; git -C "$T/repo" add -A 2>/dev/null; git -C "$T/repo" -c user.name=t -c user.email=t@t commit -qm t 2>/dev/null
[[ ! -e /tmp/pwned-hook && ! -e /tmp/pwned-filter ]] && ok "nothing executed from old repo" || bad "payload executed"
grep -q simai-catchall-v2 /etc/nginx/sites-available/000-catchall.conf && ok "catch-all upgraded" || bad "catch-all not upgraded"
curl -sk --resolve evil.example:443:127.0.0.1 https://evil.example/ -o /dev/null --max-time 5; [[ $? -ne 0 ]] && ok "443 unknown host dropped" || bad "443 served"
[[ -f /etc/logrotate.d/simai-env ]] && ok "logrotate installed" || bad "logrotate"
bash ./simai-admin.sh self migrate 2>&1 | grep -q "nothing to migrate" && ok "second run is a no-op" || bad "not idempotent"
echo "failures=$fails"; exit $fails

#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# panel install / setup-link / status / remove: the panel is an isolated site
# whose account may call the gateway; the placeholder proves that path, a
# build from an archive replaces it, and removing the panel leaves every other
# site alone.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
P=panel.test
page() { curl -s --max-time 10 -H "Host: $P" "http://127.0.0.1/$1"; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }

cli site add --domain keep.test --profile static --confirm yes >/dev/null 2>&1
mkdir -p /root/k && echo keep-site >/root/k/index.html && tar -C /root/k -czf /root/k.tgz .
cli site deploy --domain keep.test --archive /root/k.tgz --sha256 "$(sha256sum /root/k.tgz | cut -d' ' -f1)" --confirm yes >/dev/null 2>&1

cli panel status 2>&1 | grep -q 'not installed' && ok "status before install" || bad "status before install"
cli panel install --domain $P >/tmp/pl 2>&1
[[ ! -f /etc/nginx/sites-available/$P.conf ]] && ok "install without confirm changes nothing" || bad "plan created the site"
cli panel install --domain $P --confirm yes >/tmp/pi 2>&1 && ok "panel install (placeholder)" || { bad "panel install"; tail -15 /tmp/pi; }
token=$(sed -n 's#.*?setup=\([a-f0-9]\{64\}\)$#\1#p' /tmp/pi)
[[ -n "$token" ]] && ok "install prints a one-time sign-in link" || bad "no setup link: $(tail -3 /tmp/pi)"
grep -rqs "$token" /var/log/simai-admin.log /var/log/simai-audit.log /var/log/simai-panel-gate.log && bad "setup token in a log" || ok "setup token stays out of the logs"

project=$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$P.conf)
user=$(cat "/etc/simai-env/site-users/$project")
[[ "$user" == site-* ]] && ok "panel runs as its own account ($user)" || bad "panel account: $user"
[[ "$(page '?format=json' | field 'd["gateway"]')" == ok ]] && ok "placeholder reaches the gateway" || bad "placeholder gateway: $(page '?format=json')"
[[ "$(page "?format=json&setup=${token}" | field 'd["setup"]')" == valid ]] && ok "setup link is valid" || bad "setup link"
[[ "$(page '?format=json&setup=0000' | field 'd["setup"]')" == invalid ]] && ok "wrong setup link is refused" || bad "wrong link accepted"
page '' | grep -q 'not reachable' && bad "html page reports no gateway" || ok "placeholder page renders"
page '' | grep -qE 'keep\.test|simai_env|php_versions' && bad "placeholder leaks server data" || ok "placeholder shows no server data"
sudo -n -u "$user" sudo -n /bin/true >/dev/null 2>&1 && bad "panel account has wider sudo" || ok "panel account may run only the gateway"
[[ "$(printf '{"schema":"simai-panel-request/1","request_id":"p1","actor":{"user":"a","owner":null},"command":"self:describe","args":{}}' | sudo -n -u "$user" sudo -n /usr/local/sbin/simai-panel-gate | field '{"keep.test", "panel.test"} <= {s["domain"] for s in d["data"]["sites"]}')" == True ]] && ok "panel account calls the gateway" || bad "panel account gateway call"

cli panel status 2>&1 | grep -q 'placeholder' && ok "status shows the placeholder" || bad "status after install"
cli panel install --domain $P --confirm yes >/dev/null 2>&1 && bad "second placeholder install accepted" || ok "reinstalling the placeholder is refused"
cli panel install --domain other.test --confirm yes >/dev/null 2>&1 && bad "second panel accepted" || ok "a second panel domain is refused"
cli panel install --domain keep.test --git https://example.com/x --ref v1 --confirm yes >/dev/null 2>&1; [[ "$(curl -s -H 'Host: keep.test' http://127.0.0.1/)" == keep-site ]] && ok "an existing site is never taken over" || bad "keep.test changed"

cli panel setup-link --confirm yes >/tmp/ps 2>&1
new=$(sed -n 's#.*?setup=\([a-f0-9]\{64\}\)$#\1#p' /tmp/ps)
[[ -n "$new" && "$new" != "$token" ]] && ok "setup-link makes a new link" || bad "setup-link"
[[ "$(page "?format=json&setup=${token}" | field 'd["setup"]')" == invalid ]] && ok "the old link stops working" || bad "old link still valid"
[[ "$(page "?format=json&setup=${new}" | field 'd["setup"]')" == valid ]] && ok "the new link works" || bad "new link"

# A build replaces the placeholder (a minimal Laravel-shaped application).
B=/root/build; mkdir -p $B/public $B/bootstrap $B/storage/logs $B/.simai
printf '<?php echo "panel-build";\n' >$B/public/index.php
printf '<?php return null;\n' >$B/bootstrap/app.php
printf '#!/usr/bin/env php\n<?php exit(0);\n' >$B/artisan
printf '{"schema":"simai-app/1","migrate":false,"scheduler":false}\n' >$B/.simai/app.json
tar -C $B -czf /root/build.tgz .
cli panel install --domain $P --archive /root/build.tgz --sha256 "$(sha256sum /root/build.tgz | cut -d' ' -f1)" --confirm yes >/tmp/pb 2>&1 && ok "panel install with a build archive" || { bad "build install"; tail -15 /tmp/pb; tail -20 /var/log/simai-admin.log; }
[[ "$(page '')" == panel-build ]] && ok "the build replaced the placeholder" || bad "build not served: $(page '' | head -c 200)"
grep -q '^# simai-profile: laravel' /etc/nginx/sites-available/$P.conf && ok "the build runs as a Laravel site" || bad "profile"
[[ -f /etc/simai-env/sites/$P/db.env ]] && ok "the build has a database" || bad "no database"
cli panel status 2>&1 | grep -q 'build' && ok "status shows the build" || bad "status build"
user2=$(cat "/etc/simai-env/site-users/$project")
grep -q "^${user2} ALL=(root) NOPASSWD: /usr/local/sbin/simai-panel-gate \"\"" /etc/sudoers.d/simai-panel && ok "gateway rule follows the build's account" || bad "sudoers: $(cat /etc/sudoers.d/simai-panel)"
grep -q '^SIMAI_PANEL_SETUP_TOKEN=[a-f0-9]\{64\}$' /home/simai/www/$P/.env && ok "the build gets a setup token in .env" || bad "token for build"

cli panel remove >/dev/null 2>&1; [[ -f /etc/nginx/sites-available/$P.conf ]] && ok "remove without confirm changes nothing" || bad "remove ran without confirm"
cli panel remove --confirm yes >/tmp/pr 2>&1 && ok "panel remove" || { bad "panel remove"; tail -10 /tmp/pr; }
[[ ! -f /etc/nginx/sites-available/$P.conf && ! -d /home/simai/www/$P ]] && ok "panel site removed" || bad "panel site left"
[[ ! -f /etc/sudoers.d/simai-panel && ! -f /usr/local/sbin/simai-panel-gate ]] && ok "gateway removed with the panel" || bad "gateway left"
[[ "$(curl -s -H 'Host: keep.test' http://127.0.0.1/)" == keep-site ]] && ok "other sites keep working" || bad "keep.test broken"
cli panel status 2>&1 | grep -q 'not installed' && ok "status after remove" || bad "status after remove"

# A host that enabled the gateway before 1.23.0 has the sudo line but no state.
id -u simai-panel >/dev/null 2>&1 || useradd --system --user-group simai-panel
printf 'simai-panel ALL=(root) NOPASSWD: /usr/local/sbin/simai-panel-gate ""\n' >/etc/sudoers.d/simai-panel; chmod 0440 /etc/sudoers.d/simai-panel
sed -i '/^GATE_ACCOUNT=/d' /etc/simai-env/panel.env 2>/dev/null || true
cli panel install --domain $P --confirm yes >/dev/null 2>&1
grep -q '^simai-panel ALL=' /etc/sudoers.d/simai-panel && ok "earlier gateway access survives panel install" || bad "simai-panel lost: $(cat /etc/sudoers.d/simai-panel)"
cli panel remove --confirm yes >/dev/null 2>&1
grep -q '^simai-panel ALL=' /etc/sudoers.d/simai-panel 2>/dev/null && ok "and panel remove" || bad "simai-panel lost on remove"
cli panel gate-disable --confirm yes >/dev/null 2>&1

# The stand account and the installed panel share one sudo file.
cli panel gate-enable --confirm yes >/dev/null 2>&1
cli panel install --domain $P --confirm yes >/dev/null 2>&1
[[ "$(grep -c 'NOPASSWD' /etc/sudoers.d/simai-panel)" == 2 ]] && ok "both gateway accounts listed" || bad "sudo lines: $(cat /etc/sudoers.d/simai-panel)"
cli panel gate-disable --confirm yes >/dev/null 2>&1
[[ "$(page '?format=json' | field 'd["gateway"]')" == ok ]] && ok "gate-disable keeps the installed panel's access" || bad "panel lost the gateway"
cli panel remove --confirm yes >/dev/null 2>&1

# Leave the container as other cases expect it.
cli site remove --domain keep.test --remove-files yes --confirm yes >/dev/null 2>&1
rm -f /etc/sudoers.d/simai-panel /usr/local/sbin/simai-panel-gate /etc/simai-env/panel.env
userdel simai-panel >/dev/null 2>&1 || true

echo "failures=${fails}"
exit $(( fails > 0 ))

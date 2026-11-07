#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# panel install / update / setup-link / status / remove: the panel is an isolated site
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

# As install.sh leaves a new server: only the core profiles are enabled.
had_profiles=no; [[ -f /etc/simai-env/profiles.enabled ]] && { had_profiles=yes; cp /etc/simai-env/profiles.enabled /root/profiles.enabled.saved; }
cli profile init --mode core --force yes --confirm yes >/dev/null 2>&1

cli panel status 2>&1 | grep 'not installed' >/dev/null && ok "status before install" || bad "status before install"
cli panel install --domain $P >/tmp/pl 2>&1
[[ ! -f /etc/nginx/sites-available/$P.conf ]] && ok "install without confirm changes nothing" || bad "plan created the site"
cli panel install --domain $P --placeholder yes --confirm yes >/tmp/pi 2>&1 && ok "panel install (placeholder)" || { bad "panel install"; tail -15 /tmp/pi; }
token=$(sed -n 's#.*?setup=\([a-f0-9]\{64\}\)$#\1#p' /tmp/pi | head -n1)
[[ -n "$token" ]] && ok "install prints a one-time sign-in link" || bad "no setup link: $(tail -3 /tmp/pi)"
grep -rqs "$token" /var/log/simai-admin.log /var/log/simai-audit.log /var/log/simai-panel-gate.log && bad "setup token in a log" || ok "setup token stays out of the logs"

project=$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$P.conf)
user=$(cat "/etc/simai-env/site-users/$project")
[[ "$user" == site-* ]] && ok "panel runs as its own account ($user)" || bad "panel account: $user"
[[ "$(page '?format=json' | field 'd["gateway"]')" == ok ]] && ok "placeholder reaches the gateway" || bad "placeholder gateway: $(page '?format=json')"
[[ "$(page "?format=json&setup=${token}" | field 'd["setup"]')" == valid ]] && ok "setup link is valid" || bad "setup link"
[[ "$(page '?format=json&setup=0000' | field 'd["setup"]')" == invalid ]] && ok "wrong setup link is refused" || bad "wrong link accepted"
page '' | grep 'not reachable' >/dev/null && bad "html page reports no gateway" || ok "placeholder page renders"
page '' | grep -E 'keep\.test|simai_env|php_versions' >/dev/null && bad "placeholder leaks server data" || ok "placeholder shows no server data"
sudo -n -u "$user" sudo -n /bin/true >/dev/null 2>&1 && bad "panel account has wider sudo" || ok "panel account may run only the gateway"
[[ "$(printf '{"schema":"simai-panel-request/1","request_id":"p1","actor":{"user":"a","owner":null},"command":"self:describe","args":{}}' | sudo -n -u "$user" sudo -n /usr/local/sbin/simai-panel-gate | field '{"keep.test", "panel.test"} <= {s["domain"] for s in d["data"]["sites"]}')" == True ]] && ok "panel account calls the gateway" || bad "panel account gateway call"

cli panel status 2>&1 | grep 'placeholder' >/dev/null && ok "status shows the placeholder" || bad "status after install"
cli panel install --domain $P --placeholder yes --confirm yes >/dev/null 2>&1 && bad "second placeholder install accepted" || ok "reinstalling the placeholder is refused"
cli panel install --domain other.test --placeholder yes --confirm yes >/dev/null 2>&1 && bad "second panel accepted" || ok "a second panel domain is refused"
cli panel install --domain keep.test --git https://example.com/x --ref v1 --confirm yes >/dev/null 2>&1; [[ "$(curl -s -H 'Host: keep.test' http://127.0.0.1/)" == keep-site ]] && ok "an existing site is never taken over" || bad "keep.test changed"

cli panel setup-link --confirm yes >/tmp/ps 2>&1
new=$(sed -n 's#.*?setup=\([a-f0-9]\{64\}\)$#\1#p' /tmp/ps | head -n1)
[[ -n "$new" && "$new" != "$token" ]] && ok "setup-link makes a new link" || bad "setup-link"
[[ "$(page "?format=json&setup=${token}" | field 'd["setup"]')" == invalid ]] && ok "the old link stops working" || bad "old link still valid"
[[ "$(page "?format=json&setup=${new}" | field 'd["setup"]')" == valid ]] && ok "the new link works" || bad "new link"

# A build replaces the placeholder. Installing a build goes through
# site adopt, so it gets its requirements, .env, database, APP_KEY and
# releases; a build that does not answer leaves nothing behind.
mk_build() {  # $1 label, $2 broken
  local dir=/root/build-$1
  rm -rf "$dir"; mkdir -p "$dir/public" "$dir/bootstrap/cache" "$dir/storage/logs" "$dir/.simai" "$dir/vendor"
  if [[ "${2:-}" == broken ]]; then
    printf '<?php http_response_code(500); echo "broken";\n' >"$dir/public/index.php"
  else
    printf '<?php echo "panel-%s";\n' "$1" >"$dir/public/index.php"
  fi
  printf '<?php return null;\n' >"$dir/bootstrap/app.php"
  printf '<?php return [];\n' >"$dir/vendor/autoload.php"
  printf '{"name":"larena/env","require":{"php":">=8.2"}}\n' >"$dir/composer.json"
  printf 'APP_NAME=LarenaPanel\nAPP_ENV=local\nAPP_DEBUG=true\nAPP_KEY=\n' >"$dir/.env.example"
  printf '{"schema":"simai-app/1","migrate":true,"scheduler":false}\n' >"$dir/.simai/app.json"
  cat >"$dir/artisan" <<'PHP'
#!/usr/bin/env php
<?php
// Stands in for the Larena build: key:generate writes the key, and migrations
// need the database settings, readable by the account that runs them.
$env = __DIR__ . '/.env';
if (($argv[1] ?? '') === 'migrate' && !preg_match('/^DB_DATABASE=./m', (string) @file_get_contents($env))) {
    fwrite(STDERR, "no database settings in .env\n");
    exit(1);
}
if (($argv[1] ?? '') === 'key:generate') {
    $body = is_file($env) ? preg_replace('/^APP_KEY=.*$/m', '', file_get_contents($env)) : '';
    file_put_contents($env, rtrim($body) . "\nAPP_KEY=base64:" . base64_encode(random_bytes(32)) . "\n");
}
exit(0);
PHP
  chmod +x "$dir/artisan"
  tar -C "$dir" -czf "/root/build-$1.tgz" .
  sha256sum "/root/build-$1.tgz" | cut -d' ' -f1
}
grep -q laravel /etc/simai-env/profiles.enabled && bad "the test expects laravel disabled" || ok "laravel is not enabled on a new server"
s1=$(mk_build v1)
cli panel install --domain $P --archive /root/build-v1.tgz --sha256 "$s1" --confirm yes >/tmp/pb 2>&1 && ok "panel install with a build archive" || { bad "build install"; tail -15 /tmp/pb; tail -20 /var/log/simai-admin.log; }
[[ "$(page '')" == panel-v1 ]] && ok "the build replaced the placeholder" || bad "build not served: $(page '' | head -c 200)"
grep -q '^# simai-profile: laravel' /etc/nginx/sites-available/$P.conf && ok "the build runs as a Laravel site" || bad "profile"
[[ -f /etc/simai-env/sites/$P/db.env ]] && ok "the build has a database" || bad "no database"
env=/home/simai/www/$P/.env
grep -q '^APP_KEY=base64:' $env && ok "the build gets an APP_KEY" || bad "APP_KEY: $(grep -c . $env) lines"
grep -q '^APP_ENV=production' $env && grep -q '^APP_DEBUG=false' $env && ok "the panel runs in production mode" || bad "app env: $(grep -E '^APP_(ENV|DEBUG)=' $env)"
grep -q "^APP_URL=http://$P" $env && ok "APP_URL is the panel domain" || bad "APP_URL: $(grep '^APP_URL=' $env)"
grep -q '^DB_DATABASE=' $env && ok "the build knows its database" || bad "no DB_ settings in .env"
if grep -q '^DB_CONNECTION=mysql' $env; then
  db_user=$(sed -n 's/^DB_USERNAME=//p' $env)
  mysql -Ne "SHOW GRANTS FOR '${db_user}'@'localhost'" | grep 'REFERENCES' >/dev/null && ok "the database user may create foreign keys" || bad "no REFERENCES grant"
fi
project=$(sed -n 's/^# simai-project: *//p' /etc/nginx/sites-available/$P.conf)
user2=$(cat "/etc/simai-env/site-users/$project")
[[ "$(stat -c '%U %a' $env)" == "$user2 640" ]] && ok ".env belongs to the panel account only" || bad ".env: $(stat -c '%U %a' $env)"
[[ -L /home/simai/www/$P/current ]] && ok "the build has releases to roll back to" || bad "no release layout"
cli panel status 2>&1 | grep 'build' >/dev/null && ok "status shows the build" || bad "status build"
grep -q "^${user2} ALL=(root) NOPASSWD: /usr/local/sbin/simai-panel-gate \"\"" /etc/sudoers.d/simai-panel && ok "gateway rule follows the build's account" || bad "sudoers: $(cat /etc/sudoers.d/simai-panel)"
grep -q '^SIMAI_PANEL_SETUP_TOKEN=[a-f0-9]\{64\}$' $env && ok "the build gets a setup token in .env" || bad "token for build"
[[ "$(printf '{"schema":"simai-panel-request/1","request_id":"p2","actor":{"user":"a","owner":null},"command":"self:describe","args":{}}' | sudo -n -u "$user2" sudo -n /usr/local/sbin/simai-panel-gate | field 'd["status"]')" == ok ]] && ok "the build calls the gateway" || bad "build gateway call"
s2=$(mk_build v1 broken)
cli panel install --domain $P --archive /root/build-v1.tgz --sha256 "$s2" --confirm yes >/dev/null 2>&1 && bad "a second build install accepted" || ok "installing over a build points at panel update"

# panel update: data backup, deploy, health check, rollback when it fails.
cli panel update >/tmp/pu0 2>&1; [[ "$(page '')" == panel-v1 ]] && ok "update without confirm changes nothing" || bad "update ran without confirm"
s3=$(mk_build v2)
cli panel update --archive /root/build-v2.tgz --sha256 "$s3" --confirm yes >/tmp/pu 2>&1 && ok "panel update" || { bad "panel update"; tail -15 /tmp/pu; }
[[ "$(page '')" == panel-v2 ]] && ok "the new release is served" || bad "after update: $(page '' | head -c 120)"
[[ -n "$(ls -A /var/backups/simai/$P 2>/dev/null)" ]] && ok "update backs up the panel data first" || bad "no backup before the update"
grep -q '^APP_KEY=base64:' $env && grep -q '^SIMAI_PANEL_SETUP_TOKEN=' $env && ok "the update keeps .env" || bad ".env changed by the update"
# A rollback before the broken update: the newest other release is then not
# the one that was serving.
cli site deploy-rollback --domain $P --confirm yes >/dev/null 2>&1
[[ "$(page '')" == panel-v1 ]] && ok "rollback serves the earlier release" || bad "after rollback: $(page '' | head -c 120)"
s4=$(mk_build v3 broken)
cli panel update --archive /root/build-v3.tgz --sha256 "$s4" --confirm yes >/tmp/pu3 2>&1 && bad "a broken release accepted" || ok "a broken release is refused"
[[ "$(page '')" == panel-v1 ]] && ok "a broken update returns to the release that was serving" || bad "after broken update: $(page '' | head -c 120)"
grep -q 'rolled back' /tmp/pu3 && ok "the rollback is reported" || bad "rollback message: $(tail -3 /tmp/pu3)"

cli panel remove >/dev/null 2>&1; [[ -f /etc/nginx/sites-available/$P.conf ]] && ok "remove without confirm changes nothing" || bad "remove ran without confirm"
cli panel remove --confirm yes >/tmp/pr 2>&1 && ok "panel remove" || { bad "panel remove"; tail -10 /tmp/pr; }
[[ ! -f /etc/nginx/sites-available/$P.conf && ! -d /home/simai/www/$P ]] && ok "panel site removed" || bad "panel site left"
[[ ! -f /etc/sudoers.d/simai-panel && ! -f /usr/local/sbin/simai-panel-gate ]] && ok "gateway removed with the panel" || bad "gateway left"
[[ "$(curl -s -H 'Host: keep.test' http://127.0.0.1/)" == keep-site ]] && ok "other sites keep working" || bad "keep.test broken"
cli panel status 2>&1 | grep 'not installed' >/dev/null && ok "status after remove" || bad "status after remove"

s5=$(mk_build v4 broken)
cli panel install --domain $P --archive /root/build-v4.tgz --sha256 "$s5" --confirm yes >/tmp/pbb 2>&1 && bad "a build that does not answer was installed" || ok "a build that does not answer is refused"
[[ ! -f /etc/nginx/sites-available/$P.conf && ! -d /home/simai/www/$P ]] && ok "a failed first install leaves nothing" || bad "leftovers: $(ls -d /home/simai/www/$P 2>/dev/null) $(ls /etc/nginx/sites-available/$P.conf 2>/dev/null)"
cli panel status 2>&1 | grep 'not installed' >/dev/null && ok "status after the failed install" || bad "status after failed install"
cli panel update --archive /root/build-v2.tgz --sha256 "$s3" --confirm yes >/dev/null 2>&1 && bad "update without a panel accepted" || ok "update needs an installed panel"

# The pinned build: a release file of its own, served by a local web server, so
# these checks need no network.
mkdir -p /root/rel/v1.0.0 /root/rel/v2.0.0
s6=$(mk_build r1); cp /root/build-r1.tgz /root/rel/v1.0.0/panel.tgz
s7=$(mk_build r2); cp /root/build-r2.tgz /root/rel/v2.0.0/panel.tgz
(cd /root/rel && exec python3 -m http.server 18099 --bind 127.0.0.1 >/dev/null 2>&1) &
httpd=$!; sleep 1
pin() { printf 'VERSION=%s\nSHA256=%s\nURL=http://127.0.0.1:18099/v{version}/panel.tgz\n' "$1" "$2" >/root/rel.env; }
export SIMAI_PANEL_RELEASE=/root/rel.env
pin 1.0.0 0000000000000000000000000000000000000000000000000000000000000000
cli panel install --domain $P --confirm yes >/tmp/pr1 2>&1 && bad "a download with a wrong checksum was installed" || ok "a wrong checksum is refused"
grep -q 'does not match its checksum' /tmp/pr1 && [[ ! -f /etc/nginx/sites-available/$P.conf && ! -e /home/simai/www/$P ]] && ok "the refused download changes nothing" || bad "after wrong checksum: $(tail -2 /tmp/pr1)"
pin 1.0.0 "$s6"
cli panel install --domain $P --confirm yes >/tmp/pr2 2>&1 && ok "panel install downloads the pinned build" || { bad "pinned install"; tail -5 /tmp/pr2; }
[[ "$(page '')" == panel-r1 ]] && ok "the pinned build is served" || bad "pinned build: $(page '' | head -c 120)"
cli panel status 2>&1 | grep 'Version.*1\.0\.0' >/dev/null && ok "status shows the version" || bad "status version: $(cli panel status 2>&1 | tail -8)"
cli panel update --confirm yes 2>&1 | grep 'nothing to do' >/dev/null && ok "update at the pinned version does nothing" || bad "update same version"
pin 2.0.0 "$s7"
up=$(cli self update-plan --target panel --output json 2>/dev/null)
[[ "$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["current"], d["available"], d["update_available"], d["checks"])' <<<"$up")" == "1.0.0 2.0.0 True ['${P}']" ]] && ok "update plan: installed and pinned versions, the checked panel" || bad "panel update plan: ${up:0:300}"
# self update --target panel is the panel's own path (the gateway's self:update).
cli self update --target panel --confirm yes >/tmp/pr3 2>&1 && ok "update moves to the newly pinned version" || { bad "pinned update"; tail -5 /tmp/pr3; }
[[ "$(page '')" == panel-r2 ]] && cli panel status 2>&1 | grep 'Version.*2\.0\.0' >/dev/null && ok "the new version is served and recorded" || bad "after pinned update: $(page '' | head -c 120)"
pin 1.0.0 "$s6"
cli panel update --confirm yes >/dev/null 2>&1 && bad "update stepped back to an older pin" || ok "update never steps back by itself"
cli panel update --version 1.0.0 --confirm yes >/dev/null 2>&1 && bad "--version without a checksum accepted" || ok "--version needs --sha256"
cli panel update --version 1.0.0 --sha256 "$s6" --confirm yes >/dev/null 2>&1 && [[ "$(page '')" == panel-r1 ]] && ok "--version with its checksum chooses a version" || bad "--version update: $(page '' | head -c 120)"
cli panel update --archive /root/build-r2.tgz --sha256 "$s7" --confirm yes >/dev/null 2>&1 && ! cli panel status 2>&1 | grep 'Version.*[0-9]\.[0-9]\.[0-9] .*|$' >/dev/null && ok "an archive is not recorded as a version" || bad "archive version"
# A build installed from its own archive declares its version in panel-build.json.
r=$(cli site describe --domain $P --output json 2>/dev/null | field 'd["data"]["root"]'); printf '{"version":"2.0.1-dev"}' >"$r/current/panel-build.json"
[[ "$(cli self update-plan --target panel --output json 2>/dev/null | field 'd["data"]["current"] + " " + str(d["data"]["update_available"]) + " " + d["data"]["restart_items"][0]["kind"] + " " + d["data"]["backup_item"]["kind"] + " " + d["data"]["rollback_kind"]')" == "2.0.1-dev False php_fpm_pool panel_data panel_release" ]] \
  && ok "the plan compares with the build's own version and answers codes" || bad "build version plan: $(cli self update-plan --target panel --output json 2>/dev/null | head -c 400)"
cli panel remove --confirm yes >/dev/null 2>&1
ls /tmp/tmp.*.tar.gz >/dev/null 2>&1 && bad "downloads left in /tmp" || ok "downloads are removed"
kill "$httpd" 2>/dev/null; unset SIMAI_PANEL_RELEASE

# The installer's options map to the same variables.
# (Not run: install.sh would replace this tree with the published release.)
grep -q -- '--panel-port) SIMAI_INSTALL_PANEL_PORT=' install.sh && grep -q 'panel_args=(panel install --confirm yes)' install.sh \
  && ok "--with-panel works without a domain, --panel-port sets the port" || bad "installer panel options"

# The real published builds: the previous one, then an update to the one
# this release pins, and back.
up() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: real.test' http://127.0.0.1/up; }
pinned=$(sed -n 's/^VERSION=//p' admin/panel-release.env)
cli panel install --domain real.test --version 0.2.0 --sha256 7c3c10df6b0cbb2080d97c96f2f26476c343aa38c0c6485cceb9330d01780b24 --confirm yes >/tmp/pr4 2>&1 && ok "the published build 0.2.0 installs" || { bad "published build"; tail -5 /tmp/pr4; tail -20 /var/log/simai-admin.log | cut -c1-160; }
[[ "$(up)" == 200 ]] && ok "the published build answers /up" || bad "/up of the published build"
grep -q '/?setup=[a-f0-9]\{64\}$' /tmp/pr4 && ok "the published build prints its first sign-in link" || bad "no link"
[[ "$(cli self update-plan --target panel --output json 2>/dev/null | field 'd["data"]["current"] + " " + d["data"]["available"] + " " + str(d["data"]["update_available"])')" == "0.2.0 ${pinned} True" ]] && ok "the plan offers ${pinned} over 0.2.0" || bad "real update plan"
cli self update --target panel --confirm yes >/tmp/pr5 2>&1 && [[ "$(up)" == 200 ]] && cli panel status 2>&1 | grep "Version.*${pinned}" >/dev/null && ok "update to the pinned ${pinned} answers /up" || { bad "update to ${pinned}"; tail -8 /tmp/pr5; }
cli site deploy-rollback --domain real.test --confirm yes >/tmp/pr6 2>&1 && [[ "$(up)" == 200 ]] && ok "rollback to 0.2.0 still answers /up" || { bad "rollback of the published build"; tail -5 /tmp/pr6; }
cli panel remove --confirm yes >/dev/null 2>&1

# A host that enabled the gateway before 1.23.0 has the sudo line but no state.
id -u simai-panel >/dev/null 2>&1 || useradd --system --user-group simai-panel
printf 'simai-panel ALL=(root) NOPASSWD: /usr/local/sbin/simai-panel-gate ""\n' >/etc/sudoers.d/simai-panel; chmod 0440 /etc/sudoers.d/simai-panel
sed -i '/^GATE_ACCOUNT=/d' /etc/simai-env/panel.env 2>/dev/null || true
cli panel install --domain $P --placeholder yes --confirm yes >/dev/null 2>&1
grep -q '^simai-panel ALL=' /etc/sudoers.d/simai-panel && ok "earlier gateway access survives panel install" || bad "simai-panel lost: $(cat /etc/sudoers.d/simai-panel)"
cli panel remove --confirm yes >/dev/null 2>&1
grep -q '^simai-panel ALL=' /etc/sudoers.d/simai-panel 2>/dev/null && ok "and panel remove" || bad "simai-panel lost on remove"
cli panel gate-disable --confirm yes >/dev/null 2>&1

# The stand account and the installed panel share one sudo file.
cli panel gate-enable --confirm yes >/dev/null 2>&1
cli panel install --domain $P --placeholder yes --confirm yes >/dev/null 2>&1
[[ "$(grep -c 'NOPASSWD' /etc/sudoers.d/simai-panel)" == 2 ]] && ok "both gateway accounts listed" || bad "sudo lines: $(cat /etc/sudoers.d/simai-panel)"
cli panel gate-disable --confirm yes >/dev/null 2>&1
[[ "$(page '?format=json' | field 'd["gateway"]')" == ok ]] && ok "gate-disable keeps the installed panel's access" || bad "panel lost the gateway"
cli panel remove --confirm yes >/dev/null 2>&1

# Without a domain (1.51.0): the panel answers on the server's address and
# port 8500 with a self-signed certificate; a domain is attached later.
port() { curl -sk --max-time 10 "https://127.0.0.1:${2:-8500}/$1"; }
cli panel install --placeholder yes --confirm yes >/tmp/pn 2>&1 && ok "panel install without a domain" || { bad "install without a domain"; tail -15 /tmp/pn; }
grep -q 'By IP: *https://.*:8500' /tmp/pn && ok "install prints the address by IP and port" || bad "no IP address: $(tail -12 /tmp/pn)"
grep -qE '^ +https://.*:8500/\?setup=[a-f0-9]{64}$' /tmp/pn && ok "the sign-in link uses that address" || bad "sign-in link: $(tail -6 /tmp/pn)"
grep -q 'SHA-256' /tmp/pn && ok "install prints the certificate fingerprint" || bad "no fingerprint"
cli self firewall-ensure 2>&1 | grep 'allow the panel port 8500' >/dev/null && ok "firewall-ensure keeps the panel port" || bad "firewall plan without the panel port"
a=$(cli security status --output json 2>/dev/null)
[[ "$(field '[c["check"] for c in d["data"]["checks"] if c.get("domain") == "panel.internal" and c["check"] in ("https", "panel_domain")]' <<<"$a")" == "['panel_domain']" ]] && ok "the panel without a domain is not an HTTPS problem" || bad "security checks of panel.internal: $(field '[c["id"] for c in d["data"]["checks"] if c.get("domain") == "panel.internal"]' <<<"$a" 2>&1 | head -c 300)"
[[ "$(port '?format=json' | field 'd["gateway"]')" == ok ]] && ok "the panel answers on port 8500" || bad "port 8500: $(port '?format=json' | head -c 300)"
curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8500/ | grep 301 >/dev/null && ok "plain HTTP on the port goes to HTTPS" || bad "http on 8500"
a=$(cli panel address --output json 2>/dev/null)
[[ "$(field 'd["data"]["port"] == 8500 and d["data"]["ip_access"] and d["data"]["domain"] is None and d["data"]["ip_url"].endswith(":8500") and d["data"]["ip_certificate"]["kind"] == "self-signed"' <<<"$a")" == True ]] && ok "panel address" || bad "address: ${a:0:400}"
[[ -f /etc/nginx/conf.d/simai-panel-address.conf ]] && ! grep -q 'simai-managed' /etc/nginx/conf.d/simai-panel-address.conf && ok "the address is not a site of its own" || bad "address file"
cli site list 2>/dev/null | grep 'simai-panel-address' >/dev/null && bad "address listed as a site" || ok "site list unchanged"
cli panel port --port 22 --confirm yes >/dev/null 2>&1 && bad "SSH port accepted" || ok "a port of another service is refused"
cli panel port --port 8600 --confirm yes >/tmp/pp 2>&1 && ok "panel port 8600" || { bad "panel port"; tail -8 /tmp/pp; }
[[ "$(port '?format=json' 8600 | field 'd["gateway"]')" == ok && -z "$(port '' 8500)" ]] && ok "the panel moved to 8600" || bad "after the move"
id=$(sed -n 's/.*change confirm --id \([a-f0-9]\{12\}\).*/\1/p' /tmp/pp | head -n1)
cli change restore --id "$id" --confirm yes >/dev/null 2>&1
[[ "$(port '?format=json' | field 'd["gateway"]')" == ok && "$(cli panel address --output json 2>/dev/null | field 'd["data"]["port"]')" == 8500 ]] && ok "an unconfirmed move is undone" || bad "undo of the move"
cli panel port --port 8601 --confirm yes >/tmp/pp 2>&1
id=$(sed -n 's/.*change confirm --id \([a-f0-9]\{12\}\).*/\1/p' /tmp/pp | head -n1)
cli change confirm --id "$id" --confirm yes >/dev/null 2>&1
cli panel port --port 8500 --confirm yes >/tmp/pp 2>&1
id=$(sed -n 's/.*change confirm --id \([a-f0-9]\{12\}\).*/\1/p' /tmp/pp | head -n1)
cli change confirm --id "$id" --confirm yes >/dev/null 2>&1 && [[ "$(port '?format=json' | field 'd["gateway"]')" == ok ]] && ok "a confirmed move stays" || bad "confirm move: $(tail -5 /tmp/pp)"
cli panel ip-access --enabled no --confirm yes >/dev/null 2>&1 && bad "IP access off without a domain" || ok "IP access stays on while there is no domain"
cli panel domain --domain nowhere.invalid --confirm yes >/tmp/pd 2>&1 && bad "a domain that points elsewhere" || ok "a domain that does not point here is refused"
cli panel domain --domain keep.test --check-dns no --confirm yes >/dev/null 2>&1 && bad "a site's domain taken" || ok "a site's domain is refused"
cli panel domain --domain panel-new.test --check-dns no --confirm yes >/tmp/pd 2>&1 && bad "certificate without the internet" || ok "no certificate: the domain is not attached"
wr=$(sed -n 's#^[[:space:]]*alias \(.*\)/\.well-known/acme-challenge/;#\1#p' "/etc/nginx/sites-available/$(cli panel address --output json 2>/dev/null | field 'd["data"]["site_domain"]').conf" | head -n1)
echo probe-ok > "$wr/.well-known/acme-challenge/probe" 2>/dev/null
! grep -q 'does not exist or is not a directory' /tmp/pd && [[ "$(curl -sk --max-time 10 "https://127.0.0.1:$(python3 -I lib/panel_address.py get port)/.well-known/acme-challenge/probe")" == probe-ok ]] \
  && ok "the certificate check folder is prepared and served" || bad "acme webroot ${wr}: $(grep -i 'exist' /tmp/pd | head -2)"
rm -f "$wr/.well-known/acme-challenge/probe"
[[ "$(cli panel address --output json 2>/dev/null | field 'd["data"]["domain"]')" == None ]] && ! grep -q panel-new.test /etc/nginx/conf.d/simai-panel-address.conf && ok "and nothing is left of it" || bad "domain left after a failed certificate"
# A domain with a certificate (made here instead of by Let's Encrypt).
mkdir -p /etc/letsencrypt/live/panel-new.test
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=panel-new.test -keyout /etc/letsencrypt/live/panel-new.test/privkey.pem -out /etc/letsencrypt/live/panel-new.test/fullchain.pem >/dev/null 2>&1
python3 -I lib/panel_address.py set domain panel-new.test && python3 -I lib/panel_address.py set domain_ssl yes
cli self status-refresh --confirm yes >/dev/null 2>&1
sleep 2  # nginx applies a reload after the signal returns
[[ "$(curl -sk --max-time 10 --resolve panel-new.test:443:127.0.0.1 'https://panel-new.test/?format=json' | field 'd["gateway"]')" == ok ]] && ok "the domain answers over HTTPS" || { bad "domain https: $(curl -sk --max-time 10 --resolve panel-new.test:443:127.0.0.1 'https://panel-new.test/?format=json' | head -c 200)"; nginx -t 2>&1 | tail -3; ss -ltn | grep -E ':(443|8500) '; journalctl -u nginx --no-pager | tail -5; grep -E 'nginx|emerg|panel' /var/log/simai-admin.log | tail -8 | cut -c1-200; }
pp=$(python3 -I lib/panel_address.py get port)
openssl s_client -connect 127.0.0.1:"$pp" -servername panel-new.test </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep 'panel-new.test' >/dev/null \
  && [[ "$(curl -sk --max-time 10 --resolve panel-new.test:"$pp":127.0.0.1 "https://panel-new.test:$pp/?format=json" | field 'd["gateway"]')" == ok ]] \
  && ok "the domain on the panel port has its own certificate" || bad "domain on port $pp: $(openssl s_client -connect 127.0.0.1:"$pp" -servername panel-new.test </dev/null 2>/dev/null | openssl x509 -noout -subject 2>&1)"
openssl s_client -connect 127.0.0.1:"$pp" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep 'SIMAI Panel' >/dev/null && ok "the address by IP keeps the self-signed certificate" || bad "IP cert on port $pp"
curl -s -o /dev/null -w '%{http_code}' -H 'Host: panel-new.test' http://127.0.0.1/ | grep 301 >/dev/null && ok "and HTTP goes to HTTPS" || bad "domain http redirect"
[[ "$(cli panel address --output json 2>/dev/null | field 'd["data"]["url"]')" == https://panel-new.test ]] && ok "the domain is the panel's address" || bad "address url"
cli panel domain --remove yes --confirm yes >/dev/null 2>&1 && ! grep -q panel-new.test /etc/nginx/conf.d/simai-panel-address.conf && ok "panel domain --remove yes" || bad "domain remove"
rm -rf /etc/letsencrypt/live/panel-new.test
cli panel remove --confirm yes >/dev/null 2>&1
sleep 2
[[ ! -f /etc/nginx/conf.d/simai-panel-address.conf && -z "$(port '')" ]] && ok "panel remove closes the port" || { bad "port left after remove: $(port '' | head -c 200)"; ss -ltn | grep -E ':(8500) '; journalctl -u nginx --no-pager | tail -5; }

# Leave the container as other cases expect it.
if [[ "$had_profiles" == yes ]]; then cp /root/profiles.enabled.saved /etc/simai-env/profiles.enabled; else rm -f /etc/simai-env/profiles.enabled; fi
cli site remove --domain keep.test --remove-files yes --confirm yes >/dev/null 2>&1
rm -f /etc/sudoers.d/simai-panel /usr/local/sbin/simai-panel-gate /etc/simai-env/panel.env
userdel simai-panel >/dev/null 2>&1 || true

echo "failures=${fails}"
exit $(( fails > 0 ))

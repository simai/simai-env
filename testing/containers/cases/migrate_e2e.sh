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
rm -rf /home/simai/runtime-observer/x
mkdir -p "$L/.git/hooks" "$L/.git/info" /home/simai/runtime-observer/rim1-ru/state
git -C "$L" init -q 2>/dev/null || true
printf '#!/bin/sh\ntouch /tmp/pwned-hook\n' >"$L/.git/hooks/pre-commit"; chmod +x "$L/.git/hooks/pre-commit"
printf '[filter "x"]\n\tclean = touch /tmp/pwned-filter\n' >>"$L/.git/config"
echo '* filter=x' >"$L/.git/info/attributes"
chown -R root:root /home/simai/runtime-observer
printf '*/5 * * * * root /root/simai-env/simai-admin.sh observer snapshot --domain rim1.ru >/dev/null 2>&1\n' >/etc/cron.d/simai-runtime-observer-rim1-ru
# A TLS Bitrix site rendered by an earlier release: no HTTP/2, no nosniff.
openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj /CN=legacy.test -addext subjectAltName=DNS:legacy.test \
  -keyout /etc/nginx/legacy.key -out /etc/nginx/legacy.crt >/dev/null 2>&1
mkdir -p /srv/legacy/bitrix/cache && echo ok >/srv/legacy/index.html && echo 'a{}' >/srv/legacy/bitrix/cache/a.css && chmod -R a+rX /srv/legacy
{
  printf '# simai-domain: legacy.test\n# simai-profile: bitrix\n# simai-project: legacy-test\n'
  sed -e '/X-Content-Type-Options/d; /Locations with their own add_header/d' \
    -e 's#{{SERVER_NAME}}#legacy.test#; s#{{DOC_ROOT}}#/srv/legacy#; s#{{ACME_ROOT}}#/srv/legacy#' \
    -e 's#{{PROJECT_NAME}}#legacy-test#g; s#{{PHP_VERSION}}#8.3#g; s#{{PHP_SOCKET_PROJECT}}#legacy-test#g' \
    -e 's#^    listen 80;#    listen 80;\n    listen 443 ssl;\n    ssl_certificate /etc/nginx/legacy.crt;\n    ssl_certificate_key /etc/nginx/legacy.key;#' templates/nginx-bitrix.conf
} >/etc/nginx/sites-available/legacy.test.conf
ln -sf /etc/nginx/sites-available/legacy.test.conf /etc/nginx/sites-enabled/legacy.test.conf
nginx -t >/dev/null 2>&1 && systemctl reload nginx || bad "legacy site rejected by nginx"
bash ./simai-admin.sh self migrate --confirm yes >/tmp/m 2>&1 || { bad "self migrate rc"; tail /tmp/m; }
grep -q 'legacy.test: http2, nosniff' /tmp/m && ok "migration reports http2 and nosniff" || { bad "legacy site not migrated"; grep -i legacy /tmp/m; }
compgen -G '/etc/nginx/sites-available/legacy.test.conf.bak.*' >/dev/null && ok "previous config kept for rollback" || bad "no rollback copy"
h2() { curl --http2 -skI --max-time 5 --resolve "legacy.test:443:127.0.0.1" "https://legacy.test$1" | tr -d '\r'; }
# Until the reload completes, old workers still accept connections with the
# previous config: wait for five consistent answers in a row.
migrated() { h2 /index.html | grep -qi '^x-content-type-options: nosniff$'; }
n=0; for _ in {1..100}; do if migrated; then n=$((n + 1)); ((n >= 5)) && break; else n=0; fi; sleep 0.2; done
hdr=$(h2 /index.html)
head -n1 <<<"$hdr" | grep -q '^HTTP/2 200' && ok "legacy site upgraded to HTTP/2" || bad "legacy: $(head -n1 <<<"$hdr")"
grep -qi '^x-content-type-options: nosniff$' <<<"$hdr" && ok "legacy site sends nosniff" || bad "legacy: no nosniff"
grep -qi '^x-content-type-options: nosniff$' <<<"$(h2 /bitrix/cache/a.css)" && ok "legacy static location sends nosniff" || bad "legacy static: no nosniff"
nginx -t 2>&1 | grep -qi deprecated && bad "migrated config warns: $(nginx -t 2>&1 | grep -i deprecated)" || ok "migrated config has no deprecation warning"
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
grep -q -- '--confirm yes' /etc/cron.d/simai-runtime-observer-rim1-ru && ok 'managed observer cron confirmation migrated' || bad 'cron confirmation'
bash ./simai-admin.sh self migrate --confirm yes >/tmp/migrate-second.out 2>&1
grep -q "nothing to migrate" /tmp/migrate-second.out && ok "second run is a no-op" || { bad "not idempotent"; tail /tmp/migrate-second.out; }
echo "failures=$fails"; exit $fails

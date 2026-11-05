#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Apache mode: nginx in front, Apache on 127.0.0.1 reading .htaccess, PHP
# through the site's own PHP-FPM pool; back to nginx; refused for non-PHP
# profiles; removed with the site; through the panel gateway (admin only).
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
D=ht.test
get() { curl -s --max-time 5 -H "Host: $D" "${@:2}" "http://127.0.0.1$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
wait_code() { local _; for _ in {1..20}; do [[ "$(code "$1")" == "$2" ]] && return 0; sleep 0.5; done; return 1; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain "$D" --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["root"]')
pub="$root/public"
project=$(sed -n 's/^# simai-project: *//p' "/etc/nginx/sites-available/$D.conf" | head -1)
cat >"$pub/index.php" <<'EOF'
<?php echo "page=", $_GET['p'] ?? '-', " https=", $_SERVER['HTTPS'] ?? 'off', " ip=", $_SERVER['REMOTE_ADDR'];
EOF
printf 'RewriteEngine On\nRewriteRule ^pretty$ index.php?p=pretty [L,QSA]\n' >"$pub/.htaccess"
mkdir -p "$pub/secret"; echo hidden >"$pub/secret/x.txt"; printf 'Require all denied\n' >"$pub/secret/.htaccess"
chown -R simai:www-data "$pub"
[[ "$(code /secret/x.txt)" == 200 ]] && ok "on nginx .htaccess is ignored" || bad "nginx secret: $(code /secret/x.txt)"

cli site apache --domain "$D" --enable yes >/tmp/o 2>&1
[[ ! -e "/etc/simai-env/sites/$D/web.env" ]] && grep -q 'Apache' /tmp/o && ok "without confirm only a plan" || { bad "plan"; tail -5 /tmp/o; }
cli site apache --domain "$D" --enable yes --confirm yes >/tmp/o 2>&1 && ok "Apache mode applies" || { bad "apply"; tail -15 /tmp/o; }
ss -ltn | grep -q '127.0.0.1:8088 ' && ! ss -ltn | grep -qE '(\*|0\.0\.0\.0|\[::\]):8088 ' && ok "Apache listens on 127.0.0.1 only" || bad "listen: $(ss -ltn | grep 8088)"
ss -ltnp | grep ':80 ' | grep -q nginx && ! ss -ltnp | grep ':80 ' | grep -q apache && ok "nginx keeps port 80" || bad "port 80"
wait_code /secret/x.txt 403 && ok ".htaccess Require denies a folder" || bad "secret: $(code /secret/x.txt)"
[[ "$(get /pretty)" == "page=pretty https=off ip=127.0.0.1" ]] && ok ".htaccess rewrite runs PHP through the pool" || bad "pretty: $(get /pretty)"
[[ "$(get /pretty -H 'X-Forwarded-Proto: https')" == *"https=off"* ]] && ok "a client cannot fake HTTPS" || bad "https spoof: $(get /pretty -H 'X-Forwarded-Proto: https')"
[[ "$(code /.htaccess)" == 403 ]] && ok ".htaccess itself is not served" || bad "htaccess: $(code /.htaccess)"
[[ "$(code /healthcheck.php)" == 200 ]] && ok "the health check still answers" || bad "healthcheck: $(code /healthcheck.php)"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: nobody.test' http://127.0.0.1:8088/)" == 403 ]] && ok "Apache refuses unknown names" || bad "apache default"
[[ "$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["web_server"]')" == apache ]] && ok "site describe says apache" || bad "describe"
[[ "$(cli software list --output json 2>/dev/null | js "[c['installed'] for c in d['data']['components'] if c['name']=='apache'][0]")" == True ]] && ok "software list shows Apache" || bad "software list"
cli site apache --domain "$D" --enable yes --confirm yes >/tmp/o 2>&1 && grep -q 'already' /tmp/o && ok "enabling twice changes nothing" || bad "twice"

# Re-rendering the site (HTTPS off/on paths use the same renderer) keeps Apache mode.
cli ssl remove --domain "$D" >/dev/null 2>&1
wait_code /secret/x.txt 403 && grep -q 'proxy_pass http://127.0.0.1:8088' "/etc/nginx/sites-available/$D.conf" && ok "a re-render keeps Apache mode" || bad "re-render"

# A broken Apache vhost is refused and nothing changes.
cli site apache --domain "$D" --enable no --confirm yes >/dev/null 2>&1
wait_code /secret/x.txt 200 && [[ ! -e "/etc/apache2/sites-available/simai-${project}.conf" ]] && ok "back to nginx removes the Apache vhost" || bad "disable"
[[ "$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["web_server"]')" == nginx ]] && ok "site describe says nginx" || bad "describe nginx"
cp templates/apache-site.conf /tmp/tpl.bak; printf 'NoSuchDirective on\n' >>templates/apache-site.conf
cli site apache --domain "$D" --enable yes --confirm yes >/tmp/o 2>&1 && bad "a broken Apache config was kept" \
  || { [[ ! -e "/etc/simai-env/sites/$D/web.env" ]] && wait_code /secret/x.txt 200 && ok "a config Apache rejects changes nothing" || { bad "broken"; tail -5 /tmp/o; }; }
cp /tmp/tpl.bak templates/apache-site.conf

cli site add --domain st.test --profile static --confirm yes >/dev/null 2>&1
cli site apache --domain st.test --enable yes --confirm yes >/tmp/o 2>&1 && bad "static site accepted" || { grep -q 'PHP sites' /tmp/o && ok "non-PHP profiles are refused" || bad "static: $(tail -2 /tmp/o)"; }
cli site remove --domain st.test --remove-files yes --confirm yes >/dev/null 2>&1

# Through the panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
[[ "$(gate "$(req '"acme"' site:apache "{\"domain\":\"$D\",\"enable\":\"yes\"}")" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot switch Apache mode" || bad "owner"
[[ "$(gate "$(req null site:apache "{\"domain\":\"$D\",\"enable\":\"yes\"}")" | js 'd["kind"]')" == plan ]] && ok "site:apache answers a plan" || bad "gate plan"
a=$(gate "$(req null site:apache "{\"domain\":\"$D\",\"enable\":\"yes\"}" 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..90}; do st=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")"); s=$(js 'd["data"]["state"]' <<<"$st"); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded ]] && wait_code /secret/x.txt 403 && ok "the job switches the site to Apache" || bad "gate job: $s ${st:0:300}"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain "$D" --remove-files yes --confirm yes >/dev/null 2>&1
[[ ! -e "/etc/apache2/sites-available/simai-${project}.conf" && ! -e "/etc/simai-env/sites/$D" ]] && ok "removing the site removes its Apache vhost" || bad "left after remove"
echo "failures=${fails}"
exit $(( fails > 0 ))

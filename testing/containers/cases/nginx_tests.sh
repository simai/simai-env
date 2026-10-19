#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq nginx curl openssl >/dev/null 2>&1
cd /src
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
echo "nginx: $(nginx -v 2>&1)"
rm -f /etc/nginx/sites-enabled/default
mkdir -p /etc/nginx/snippets
[[ -f /etc/nginx/snippets/fastcgi-php.conf ]] || echo 'fastcgi_split_path_info ^(.+?\.php)(/.*)$; try_files $fastcgi_script_name =404; include fastcgi_params;' >/etc/nginx/snippets/fastcgi-php.conf

render() {
  local name="$1" host="$2" root="/srv/${1}"
  mkdir -p "$root"
  sed -e "s#{{SERVER_NAME}}#${host}#g" -e "s#{{DOC_ROOT}}#${root}#g" -e "s#{{ACME_ROOT}}#${root}#g" \
    -e "s#{{PROJECT_NAME}}#${name}#g" -e "s#{{PHP_VERSION}}#8.2#g" -e "s#{{PHP_SOCKET_PROJECT}}#${name}#g" \
    "templates/nginx-${name}.conf" >"/etc/nginx/sites-enabled/${name}.conf"
}
for t in generic laravel static wordpress bitrix; do render "$t" "${t}.test"; done

# Fixture files that must be denied or served.
for t in generic laravel static wordpress bitrix; do
  r="/srv/${t}"
  mkdir -p "$r/sub/.git" "$r/.well-known/acme-challenge" "$r/wp-content/uploads" "$r/bitrix/backup" "$r/bitrix/cache/css" "$r/local/php_interface"
  echo ok >"$r/index.html"; echo secret >"$r/sub/.git/config"; echo secret >"$r/.env"
  echo dump >"$r/dump.sql"; echo tok >"$r/.well-known/acme-challenge/t"; echo x >"$r/app.log"
  echo '<?php' >"$r/wp-content/uploads/shell.php"; echo bk >"$r/bitrix/backup/site.tar.gz"
  echo 'a{}' >"$r/bitrix/cache/css/a.css"; echo '<?php' >"$r/local/php_interface/init.php"
  echo 'a{}' >"$r/bitrix/backup/x.css"
done
chmod -R a+rX /srv

# Catch-all through the real function.
LOG_FILE=/tmp/simai.log; : >"$LOG_FILE"
warn() { echo "warn: $*"; }
export SCRIPT_DIR=/src SIMAI_ENV_ROOT=/src SIMAI_USER=root
set +u; source admin/lib/site_utils.sh; set +e; set -u
warn() { echo "warn: $*"; }
mkdir -p /etc/nginx/sites-available
ensure_nginx_catchall
grep -q simai-catchall-v2 /etc/nginx/sites-available/000-catchall.conf && ok "catch-all v2 written" || bad "catch-all fell back: $(cat /etc/nginx/sites-available/000-catchall.conf)"

# A TLS site so 443 has a real vhost besides the catch-all.
openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj /CN=generic.test -keyout /etc/nginx/g.key -out /etc/nginx/g.crt >/dev/null 2>&1
sed -i 's#    listen 80;#    listen 80;\n    listen 443 ssl;\n    ssl_certificate /etc/nginx/g.crt;\n    ssl_certificate_key /etc/nginx/g.key;#' /etc/nginx/sites-enabled/generic.conf

nginx -t >/tmp/t 2>&1 && ok "nginx -t passes with all templates" || { bad "nginx -t"; cat /tmp/t; }
systemctl reload nginx
for _ in {1..50}; do
  curl -fs --max-time 2 -H 'Host: generic.test' http://127.0.0.1/index.html >/dev/null 2>&1 && break
  sleep 0.1
done

code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1$2"; }
expect() { local got; got=$(code "$1" "$2"); [[ "$got" == "$3" ]] && ok "$1$2 -> $got" || bad "$1$2 -> $got (want $3)"; }

for t in generic laravel static wordpress bitrix; do
  h="${t}.test"
  expect "$h" /index.html 200
  expect "$h" /sub/.git/config 403
  expect "$h" /.env 403
  expect "$h" /dump.sql 403
  expect "$h" /app.log 403
  expect "$h" /.well-known/acme-challenge/t 200
done
expect wordpress.test /wp-content/uploads/shell.php 403
expect bitrix.test /bitrix/backup/site.tar.gz 403
expect bitrix.test /bitrix/backup/x.css 403
expect bitrix.test /local/php_interface/init.php 403
expect bitrix.test /bitrix/cache/css/a.css 200

# Unknown host / bare IP must not reach a site.
rc=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' http://127.0.0.1/index.html); [[ "$rc" == 000 ]] && ok "unknown host on :80 dropped" || bad "unknown host :80 -> $rc"
curl -sk --resolve evil.example:443:127.0.0.1 https://evil.example/index.html -o /tmp/body; rc=$?
[[ $rc -ne 0 ]] && ok "unknown host on :443 dropped (curl rc=$rc)" || bad "unknown host :443 served: $(cat /tmp/body)"
body=$(curl -sk --resolve generic.test:443:127.0.0.1 https://generic.test/index.html)
[[ "$body" == ok ]] && ok "known TLS host still served" || bad "known TLS host -> '$body'"

echo "failures=${fails}"
exit "$fails"

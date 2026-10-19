#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Long-running service sites (profile node): site add allocates a port, site
# deploy builds as the site user, runs simai-app-<project>.service behind
# nginx, keeps shared paths, rolls back on a failed health check.
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
D=svc.test; P=/home/simai/www/$D
page() { curl -s --max-time 5 -H "Host: $D" "http://127.0.0.1${1:-/}"; }

apt-get remove -y -qq tree >/dev/null 2>&1
if ! command -v node >/dev/null 2>&1; then
  apt-get install -y -qq nodejs npm >/dev/null 2>&1 || { echo "FAIL nodejs install"; exit 1; }
fi

# A minimal service: answers with its release label, writes into a shared
# cache, and fails its health check when BROKEN exists in the release.
mk_app() {  # $1 label, $2 extra
  local dir=/root/node-$1
  rm -rf "$dir"; mkdir -p "$dir/.simai" "$dir/cache"
  cat >"$dir/server.js" <<JS
const http = require('http'), fs = require('fs');
const broken = fs.existsSync(__dirname + '/BROKEN');
fs.appendFileSync(__dirname + '/cache/starts.log', '$1\n');
http.createServer((q, r) => {
  if (q.url === '/health') { r.statusCode = broken ? 500 : 200; return r.end('ok'); }
  if (q.url === '/proto') return r.end(String(q.headers['x-forwarded-proto']));
  if (q.url === '/env') return r.end([process.env.PORT, process.env.HOST, process.env.GREETING, process.getuid()].join(' '));
  r.end('release-$1');
}).listen(process.env.PORT, process.env.HOST);
JS
  printf '{"name":"svc","version":"1.0.0","private":true}\n' >"$dir/package.json"
  printf '{"name":"svc","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"svc","version":"1.0.0"}}}\n' >"$dir/package-lock.json"
  printf '' >"$dir/requirements.txt"
  printf 'GREETING=from-example\nPORT=9999\n' >"$dir/.env.example"
  cat >"$dir/.simai/app.json" <<'JSON'
{"schema": "simai-app/1", "profile": "node",
 "node": {"version": "18", "start": "node server.js"},
 "python": {"requirements": "requirements.txt"},
 "packages": ["tree"],
 "shared": ["cache"], "health": {"path": "/health", "timeout": 30}}
JSON
  [[ "${2:-}" == broken ]] && touch "$dir/BROKEN"
  return 0
}

cli profile enable --id node --confirm yes >/dev/null 2>&1
cli site add --domain $D --profile node --confirm yes >/tmp/n-add 2>&1 && ok "site add --profile node" || { bad "site add"; tail -15 /tmp/n-add; }
port=$(sed -n 's/^APP_PORT=//p' /etc/simai-env/sites/$D/service.env)
[[ "$port" =~ ^3[0-9]{3}$ ]] && ok "port ${port} allocated" || bad "port: ${port}"
grep -q "proxy_pass http://127.0.0.1:${port};" /etc/nginx/sites-available/$D.conf && nginx -t >/dev/null 2>&1 && ok "nginx proxies to the port" || bad "nginx config"
[[ ! -e /etc/php ]] || ! ls /etc/php/*/fpm/pool.d/svc-test.conf >/dev/null 2>&1 && ok "no PHP pool for a node site" || bad "php pool created"

mk_app v1
cli site deploy --domain $D --from /root/node-v1 >/tmp/n-plan 2>&1
grep -q 'simai-app-svc-test.service' /tmp/n-plan && [[ ! -d $P/releases ]] && ok "deploy shows the service plan" || { bad "plan"; cat /tmp/n-plan; }
cli site deploy --domain $D --from /root/node-v1 --confirm yes >/tmp/n-d1 2>&1 && ok "deploy v1" || { bad "deploy v1"; tail -20 /tmp/n-d1; journalctl -u simai-app-svc-test -n 20 --no-pager; }
[[ "$(page)" == release-v1 ]] && ok "nginx serves the service" || bad "page: $(page)"
read -r e_port e_host e_greet e_uid <<<"$(page /env)"
[[ "$e_port" == "$port" && "$e_host" == 127.0.0.1 ]] && ok "PORT/HOST are managed (example PORT ignored)" || bad "env: $(page /env)"
[[ "$e_greet" == from-example ]] && ok ".env seeded from .env.example" || bad "greeting ${e_greet}"
[[ "$e_uid" != 0 && "$(id -un "$e_uid")" == "$(stat -c %U $P/current/)" ]] && ok "service runs as the site user ($(id -un "$e_uid"))" || bad "uid ${e_uid}"
[[ "$(stat -c '%U %a' $P/.env)" == "root 640" ]] && ok ".env root-owned 0640" || bad ".env perms $(stat -c '%U %a' $P/.env)"
[[ -L $P/current/cache && -d $P/shared/cache ]] && ok "cache is shared" || bad "shared cache"
[[ -x $P/current/.venv/bin/python ]] && ok "python venv built" || bad "no venv"
initial=("$P"/releases/*-initial)
[[ -d $P/public && -d "${initial[0]}" && ! -e "${initial[0]}/public" ]] && ok "public/ stays outside releases for ACME" || bad "public moved"
systemctl is-enabled --quiet simai-app-svc-test && ok "service enabled for reboot" || bad "not enabled"
command -v tree >/dev/null && ok "deploy installed the packages the manifest declares" || bad "manifest package not installed"
grep -q '^git .*@ ' /etc/simai-env/sites/$D/deploy.env 2>/dev/null || grep -q '^SOURCE=dir /root/node-v1$' /etc/simai-env/sites/$D/deploy.env && ok "deploy source recorded on one line" || bad "source: $(grep SOURCE /etc/simai-env/sites/$D/deploy.env)"

mk_app v2
cli site deploy --domain $D --from /root/node-v2 --confirm yes >/tmp/n-d2 2>&1 && [[ "$(page)" == release-v2 ]] && ok "deploy v2" || { bad "deploy v2"; tail -10 /tmp/n-d2; }
grep -q v1 $P/shared/cache/starts.log && grep -q v2 $P/shared/cache/starts.log && ok "shared cache survives releases" || bad "cache lost"

mk_app v3 broken
if cli site deploy --domain $D --from /root/node-v3 --confirm yes >/tmp/n-d3 2>&1; then bad "broken release reported success"; else ok "broken release fails its health check"; fi
[[ "$(page)" == release-v2 ]] && ok "previous release keeps serving" || bad "after failed deploy: $(page)"

cli site deploy-rollback --domain $D --confirm yes >/tmp/n-rb 2>&1 && [[ "$(page)" == release-v1 ]] && ok "rollback to v1" || { bad "rollback"; tail -8 /tmp/n-rb; }
cli site service-restart --domain $D --confirm yes >/tmp/n-rs 2>&1 && [[ "$(page)" == release-v1 ]] && ok "service-restart with health check" || { bad "service-restart"; tail -5 /tmp/n-rs; }
pid=$(systemctl show -p MainPID --value simai-app-svc-test); kill -9 "$pid" 2>/dev/null
for _ in {1..20}; do [[ "$(page)" == release-v1 ]] && break; sleep 1; done
[[ "$(page)" == release-v1 ]] && ok "systemd restarts a crashed service" || bad "no restart after crash"

cli site describe --domain $D >/tmp/n-desc.json 2>/dev/null
python3 - "$port" <<'PY' && ok "describe reports the service" || bad "describe service"
import json, sys
d = json.load(open("/tmp/n-desc.json"))
s = d["service"]
assert s["unit"] == "simai-app-svc-test.service" and s["port"] == int(sys.argv[1]) and s["state"] == "active", s
assert d["manifest"]["start"] == "node server.js" and d["manifest"]["shared"] == ["cache"], d["manifest"]
assert "service_logs" in d["how_to"], d["how_to"]
PY

# TLS on a node site: ssl install re-renders the node template with its port.
C=/root/svc-tls; rm -rf $C; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Test CA" -keyout $C/ca.key -out $C/ca.pem >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=$D" -keyout $C/key.pem -out $C/leaf.csr >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "$D" >$C/ext
openssl x509 -req -in $C/leaf.csr -CA $C/ca.pem -CAkey $C/ca.key -CAcreateserial -days 2 -extfile $C/ext -out $C/leaf.pem >/dev/null 2>&1
cat $C/leaf.pem $C/ca.pem >$C/fullchain.pem
cli ssl install --domain $D --cert $C/fullchain.pem --key $C/key.pem --chain $C/ca.pem --redirect yes --confirm yes >/tmp/n-ssl 2>&1 \
  && ok "ssl install on a node site" || { bad "ssl install"; grep -iE "error|warn" /tmp/n-ssl | head -5; }
[[ $(grep -c 'BEGIN CERTIFICATE' /etc/nginx/ssl/$D/fullchain.pem 2>/dev/null) -eq 2 ]] && ok "fullchain plus --chain is not duplicated" || bad "bundle has $(grep -c 'BEGIN CERTIFICATE' /etc/nginx/ssl/$D/fullchain.pem 2>/dev/null) certificates"
grep -q "proxy_pass http://127.0.0.1:${port};" /etc/nginx/sites-available/$D.conf && ok "proxy port kept after the SSL re-render" || bad "proxy lost"
[[ "$(curl -s --max-time 5 --cacert $C/ca.pem --resolve $D:443:127.0.0.1 https://$D/health)" == ok ]] && ok "HTTPS reaches the service" || bad "https health"
[[ "$(curl -s --max-time 5 --cacert $C/ca.pem --resolve $D:443:127.0.0.1 https://$D/proto)" == https ]] && ok "service sees X-Forwarded-Proto https" || bad "proto $(curl -s --cacert $C/ca.pem --resolve $D:443:127.0.0.1 https://$D/proto)"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $D" http://127.0.0.1/health)" == 301 ]] && ok "HTTP redirects to HTTPS" || bad "no redirect"

cli site remove --domain $D --remove-files yes --confirm yes >/tmp/n-rm 2>&1 && ok "site remove" || { bad "site remove"; grep -iE "warn|error" /tmp/n-rm | head -10; ls -la $P 2>&1 | head; }
[[ ! -f /etc/systemd/system/simai-app-svc-test.service && ! -f /etc/simai-env/sites/$D/service.env ]] && ok "service unit and port record removed" || bad "leftovers"
echo "failures=$fails"; exit $fails

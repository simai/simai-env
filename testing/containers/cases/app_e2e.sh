#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Node sites with a static root (profile node + "static"): nginx serves the
# release, routes /api/ to the service and applies per-path header sets, cache
# rules, deny patterns and a release header, all from .simai/app.json.
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
command -v npm >/dev/null 2>&1 || apt-get install -y -qq nodejs npm >/dev/null 2>&1
D=play.test; P=/home/simai/www/$D
hdr() { curl -s -D - -o /dev/null --max-time 5 -H "Host: $D" "${@:2}" "http://127.0.0.1$1" | tr -d '\r'; }
get() { curl -s --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
h() { hdr "$1" | sed -n "s/^$2: //Ip" | head -1; }

mk_app() {  # $1 label, $2 variant
  local dir=/root/app-$1
  rm -rf "$dir"; mkdir -p "$dir/.simai" "$dir/public/runner/assets" "$dir/public/simai/fonts"
  echo "home-$1" >"$dir/public/index.html"
  echo "runner-$1" >"$dir/public/runner/index.html"
  head -c 3000 /dev/zero | tr '\0' 'x' | sed 's/^/var a=1;/' >"$dir/public/runner/assets/app-abcdef1234.js"
  echo "a{}" >"$dir/public/simai/x.css"; echo "font" >"$dir/public/simai/fonts/f.ttf"
  echo "embed-$1" >"$dir/public/embed.html"; echo '{}' >"$dir/public/package.json"
  cat >"$dir/server.js" <<'JS'
const http = require('http');
http.createServer((q, r) => {
  if (q.url === '/api/ping') { r.setHeader('content-type', 'application/json'); return r.end(JSON.stringify({port: process.env.API_PORT, host: process.env.API_HOST, examples: process.env.EXAMPLES_DIR})); }
  r.statusCode = 404; r.end('no');
}).listen(process.env.API_PORT, process.env.API_HOST);
JS
  printf '{"name":"app","version":"1.0.0","private":true}\n' >"$dir/package.json"
  local bad_header=""
  [[ "${2:-}" == badroutes ]] && bad_header=', "Set-Cookie": "x=1"'
  cat >"$dir/.simai/app.json" <<JSON
{"schema": "simai-app/1", "profile": "node",
 "node": {"version": "18", "start": "node server.js", "install": "none"},
 "port_env": ["API_PORT"], "host_env": ["API_HOST"],
 "env": {"EXAMPLES_DIR": "{state}/examples", "API_PORT": "1"},
 "static": {"root": "public", "fallback": "/index.html"},
 "routes": [{"path": "/api/", "to": "service"}],
 "headers": {
   "page": {"Content-Security-Policy": "default-src 'self'", "X-Frame-Options": "SAMEORIGIN"${bad_header}},
   "runner": {"Content-Security-Policy": "default-src 'self'; frame-ancestors *"},
   "embed": {"Content-Security-Policy": "frame-ancestors *"}
 },
 "page": {"headers": ["page"], "cache": "no-cache"},
 "locations": [
   {"path": "/simai/fonts/", "headers": ["page"], "cors": true, "default_type": "font/ttf", "cache": "framework"},
   {"path": "/simai/", "headers": ["page"], "cors": true, "cache": "framework"},
   {"path": "/runner/", "headers": ["runner"], "cache": "runner", "try": "dir"},
   {"path": "/embed.html", "exact": true, "headers": ["embed"], "cache": "no-cache"}
 ],
 "cache": {
   "framework": {"arg": "sf_v", "values": ["v1"], "value": "public, max-age=31536000, immutable", "default": "no-cache"},
   "runner": {"uri": "^/runner/assets/.+-[A-Za-z0-9_-]{8,}\\\\.js\$", "value": "public, max-age=31536000, immutable", "default": "no-cache"}
 },
 "deny": ["^/(?:\\\\.env|package\\\\.json\$)"],
 "release_header": "X-App-Release",
 "health": {"path": "/api/ping", "timeout": 30}}
JSON
  return 0
}

cli profile enable --id node --confirm yes >/dev/null 2>&1
SIMAI_SITE_ISOLATION=no cli site add --domain $D --profile node --confirm yes >/tmp/a-add 2>&1 && ok "site add" || { bad "site add"; tail -8 /tmp/a-add; }
port=$(sed -n 's/^APP_PORT=//p' /etc/simai-env/sites/$D/service.env)
grep -q 'include /etc/nginx/simai-app/play.test/routes.conf;' /etc/nginx/sites-available/$D.conf && [[ -f /etc/nginx/simai-app/$D/routes.conf ]] && ok "node template includes generated routes" || bad "no routes include"
mk_app v1
cli site deploy --domain $D --from /root/app-v1 --confirm yes >/tmp/a-d1 2>&1 && ok "deploy v1" || { bad "deploy v1"; tail -15 /tmp/a-d1; }
rel1=$(basename "$(readlink $P/current)")
[[ "$(get /)" == home-v1 ]] && ok "static root served by nginx" || bad "home: $(get /)"
[[ "$(get /deep/link)" == home-v1 ]] && ok "SPA fallback to /index.html" || bad "fallback: $(get /deep/link)"
api=$(get /api/ping)
python3 - "$api" "$port" "$P" <<'PY' && ok "/api/ goes to the service with API_PORT/API_HOST and {state}" || bad "api: $api"
import json, sys
d = json.loads(sys.argv[1])
assert d["port"] == sys.argv[2] and d["host"] == "127.0.0.1" and d["examples"] == sys.argv[3] + "/shared/state/examples", d
PY
[[ "$(h / Content-Security-Policy)" == "default-src 'self'" && "$(h / X-Frame-Options)" == SAMEORIGIN ]] && ok "page header set" || bad "page headers"
[[ "$(h / X-Content-Type-Options)" == nosniff && "$(h /runner/ X-Content-Type-Options)" == nosniff ]] && ok "nosniff on every location" || bad "nosniff"
[[ "$(get /runner/)" == runner-v1 && "$(h /runner/ Content-Security-Policy)" == "default-src 'self'; frame-ancestors *" ]] && ok "runner header set and directory index" || bad "runner: $(get /runner/) $(h /runner/ Content-Security-Policy)"
[[ "$(h /runner/assets/app-abcdef1234.js Cache-Control)" == "public, max-age=31536000, immutable" ]] && ok "uri cache rule" || bad "runner cache: $(h /runner/assets/app-abcdef1234.js Cache-Control)"
[[ "$(h /runner/index.html Cache-Control)" == no-cache ]] && ok "uri rule default" || bad "runner default cache"
[[ "$(h '/simai/x.css?sf_v=v1' Cache-Control)" == "public, max-age=31536000, immutable" && "$(h '/simai/x.css?sf_v=v9' Cache-Control)" == no-cache ]] && ok "query-argument cache rule" || bad "sf_v cache"
[[ "$(h /simai/x.css Access-Control-Allow-Origin)" == '*' && "$(h /simai/x.css Cross-Origin-Resource-Policy)" == cross-origin ]] && ok "CORS and CORP pair" || bad "cors"
[[ "$(h /simai/fonts/f.ttf Content-Type)" == font/ttf* ]] && ok "default_type per location" || bad "font type: $(h /simai/fonts/f.ttf Content-Type)"
[[ "$(get /embed.html)" == embed-v1 && "$(h /embed.html Content-Security-Policy)" == "frame-ancestors *" ]] && ok "exact location" || bad "embed"
[[ "$(h / X-App-Release)" == "$rel1" ]] && ok "release header names the release" || bad "release header: $(h / X-App-Release)"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $D" http://127.0.0.1/package.json)" == 404 ]] && ok "deny pattern" || bad "deny"
hdr /runner/assets/app-abcdef1234.js -H 'Accept-Encoding: gzip' | grep -qi '^Content-Encoding: gzip' && ok "gzip" || bad "gzip"
grep -q '^API_PORT='"$port"'$' $P/.env && [[ $(grep -c '^API_PORT=' $P/.env) -eq 1 ]] && ok "port_env overrides the manifest value" || bad "API_PORT in .env"

mk_app v2
cli site deploy --domain $D --from /root/app-v2 --confirm yes >/tmp/a-d2 2>&1 && [[ "$(get /)" == home-v2 ]] && ok "deploy v2" || { bad "deploy v2"; tail -8 /tmp/a-d2; }
rel2=$(basename "$(readlink $P/current)")
for _ in {1..10}; do [[ "$(h / X-App-Release)" == "$rel2" ]] && break; sleep 0.5; done
[[ "$(h / X-App-Release)" == "$rel2" ]] && ok "routes follow the release" || bad "release header after v2: $(h / X-App-Release)"
mk_app v3 badroutes
cli site deploy --domain $D --from /root/app-v3 --confirm yes >/tmp/a-d3 2>&1 && bad "disallowed header accepted" || { grep -q "is not allowed" /tmp/a-d3 && ok "disallowed header refused" || { bad "bad routes message"; tail -5 /tmp/a-d3; }; }
[[ "$(get /)" == home-v2 && "$(h / X-App-Release)" == "$rel2" ]] && ok "previous release and routes keep serving" || bad "after bad routes: $(get /)"

C=/root/tls; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain $D --cert $C/cert.pem --key $C/key.pem --confirm yes >/tmp/a-ssl 2>&1 || { bad "ssl install"; tail -5 /tmp/a-ssl; }
for _ in {1..20}; do [[ "$(curl -sk --resolve $D:443:127.0.0.1 https://$D/runner/)" == runner-v2 ]] && break; sleep 0.5; done
[[ "$(curl -sk --resolve $D:443:127.0.0.1 https://$D/runner/)" == runner-v2 ]] && [[ "$(curl -sk --resolve $D:443:127.0.0.1 https://$D/api/ping | python3 -c 'import json,sys; print(json.load(sys.stdin)["host"])')" == 127.0.0.1 ]] && ok "routes kept after ssl install" || bad "https routes"

cli site remove --domain $D --remove-files yes --confirm yes >/dev/null 2>&1
[[ ! -e /etc/nginx/simai-app/$D && ! -e /etc/nginx/conf.d/simai-app-play-test.conf ]] && nginx -t >/dev/null 2>&1 && ok "site remove clears generated routes" || bad "routes left behind"
echo "failures=$fails"; exit $fails

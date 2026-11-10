#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# site set-profile: a deployed static site becomes a node site (static root
# plus a service at /api/) without losing its releases, keeps serving its
# static release until the first node release, rolls back on failure, and
# switches back to static.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
D=fx.test; P=/home/simai/www/$D; CFG=/etc/nginx/sites-available/$D.conf; SVC=/etc/simai-env/sites/$D/service.env
get() { curl -s --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
hdr() { curl -s -D - -o /dev/null --max-time 5 -H "Host: $D" "${@:2}" "http://127.0.0.1$1" | tr -d '\r'; }
sget() { curl -sk --max-time 5 --resolve "$D:443:127.0.0.1" "https://$D$1"; }
wait_get() { local _; for _ in {1..40}; do [[ "$(get "$1")" == "$2" ]] && return 0; sleep 0.25; done; return 1; }
# Answers of the static pages, compared before and after each switch.
pages() { printf '%s|%s|%s|%s|%s|%s\n' "$(get /)" "$(get /dir/)" "$(get /page)" "$(code /dir)" "$(code /missing):$(get /missing)" "$(get /200-only)"; }
tree_sum() { (cd "$P/releases" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum; find . -printf '%U:%G %m %p\n' | sort | sha256sum) | tr '\n' ' '; }

if ! command -v npm >/dev/null 2>&1; then
  apt-get install -y -qq nodejs npm >/dev/null 2>&1 || { echo "FAIL nodejs install"; exit 1; }
fi

# A static artifact as CI builds it (GitHub Pages layout).
mk_static() {
  local dir=/root/fx-static
  rm -rf "$dir"; mkdir -p "$dir/dir" "$dir/.simai" "$dir/fonts"
  echo home >"$dir/index.html"; echo dir >"$dir/dir/index.html"; echo page >"$dir/page.html"
  echo not-found >"$dir/404.html"; echo font >"$dir/fonts/icons.0123456789abcdef.woff2"
  printf '{"schema": "simai-app/1", "profile": "static"}\n' >"$dir/.simai/app.json"
  tar -C "$dir" -czf /root/fx-static.tgz .
}

# A node release with a static root and a service at /api/ (ui-effects shape).
mk_node() {  # $1 label, $2 broken
  local dir=/root/fx-node-$1
  rm -rf "$dir"; mkdir -p "$dir/.simai" "$dir/public" "$dir/state"
  echo "node-home-$1" >"$dir/public/index.html"
  cat >"$dir/server.js" <<JS
const http = require('http'), fs = require('fs');
const broken = fs.existsSync(__dirname + '/BROKEN');
http.createServer((q, r) => {
  if (q.url === '/api/health') { r.statusCode = broken ? 500 : 200; return r.end('ok'); }
  if (q.url === '/api/vote') { fs.appendFileSync(__dirname + '/state/votes', '$1\n'); return r.end('voted'); }
  r.end('api-$1');
}).listen(process.env.PORT, process.env.HOST);
JS
  printf '{"name":"fx","version":"1.0.0","private":true}\n' >"$dir/package.json"
  printf '{"name":"fx","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fx","version":"1.0.0"}}}\n' >"$dir/package-lock.json"
  cat >"$dir/.simai/app.json" <<'JSON'
{"schema": "simai-app/1", "profile": "node",
 "node": {"version": "18", "start": "node server.js", "install": "none"},
 "static": {"root": "public", "fallback": "404"},
 "routes": [{"path": "/api/", "to": "service"}],
 "shared": ["state"], "health": {"path": "/api/health", "timeout": 30}}
JSON
  [[ "${2:-}" == broken ]] && touch "$dir/BROKEN"
  return 0
}

cli profile enable --id node --confirm yes >/dev/null 2>&1

# The plan of site add already refuses a disabled profile and names the fix
# (the panel gateway asks for plans before confirming); enabled, it plans.
cli profile disable --id bitrix --confirm yes >/dev/null 2>&1
cli site add --domain plan.test --profile bitrix >/tmp/p-dis 2>&1 && bad "plan with a disabled profile succeeded" \
  || { grep -q 'profile enable --id bitrix' /tmp/p-dis && ! grep -q 'No handler was executed' /tmp/p-dis \
    && ok "plan of site add refuses a disabled profile" || { bad "disabled plan"; cat /tmp/p-dis; }; }
cli site add --domain plan.test --profile bitrix --output json >/tmp/p-dis.json 2>/dev/null && bad "json plan with a disabled profile succeeded" \
  || { python3 -c 'import json,sys; d=json.load(open("/tmp/p-dis.json")); sys.exit(d["status"] != "failed")' \
    && ok "json plan of site add fails for a disabled profile" || { bad "json disabled plan"; cat /tmp/p-dis.json; }; }
cli profile enable --id bitrix --confirm yes >/dev/null 2>&1
cli site add --domain plan.test --profile bitrix >/tmp/p-en 2>&1 && grep -q 'No handler was executed' /tmp/p-en \
  && [[ ! -e /etc/nginx/sites-available/plan.test.conf ]] && ok "plan of site add succeeds once the profile is enabled" || { bad "enabled plan"; cat /tmp/p-en; }
cli site add --domain $D --profile static --confirm yes >/tmp/p-add 2>&1 || { bad "site add static"; tail -10 /tmp/p-add; }
cli site add --domain other.test --profile static --confirm yes >/tmp/p-other 2>&1 || { bad "second site"; tail -5 /tmp/p-other; }
mk_static
cli site deploy --domain $D --archive /root/fx-static.tgz --confirm yes >/tmp/p-d0 2>&1 || { bad "static deploy"; tail -10 /tmp/p-d0; }
cli site redirect-add --domain $D --from /old --to /page --code 301 --confirm yes >/dev/null 2>&1 || bad "redirect-add"
C=/root/fx-tls; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain $D --cert $C/cert.pem --key $C/key.pem --redirect no --confirm yes >/tmp/p-ssl 2>&1 || { bad "ssl install"; tail -5 /tmp/p-ssl; }
static_release=$(basename "$(readlink $P/current)")
cert_line=$(grep -E "^[[:space:]]*ssl_certificate[[:space:]]" $CFG)
before=$(pages); sums=$(tree_sum); other_sum=$(sha256sum /etc/nginx/sites-available/other.test.conf)
[[ "$before" == "home|dir|page|301|404:not-found|not-found" ]] && ok "static site serves before the switch" || bad "before: $before"

# Plan only: nothing changes.
cfg_sum=$(sha256sum $CFG)
cli site set-profile --domain $D --profile node >/tmp/p-plan 2>&1
grep -q 'profile static -> node' /tmp/p-plan && grep -q 'STATIC_RELEASES=yes' /tmp/p-plan && grep -q 'HTTPS kept' /tmp/p-plan \
  && [[ "$(sha256sum $CFG)" == "$cfg_sum" && ! -e $SVC && -L $P/public ]] && ok "plan without --confirm changes nothing" || { bad "plan"; cat /tmp/p-plan; }

# A port that is taken is refused.
python3 -m http.server 3170 --bind 127.0.0.1 >/dev/null 2>&1 & busy=$!
for _ in {1..20}; do ss -ltn | grep -q ':3170 ' && break; sleep 0.25; done
cli site set-profile --domain $D --profile node --app-port 3170 --confirm yes >/tmp/p-busy 2>&1 && bad "busy port accepted" \
  || { grep -q 'already used' /tmp/p-busy && [[ "$(sha256sum $CFG)" == "$cfg_sum" && ! -e $SVC ]] && ok "busy port refused, nothing changed" || { bad "busy port"; tail -5 /tmp/p-busy; }; }
kill $busy 2>/dev/null

# nginx rejects the result: everything returns as it was.
echo 'this is not nginx;' >/etc/nginx/conf.d/zz-broken.conf
cli site set-profile --domain $D --profile node --confirm yes >/tmp/p-fail 2>&1 && bad "switch with broken nginx reported success" || ok "switch fails when nginx -t fails"
rm -f /etc/nginx/conf.d/zz-broken.conf
[[ "$(sha256sum $CFG)" == "$cfg_sum" && ! -e $SVC && ! -e /etc/nginx/simai-app/$D/routes.conf && -L $P/public && "$(readlink $P/public)" == current ]] \
  && ok "failed switch restores config, symlink and port record" || { bad "rollback state"; ls -la $P; ls /etc/simai-env/sites/$D; }
grep -q 'Restoring the previous configuration' /tmp/p-fail && ok "failure is reported with the restore" || bad "failure message: $(tail -3 /tmp/p-fail)"
[[ "$(pages)" == "$before" ]] && ok "site keeps serving after the failed switch" || bad "after failure: $(pages)"

# The switch.
cli site set-profile --domain $D --profile node --confirm yes >/tmp/p-sw 2>&1 && ok "set-profile static -> node" || { bad "switch"; tail -15 /tmp/p-sw; }
port=$(sed -n 's/^APP_PORT=//p' $SVC)
[[ "$port" =~ ^3[0-9]{3}$ ]] && grep -qx 'STATIC_RELEASES=yes' $SVC && ok "port ${port} recorded" || bad "service.env: $(cat $SVC)"
grep -q '^# simai-profile: node' $CFG && grep -q '^# simai-nginx-template: node' $CFG && grep -q "include /etc/nginx/simai-app/$D/routes.conf;" $CFG \
  && ok "vhost from the node template with node metadata" || { bad "metadata"; grep '^# simai-' $CFG; }
[[ -d $P/public && ! -L $P/public && "$(basename "$(readlink $P/current)")" == "$static_release" ]] && ok "public is a directory, current unchanged" || bad "layout: $(ls -la $P)"
[[ "$(tree_sum)" == "$sums" ]] && ok "every release file, owner and mode unchanged" || bad "release files changed"
wait_get / home
[[ "$(pages)" == "$before" ]] && ok "static pages answer the same through the node vhost" || bad "after switch: $(pages) (want $before)"
hdr / | grep -qi '^Cache-Control: no-cache' && hdr /page | grep -qi '^Content-Type: text/html; charset=utf-8' && ok "static caching and charset kept" || bad "headers: $(hdr /)"
hdr /fonts/icons.0123456789abcdef.woff2 | grep -qi '^Access-Control-Allow-Origin: \*' && ok "fonts keep CORS" || bad "font: $(hdr /fonts/icons.0123456789abcdef.woff2)"
[[ "$(code /old)" == 301 ]] && ok "path redirect kept" || bad "redirect: $(code /old)"
[[ "$(sget /page)" == page ]] && [[ -n "$cert_line" && "$(grep -E "^[[:space:]]*ssl_certificate[[:space:]]" $CFG)" == "$cert_line" ]] && ok "HTTPS kept with the same certificate" || bad "https: $(sget /page)"
[[ "$(code /.simai/app.json)" =~ ^40[34]$ ]] && ok "manifest not served" || bad "manifest served"
mkdir -p $P/public/.well-known/acme-challenge && echo tok >$P/public/.well-known/acme-challenge/t
[[ "$(get /.well-known/acme-challenge/t)" == tok ]] && ok "ACME challenges come from public/" || bad "acme: $(code /.well-known/acme-challenge/t)"
rm -rf $P/public/.well-known
nginx -t >/dev/null 2>&1 && [[ "$(sha256sum /etc/nginx/sites-available/other.test.conf)" == "$other_sum" ]] && ok "nginx -t passes, other site untouched" || bad "nginx or other site"
! systemctl cat simai-app-fx-test.service >/dev/null 2>&1 && ok "no service before the first node release" || bad "service unit created early"
cli site describe --domain $D >/tmp/p-desc.json 2>/dev/null
python3 - "$port" <<'PY' && ok "describe shows profile node and the port" || bad "describe"
import json, sys
d = json.load(open("/tmp/p-desc.json"))
assert d["profile"] == "node", d["profile"]
assert d["service"]["port"] == int(sys.argv[1]), d["service"]
PY
cli site set-profile --domain $D --profile node --confirm yes 2>&1 | grep -q 'already has profile node' && ok "second run is a no-op" || bad "not idempotent"

# First node release: static root from the release, /api/ to the service.
mk_node v1
cli site deploy --domain $D --from /root/fx-node-v1 --confirm yes >/tmp/p-n1 2>&1 && ok "first node release deploys" || { bad "node deploy"; tail -15 /tmp/p-n1; journalctl -u simai-app-fx-test -n 20 --no-pager; }
node_release=$(basename "$(readlink $P/current)")
wait_get / node-home-v1
[[ "$(get /)" == node-home-v1 && "$(get /api/health)" == ok ]] && ok "release public/ and /api/ served" || bad "node site: $(get /) $(get /api/health)"
[[ "$(get /api/vote)" == voted && -s $P/shared/state/votes && -L $P/current/state ]] && ok "votes land in shared/state" || bad "state: $(ls -la $P/shared $P/current/state)"
cli backup data --domain $D --db no --confirm yes >/tmp/p-bk 2>&1 || { bad "backup data"; tail -5 /tmp/p-bk; }
bk=$(find /var/backups/simai/$D -name files.tar.gz | sort | tail -n1)
[[ -n "$bk" ]] && tar -tzf "$bk" | grep -qx './shared/state/votes' && ok "file backup holds shared/state" || bad "backup content: $(tar -tzf "$bk" 2>/dev/null | grep shared | head)"

# A broken node release returns to the working one.
mk_node v2 broken
cli site deploy --domain $D --from /root/fx-node-v2 --confirm yes >/tmp/p-n2 2>&1 && bad "broken release accepted" || ok "broken node release refused"
[[ "$(get /)" == node-home-v1 && "$(get /api/health)" == ok ]] && ok "previous node release keeps serving" || bad "after broken: $(get /)"

# Back to the static release (code only), then back to profile static.
cli site deploy-rollback --domain $D --release "$static_release" --confirm yes >/tmp/p-rb 2>&1 && ok "rollback to the static release" || { bad "rollback"; tail -8 /tmp/p-rb; }
wait_get / home
[[ "$(pages)" == "$before" ]] && ok "static release served again on the node site" || bad "after rollback: $(pages)"
! systemctl is-active --quiet simai-app-fx-test && ok "service stopped for the static release" || bad "service still running"
cli site deploy-rollback --domain $D --release "$node_release" --confirm yes >/tmp/p-rf 2>&1 && wait_get / node-home-v1 && [[ "$(get /api/health)" == ok ]] \
  && ok "rollback forward to the node release" || { bad "forward rollback"; tail -8 /tmp/p-rf; }
cli site set-profile --domain $D --profile static --confirm yes >/tmp/p-back0 2>&1 && bad "back to static with a running service" \
  || { grep -q 'runs a service' /tmp/p-back0 && ok "back to static refused while current runs a service" || bad "refusal: $(tail -3 /tmp/p-back0)"; }
cli site deploy-rollback --domain $D --release "$static_release" --confirm yes >/dev/null 2>&1
cli site set-profile --domain $D --profile static --confirm yes >/tmp/p-back 2>&1 && ok "set-profile node -> static" || { bad "back"; tail -10 /tmp/p-back; }
grep -q '^# simai-profile: static' $CFG && [[ -L $P/public && "$(readlink $P/public)" == current && ! -e $SVC && ! -e /etc/nginx/simai-app/$D/routes.conf && ! -e /etc/systemd/system/simai-app-fx-test.service ]] \
  && ok "static layout restored, port and service removed" || { bad "back layout"; ls -la $P; ls /etc/simai-env/sites/$D; }
wait_get / home
[[ "$(pages)" == "$before" && "$(sget /page)" == page && "$(code /old)" == 301 ]] && ok "static pages, HTTPS and redirects after switching back" || bad "after back: $(pages)"
[[ -d "$P/releases/$node_release" && -d $P/shared/state ]] && ok "node release and shared state kept" || bad "kept data"
nginx -t >/dev/null 2>&1 && ok "nginx -t passes at the end" || bad "nginx -t"

cli site remove --domain $D --remove-files yes --confirm yes >/dev/null 2>&1
cli site remove --domain other.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=$fails"; exit $fails

#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Static sites deployed from CI artifacts (GitHub Pages behaviour), path and
# domain redirects, and per-site CI deploy keys over real SSH.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
D=pages.test; P=/home/simai/www/$D
get() { curl -s --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $D" "http://127.0.0.1$1"; }
# nginx reloads asynchronously: wait until a path answers the expected code.
wait_code() { local host="$1" path="$2" want="$3" _; for _ in {1..20}; do [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $host" "http://127.0.0.1$path")" == "$want" ]] && return 0; sleep 0.5; done; return 1; }
hdr() { curl -s -D - -o /dev/null --max-time 5 -H "Host: $D" "${@:2}" "http://127.0.0.1$1" | tr -d '\r'; }

mk_artifact() {  # $1 label, $2 extra
  local dir=/root/art-$1
  rm -rf "$dir"; mkdir -p "$dir/dir" "$dir/ok" "$dir/.simai"
  echo "home-$1" >"$dir/index.html"
  echo "dir-$1" >"$dir/dir/index.html"
  echo "page-$1" >"$dir/page.html"
  echo "not-found-$1" >"$dir/404.html"
  [[ "${2:-}" == broken ]] || echo "ok-$1" >"$dir/ok/index.html"
  head -c 4000 /dev/zero | tr '\0' 'a' | sed 's/^/body{}/' >"$dir/style.css"
  echo "pages.test" >"$dir/CNAME"; : >"$dir/.nojekyll"
  mkdir -p "$dir/_docara/vendor"; echo 'a{}' >"$dir/_docara/shell.0123456789abcdef.css"; echo 'b{}' >"$dir/_docara/plain.css"
  echo "MIT" >"$dir/_docara/vendor/LICENSE"
  printf '{"schema": "simai-app/1", "profile": "static", "health": {"path": "/ok/"}}\n' >"$dir/.simai/app.json"
  [[ "${2:-}" == escape ]] && ln -s ../../../../etc/passwd "$dir/leak.txt"
  tar -C "$dir" -czf "/root/art-$1.tgz" .
  sha256sum "/root/art-$1.tgz" | cut -d' ' -f1
}

cli site add --domain $D --profile static --confirm yes >/tmp/s-add 2>&1 && ok "site add static" || { bad "site add"; tail -10 /tmp/s-add; }
s1=$(mk_artifact v1)
cli site deploy --domain $D --archive /root/art-v1.tgz --sha256 "$s1" >/tmp/s-plan 2>&1
grep -q 'symlink to current' /tmp/s-plan && [[ ! -d $P/releases ]] && ok "deploy shows the static plan" || { bad "plan"; cat /tmp/s-plan; }
cli site deploy --domain $D --archive /root/art-v1.tgz --sha256 "$s1" --confirm yes >/tmp/s-d1 2>&1 && ok "deploy artifact v1" || { bad "deploy v1"; tail -15 /tmp/s-d1; }
[[ -L $P/public && "$(readlink $P/public)" == current && -L $P/current ]] && ok "public is a symlink to current" || bad "layout: $(ls -la $P)"
[[ "$(get /)" == home-v1 ]] && ok "serves the artifact" || bad "home: $(get /)"
[[ "$(code /dir)" == 301 && "$(hdr /dir | sed -n 's/^Location: //p')" == */dir/ ]] && ok "/dir redirects to /dir/" || bad "dir: $(code /dir)"
[[ "$(get /dir/)" == dir-v1 ]] && ok "/dir/ serves dir/index.html" || bad "dir index"
[[ "$(get /page)" == page-v1 ]] && ok "/page serves page.html" || bad "page: $(get /page)"
[[ "$(code /missing)" == 404 && "$(get /missing)" == not-found-v1 ]] && ok "404.html is the error page" || bad "404: $(code /missing) $(get /missing)"
hdr / | grep -qi '^Cache-Control: no-cache' && ok "HTML is revalidated" || bad "html cache: $(hdr / | grep -i cache)"
hdr /style.css | grep -qi '^Cache-Control: public, max-age=600$' && ok "plain assets revalidate after ten minutes" || bad "css cache: $(hdr /style.css | grep -i cache)"
hdr /_docara/shell.0123456789abcdef.css | grep -qi '^Cache-Control: public, max-age=31536000, immutable$' && ok "hashed assets are immutable" || bad "hashed cache: $(hdr /_docara/shell.0123456789abcdef.css | grep -i cache)"
[[ "$(code /_docara/plain.css)" == 200 ]] && ok "underscore directories are served" || bad "_docara: $(code /_docara/plain.css)"
hdr /_docara/vendor/LICENSE | grep -qi '^Content-Type: text/plain' && ok "extensionless files are text/plain" || bad "LICENSE type: $(hdr /_docara/vendor/LICENSE | grep -i content-type)"
[[ $(hdr /style.css | grep -ci '^Cache-Control:') -eq 1 ]] && ok "one Cache-Control header" || bad "duplicate Cache-Control"
hdr /style.css -H 'Accept-Encoding: gzip' | grep -qi '^Content-Encoding: gzip' && ok "text compressed with gzip" || bad "no gzip"
hdr / | grep -qi '^X-Content-Type-Options: nosniff' && ok "nosniff kept with the static settings" || bad "nosniff lost"
[[ "$(code /.simai/app.json)" =~ ^40[34]$ ]] && ok "manifest in the artifact is not served" || bad "manifest served"

s2=$(mk_artifact v2 broken)
cli site deploy --domain $D --archive /root/art-v2.tgz --sha256 "$s2" --confirm yes >/tmp/s-d2 2>&1 && { bad "broken release accepted"; grep -vE "^\s*$" /tmp/s-d2 | tail -12; } || ok "health path from the artifact rejects a broken release"
[[ "$(get /)" == home-v1 ]] && ok "previous release keeps serving" || bad "after failed deploy: $(get /)"
s3=$(mk_artifact v3 escape)
cli site deploy --domain $D --archive /root/art-v3.tgz --sha256 "$s3" --confirm yes >/tmp/s-d3 2>&1 && bad "escaping symlink accepted" || { grep -q 'symbolic link leaving the release' /tmp/s-d3 && ok "symlink leaving the release is refused" || { bad "escape message"; tail -3 /tmp/s-d3; }; }
cli site deploy --domain $D --archive /root/art-v1.tgz --sha256 "$s2" --confirm yes >/dev/null 2>&1 && bad "wrong sha256 accepted" || ok "wrong sha256 refused"

# Shared-account hosts (SIMAI_SITE_ISOLATION=no): nginx reads the release
# through www-data, not through a per-site group.
SIMAI_SITE_ISOLATION=no cli site add --domain shared-pages.test --profile static --confirm yes >/tmp/s-sh 2>&1 || { bad "shared site add"; tail -5 /tmp/s-sh; }
# Files private to their owner (as CI tarballs or a restrictive umask make
# them) must still reach nginx through the site's web group.
rm -rf /root/art-private && cp -a /root/art-v1 /root/art-private && chmod -R go-rwx /root/art-private
tar -C /root/art-private -czf /root/art-private.tgz . && sp=$(sha256sum /root/art-private.tgz | cut -d' ' -f1)
cli site deploy --domain shared-pages.test --archive /root/art-private.tgz --sha256 "$sp" --confirm yes >/tmp/s-shd 2>&1 || { bad "shared deploy"; tail -8 /tmp/s-shd; }
[[ "$(curl -s -H 'Host: shared-pages.test' http://127.0.0.1/dir/)" == dir-v1 ]] && ok "nested files of a shared-account site are readable by nginx" || bad "shared nested: $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: shared-pages.test' http://127.0.0.1/dir/)"
[[ "$(stat -c %U /home/simai/www/shared-pages.test/current/dir/index.html)" == simai ]] && ok "shared release owned by simai" || bad "shared owner"

# Path redirects survive a re-render of the nginx config (ssl install).
cli site redirect-add --domain $D --from / --to /ru/ --code 302 --confirm yes >/tmp/s-r 2>&1 && ok "redirect-add" || { bad "redirect-add"; tail -5 /tmp/s-r; }
wait_code $D / 302
[[ "$(code /)" == 302 && "$(hdr / | sed -n 's/^Location: //p')" == */ru/ ]] && ok "/ answers 302 to /ru/" || bad "redirect: $(code /)"
[[ "$(get /page)" == page-v1 ]] && ok "other paths are unchanged" || bad "page after redirect"
cli site redirect-add --domain $D --from /x --to '/y;return 200 hacked' --confirm yes >/dev/null 2>&1 && bad "unsafe target accepted" || ok "unsafe redirect target refused"
C=/root/tls; mkdir -p $C
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" -keyout $C/key.pem -out $C/cert.pem >/dev/null 2>&1
cli ssl install --domain $D --cert $C/cert.pem --key $C/key.pem --confirm yes >/tmp/s-ssl 2>&1 || { bad "ssl install"; tail -5 /tmp/s-ssl; }
[[ "$(curl -sk -o /dev/null -w '%{http_code}' --resolve $D:443:127.0.0.1 https://$D/)" == 302 ]] && ok "redirect kept after ssl install" || bad "redirect lost after re-render"
[[ "$(curl -sk --resolve $D:443:127.0.0.1 https://$D/missing)" == not-found-v1 ]] && ok "static behaviour kept over HTTPS" || bad "https 404"
cli site redirect-list --domain $D 2>&1 | grep -q '/ru/' && ok "redirect-list" || bad "redirect-list"

# Whole-domain redirect sites.
cli profile enable --id redirect --confirm yes >/dev/null 2>&1
cli site add --domain old.test --profile redirect --redirect-to https://new.test --redirect-code 301 --confirm yes >/tmp/s-old 2>&1 && ok "site add --profile redirect" || { bad "redirect site"; tail -8 /tmp/s-old; }
wait_code old.test /a 301
loc=$(curl -s -D - -o /dev/null -H "Host: old.test" "http://127.0.0.1/a/b?c=1" | tr -d '\r' | sed -n 's/^Location: //p')
[[ "$loc" == "https://new.test/a/b?c=1" ]] && ok "domain redirect keeps path and query" || bad "domain redirect: $loc"
mkdir -p /home/simai/www/old.test/public/.well-known/acme-challenge && echo tok >/home/simai/www/old.test/public/.well-known/acme-challenge/t
[[ "$(curl -s -H 'Host: old.test' http://127.0.0.1/.well-known/acme-challenge/t)" == tok ]] && ok "redirect site still answers ACME" || bad "acme on redirect site"
cli site add --domain bad.test --profile redirect --redirect-to 'https://new.test/$x' --confirm yes >/dev/null 2>&1 && bad "unsafe domain target accepted" || ok "unsafe domain redirect refused"

# CI deploy key over real SSH.
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
cli site redirect-remove --domain $D --from / --confirm yes >/dev/null 2>&1
wait_code $D / 200
ssh-keygen -q -t ed25519 -N '' -f /root/ci
cli site deploy-key-add --domain $D --pubkey-file /root/ci.pub --host 127.0.0.1 --confirm yes >/tmp/s-key 2>&1 && ok "deploy-key-add" || { bad "deploy-key-add"; tail -8 /tmp/s-key; }
sed -n '/SIMAI_DEPLOY_KNOWN_HOSTS/,$p' /tmp/s-key | grep '^127.0.0.1 ' >/root/ci_known_hosts
[[ -s /root/ci_known_hosts ]] && ok "known_hosts lines printed" || bad "no known_hosts"
ci() { ssh -i /root/ci -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/ci_known_hosts simai-deploy@127.0.0.1 "$@"; }
s4=$(mk_artifact v4)
ci "deploy-artifact $s4" </root/art-v4.tgz >/tmp/s-ci 2>&1 && [[ "$(get /)" == home-v4 ]] && ok "CI deploys an artifact through the gate" || { bad "ci deploy"; tail -10 /tmp/s-ci; }
ci status 2>&1 | grep -q 'current' && ok "gate status" || bad "gate status"
ci rollback >/dev/null 2>&1 && [[ "$(get /)" == home-v1 ]] && ok "gate rollback" || bad "gate rollback: $(get /)"
rc=0; ci "id" >/tmp/s-deny 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "other commands are refused" || bad "id rc=$rc"
rc=0; ci "deploy-artifact $s4; id" </root/art-v4.tgz >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "command injection refused" || bad "injection rc=$rc"
rc=0; ci "deploy-artifact $(printf '0%.0s' {1..64})" </root/art-v4.tgz >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "gate checks the sha256" || bad "gate sha rc=$rc"
rc=0; ci "deploy-git $(printf 'a%.0s' {1..40})" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artifact key cannot deploy from git" || bad "git rc=$rc"
ssh -i /root/ci -o BatchMode=yes -o UserKnownHostsFile=/root/ci_known_hosts -o ExitOnForwardFailure=yes -R 18081:127.0.0.1:80 simai-deploy@127.0.0.1 status >/dev/null 2>&1 \
  && bad "port forwarding allowed" || ok "port forwarding refused"
grep -q 'denied' /var/log/simai-deploy-gate.log && ok "refusals are logged" || bad "no gate log"
kid=$(sed -n 's/.*Key id *| *\([a-f0-9]\{12\}\).*/\1/p' /tmp/s-key | head -1)
[[ -n "$kid" ]] || kid=$(ls /etc/simai-env/deploy-keys | head -1)
cli site deploy-key-remove --key-id "$kid" --confirm yes >/dev/null 2>&1
ci status >/dev/null 2>&1 && bad "revoked key still works" || ok "revoked key is refused"
echo "failures=$fails"; exit $fails

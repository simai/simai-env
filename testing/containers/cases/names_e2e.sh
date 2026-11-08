#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
# A site's extra names (site names, site name-add, site name-remove), 1.53.0.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { local arg; for arg; do if [[ "$arg" == --confirm || "$arg" == --confirm=* ]]; then ./simai-admin.sh "$@"; return; fi; done; ./simai-admin.sh "$@" --confirm yes; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
names() { ./simai-admin.sh site names --domain "$1" --output json 2>/dev/null; }
code() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $1" "http://127.0.0.1${2:-/}"; }
D=names.test; C=/etc/nginx/sites-available/$D.conf; X=/etc/nginx/conf.d/simai-site-names-$D.conf

for s in $D other.test; do
  cli site add --domain "$s" --profile static --create-db no >/tmp/add.$s 2>&1 || { bad "site add $s"; tail -8 /tmp/add.$s; }
done
echo names-site >/home/simai/www/$D/public/index.html

a=$(names $D)
[[ "$(field 'd["data"]["schema"] + str([(r["name"], r["kind"]) for r in d["data"]["names"]]) + str(d["data"]["suggest"])' <<<"$a")" == "simai-site-names/1[('names.test', 'primary')]['www.names.test']" ]] \
  && ok "a new site has only its main name and suggests www" || bad "names: ${a:0:300}"

cli site name-add --domain $D --name www.$D --check-dns no >/tmp/n1 2>&1 && ok "name-add www (redirect by default)" || { bad "name-add www"; tail -8 /tmp/n1; }
[[ -f $X ]] && [[ "$(code www.$D /a?b=1)" == "301 http://$D/a?b=1" ]] && ok "www answers 301 to the main domain with the path" || bad "www redirect: $(code www.$D /a?b=1)"
grep -q "server_name $D;" $C && ok "a redirect name is not in the site's own server_name" || bad "site server_name: $(grep server_name $C)"

cli site name-add --domain $D --name alt.$D --mode serve --check-dns no >/tmp/n2 2>&1 && ok "name-add alt (serve)" || { bad "name-add alt"; tail -8 /tmp/n2; }
[[ "$(curl -s -H "Host: alt.$D" http://127.0.0.1/)" == names-site ]] && grep -q "server_name $D alt.$D;" $C && ok "a serve name shows the site" || bad "alt serve: $(grep server_name $C)"
./simai-admin.sh site info --domain $D 2>&1 | grep 'Hostnames.*alt\.names\.test' >/dev/null && ok "the name is part of the site's host names (kept when nginx is written again)" || bad "hostnames"
[[ "$(names $D | field 'str([(r["name"], r["kind"], r["mode"]) for r in d["data"]["names"]]) + str(d["data"]["suggest"])')" == "[('names.test', 'primary', 'serve'), ('www.names.test', 'extra', 'redirect'), ('alt.names.test', 'extra', 'serve')][]" ]] \
  && ok "names lists both, in order, with their modes" || bad "names list: $(names $D | head -c 400)"

cli site name-add --domain $D --name other.test --check-dns no >/dev/null 2>&1 && bad "another site's domain taken" || ok "another site's domain is refused"
cli site name-add --domain $D --name $D --check-dns no >/dev/null 2>&1 && bad "main domain as extra" || ok "the main domain is refused"
cli site name-add --domain $D --name 'bad_name' --check-dns no >/dev/null 2>&1 && bad "invalid name" || ok "an invalid name is refused"
cli site name-add --domain other.test --name www.$D --check-dns no >/tmp/n3 2>&1 && bad "a name of another site taken" || { grep -q "belongs to $D" /tmp/n3 && ok "a name of another site is refused with its owner" || bad "taken message: $(tail -2 /tmp/n3)"; }
cli site name-add --domain $D --name nowhere.invalid >/dev/null 2>&1 && bad "a name that points nowhere" || ok "a name that does not point here is refused"

# A site with a Let's Encrypt certificate (made here; Let's Encrypt is not reachable from the test).
mkdir -p /etc/letsencrypt/live/$D /etc/letsencrypt/renewal
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=$D -addext "subjectAltName=DNS:$D,DNS:www.$D,DNS:alt.$D" \
  -keyout /etc/letsencrypt/live/$D/privkey.pem -out /etc/letsencrypt/live/$D/fullchain.pem >/dev/null 2>&1
echo "# test" >/etc/letsencrypt/renewal/$D.conf
before=$(md5sum $C $X)
cli site name-add --domain $D --name shop.$D --check-dns no >/tmp/n4 2>&1 && bad "a name the certificate cannot cover" || ok "no certificate for the new name: it is refused"
[[ "$(md5sum $C $X)" == "$before" ]] && ! names $D | grep shop >/dev/null && ok "and nothing is left of it" || bad "shop left: $(grep server_name $C $X)"
[[ "$(names $D | field '[r["https"] for r in d["data"]["names"]] + [d["data"]["certificate"]["names"]]')" == "[False, False, False, ['alt.names.test', 'names.test', 'www.names.test']]" ]] \
  && ok "names reads the certificate's names (HTTPS only once the site serves 443)" || bad "cert in names: $(names $D | head -c 500)"
rm -rf /etc/letsencrypt/live/$D /etc/letsencrypt/renewal/$D.conf

cli site name-remove --domain $D --name alt.$D >/dev/null 2>&1 && grep -q "server_name $D;" $C && ok "name-remove takes a serve name out of nginx" || bad "remove alt: $(grep server_name $C)"
cli site name-remove --domain $D --name www.$D >/dev/null 2>&1 && [[ ! -f $X ]] && ! grep -rq "www\.$D" /etc/nginx/ && ok "the last redirect name takes its nginx file with it" || bad "remove www: $(ls $X 2>&1; grep -rl "www\.$D" /etc/nginx/)"
cli site name-remove --domain $D --name www.$D >/dev/null 2>&1 && bad "removing a name twice" || ok "removing a name that is not there is refused"
nginx -t >/dev/null 2>&1 && ok "nginx configuration stays valid" || bad "nginx -t"

cli site remove --domain other.test --remove-files yes >/dev/null 2>&1
cli site remove --domain $D --remove-files yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

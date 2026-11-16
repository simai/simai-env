#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# site cache-clear: a site's OPcache scripts (another site of the same PHP
# version keeps its own), its nginx fastcgi cache (not a zone another site
# shares), the framework cache of laravel, wordpress and bitrix as the site
# user, the plan (CLI and gateway), the job result, and the refusal of a
# redirect site.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env-cache && cp -r /src /root/simai-env-cache && chmod +x /root/simai-env-cache/*.sh
cd /root/simai-env-cache
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
item() { j "next((i['state']+'|'+str(i.get('reason') or '')) for i in d['data']['items'] if i['name']=='$1')"; }
get() { curl -s --max-time 10 -H "Host: $1" "http://127.0.0.1$2"; }
docroot() { sed -n -E 's/^[[:space:]]*root[[:space:]]+([^;]+);.*/\1/p' "/etc/nginx/sites-available/$1.conf" | head -n1; }
project() { sed -n 's/^# simai-project: *//p' "/etc/nginx/sites-available/$1.conf" | head -n1; }
php=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli profile init --mode all --confirm yes >/tmp/cc-profile.out 2>&1 || true
for p in laravel wordpress bitrix; do cli profile enable --id "$p" --confirm yes >>/tmp/cc-profile.out 2>&1 || true; done
G1=cache-one.test G2=cache-two.test L=cache-lara.test W=cache-wp.test B=cache-bx.test R=cache-redirect.test
for d in "$G1" "$G2"; do
  cli site add --domain "$d" --profile generic --php "$php" --create-db no --confirm yes >"/tmp/cc-add-$d.out" 2>&1 \
    || { bad "add $d"; tail -10 "/tmp/cc-add-$d.out"; }
done
cli site add --domain "$R" --profile redirect --redirect-to https://cache-one.test --confirm yes >/tmp/cc-add-r.out 2>&1 \
  || { bad 'add redirect site'; tail -10 /tmp/cc-add-r.out; }

# 1. OPcache: only this site's scripts; the other site keeps its own.
for d in "$G1" "$G2"; do
  doc=$(docroot "$d"); owner=$(stat -c %U:%G "$doc")
  echo '<?php echo "x";' >"$doc/x.php"
  echo '<?php header("Cache-Control: no-store"); echo json_encode(opcache_is_script_cached(__DIR__ . "/x.php"));' >"$doc/chk.php"
  chown "$owner" "$doc/x.php" "$doc/chk.php"
done
sleep 3  # opcache.file_update_protection: files younger than 2 seconds are not cached
for d in "$G1" "$G2"; do get "$d" /x.php >/dev/null; done
c1=$(get "$G1" "/chk.php?a=$RANDOM") c2=$(get "$G2" "/chk.php?a=$RANDOM")
[[ "$c1|$c2" == "true|true" ]] && ok 'both sites have x.php in the OPcache' || bad "OPcache not warm: $c1|$c2"

plan=$(cli site cache-clear --domain "$G1" --output json 2>/dev/null)
[[ "$(j "d['status']" <<<"$plan")" == planned ]] && ok 'cache-clear without confirm is a plan' || bad "plan: ${plan:0:400}"
[[ "$(item opcache <<<"$plan")|$(item nginx_cache <<<"$plan")|$(item framework <<<"$plan")" == "planned||skipped|none|skipped|none" ]] \
  && ok 'plan: OPcache planned, nginx cache none, no framework cache for generic' || bad "plan items: ${plan:0:800}"
c1=$(get "$G1" "/chk.php?a=$RANDOM")
[[ "$c1" == true ]] && ok 'a plan changes nothing' || bad "plan cleared the OPcache: $c1"

res=$(cli site cache-clear --domain "$G1" --confirm yes --output json 2>/tmp/cc-g1.err)
[[ "$(j "d['status']+'|'+d['data']['schema']" <<<"$res")" == "success|simai-site-cache/1" ]] && ok 'cache-clear answers simai-site-cache/1' \
  || { bad "clear: ${res:0:600}"; tail -5 /tmp/cc-g1.err; }
[[ "$(item opcache <<<"$res")" == "cleared|" ]] && ok "OPcache item cleared ($(j "next(i['detail'] for i in d['data']['items'] if i['name']=='opcache')" <<<"$res"))" \
  || bad "opcache item: ${res:0:600}"
c1=$(get "$G1" "/chk.php?a=$RANDOM") c2=$(get "$G2" "/chk.php?a=$RANDOM")
[[ "$c1" == false ]] && ok "the site's x.php left the OPcache" || bad "G1 still cached: $c1"
[[ "$c2" == true ]] && ok "the other site's x.php stays in the OPcache" || bad "G2 lost its cache: $c2"
[[ -z "$(ls -A /var/lib/simai-env/opcache-clear 2>/dev/null)" ]] && ok 'no helper script left behind' || bad 'helper left behind'
out=$(cli site cache-clear --domain "$G1" --confirm yes 2>&1)
[[ "$out" == *opcache*cleared* && "$out" == *nginx_cache*"skipped: none"* ]] && ok 'human output is a table' || bad "table: ${out:0:600}"

# 2. nginx fastcgi cache of the site's own zone; a shared zone is skipped.
mkdir -p /etc/nginx/simai-custom /var/cache/nginx
cat >/etc/nginx/conf.d/cc-test.conf <<'EOF'
fastcgi_cache_path /var/cache/nginx/cc-one levels=1:2 keys_zone=CCONE:10m;
EOF
p1=$(project "$G1")
printf 'fastcgi_cache CCONE;\nfastcgi_cache_key "$host$request_uri";\nfastcgi_cache_valid 200 10m;\n' >"/etc/nginx/simai-custom/${p1}.conf"
nginx -t >/tmp/cc-nginx.out 2>&1 && systemctl reload nginx || { bad 'nginx cache config'; cat /tmp/cc-nginx.out; }
sleep 2  # the reload is asynchronous: old workers answer for a moment
get "$G1" /x.php >/dev/null; get "$G1" /x.php?b=1 >/dev/null
n=$(find /var/cache/nginx/cc-one -type f | wc -l)
(( n > 0 )) && ok "nginx cached $n responses" || bad 'nginx cache empty'
plan=$(cli site cache-clear --domain "$G1" --output json 2>/dev/null)
[[ "$(item nginx_cache <<<"$plan")" == "planned|" && "$(j "next(i['target'] for i in d['data']['items'] if i['name']=='nginx_cache')" <<<"$plan")" == /var/cache/nginx/cc-one ]] \
  && ok 'plan names the cache path' || bad "nginx plan: ${plan:0:600}"
res=$(cli site cache-clear --domain "$G1" --confirm yes --output json 2>/dev/null)
[[ "$(item nginx_cache <<<"$res")" == "cleared|" && -d /var/cache/nginx/cc-one && -z "$(find /var/cache/nginx/cc-one -type f)" ]] \
  && ok 'nginx cache emptied, its directory kept' || bad "nginx clear: ${res:0:600}"
p2=$(project "$G2")
printf 'fastcgi_cache CCONE;\nfastcgi_cache_key "$host$request_uri";\n' >"/etc/nginx/simai-custom/${p2}.conf"
nginx -t >/dev/null 2>&1 && systemctl reload nginx && sleep 2
get "$G2" /x.php >/dev/null
[[ "$(cli site cache-clear --domain "$G1" --output json 2>/dev/null | item nginx_cache)" == "skipped|zone_shared" ]] \
  && ok 'a zone another site uses is skipped (zone_shared)' || bad 'shared zone not skipped'
: >"/etc/nginx/simai-custom/${p1}.conf"; : >"/etc/nginx/simai-custom/${p2}.conf"; rm -f /etc/nginx/conf.d/cc-test.conf
nginx -t >/dev/null 2>&1 && systemctl reload nginx

# 3. Laravel: artisan optimize:clear in the current release, as the site user.
cli site add --domain "$L" --profile laravel --php "$php" --create-db yes --confirm yes >/tmp/cc-add-l.out 2>&1 \
  || { bad 'add laravel'; tail -10 /tmp/cc-add-l.out; }
lroot=/home/simai/www/$L; lowner=$(stat -c %U:%G "$lroot"); luser=${lowner%%:*}
mkdir -p "$lroot/releases/r1"
cat >"$lroot/releases/r1/artisan" <<'EOF'
<?php
$u = function_exists('posix_geteuid') ? posix_getpwuid(posix_geteuid())['name'] : getenv('USER');
file_put_contents(__DIR__ . '/artisan.log', $u . ' ' . implode(' ', array_slice($argv, 1)) . "\n", FILE_APPEND);
echo "Caches cleared\n";
EOF
chown -R "$lowner" "$lroot/releases"; ln -sfn releases/r1 "$lroot/current"
res=$(cli site cache-clear --domain "$L" --confirm yes --output json 2>/dev/null)
[[ "$(item framework <<<"$res")" == "cleared|" ]] && ok 'laravel framework cache cleared' || bad "laravel: ${res:0:600}"
[[ "$(cat "$lroot/releases/r1/artisan.log" 2>/dev/null)" == "$luser optimize:clear --no-interaction" ]] \
  && ok "artisan optimize:clear ran in the current release as $luser" || bad "artisan log: $(cat "$lroot/releases/r1/artisan.log" 2>&1)"
rm -f "$lroot/releases/r1/artisan"
[[ "$(cli site cache-clear --domain "$L" --output json 2>/dev/null | item framework)" == "skipped|artisan_missing" ]] \
  && ok 'no artisan: skipped artisan_missing' || bad 'artisan_missing'

# 4. WordPress: WP-CLI missing is a skip; with WP-CLI, flush and transients as the site user.
cli site add --domain "$W" --profile wordpress --php "$php" --create-db yes --confirm yes >/tmp/cc-add-w.out 2>&1 \
  || { bad 'add wordpress'; tail -10 /tmp/cc-add-w.out; }
wdoc=$(docroot "$W"); wowner=$(stat -c %U:%G "$wdoc"); wuser=${wowner%%:*}
mkdir -p "$wdoc/wp-includes"; echo '<?php // site' >"$wdoc/wp-config.php"; echo '<?php' >"$wdoc/index.php"
chown -R "$wowner" "$wdoc"
phar=/usr/local/lib/simai-env/wp-cli.phar
if [[ ! -e $phar ]] && ! command -v wp >/dev/null; then
  [[ "$(cli site cache-clear --domain "$W" --output json 2>/dev/null | item framework)" == "skipped|wp_cli_missing" ]] \
    && ok 'no WP-CLI: skipped wp_cli_missing' || bad 'wp_cli_missing'
fi
mkdir -p /usr/local/lib/simai-env
[[ -e $phar ]] && mv "$phar" "$phar.cc-saved"
cat >"$phar" <<'EOF'
<?php
$u = function_exists('posix_geteuid') ? posix_getpwuid(posix_geteuid())['name'] : getenv('USER');
$args = array_values(array_filter(array_slice($argv, 1), fn($a) => strpos($a, '--path=') !== 0));
file_put_contents('/tmp/cc-wp.log', $u . ' ' . implode(' ', $args) . "\n", FILE_APPEND);
echo "Success\n";
EOF
chmod 0755 "$phar"; rm -f /tmp/cc-wp.log
res=$(cli site cache-clear --domain "$W" --confirm yes --output json 2>/dev/null)
[[ "$(item framework <<<"$res")" == "cleared|" ]] && ok 'wordpress framework cache cleared' || bad "wordpress: ${res:0:600}"
[[ "$(cat /tmp/cc-wp.log 2>/dev/null)" == "$wuser cache flush"$'\n'"$wuser transient delete --all" ]] \
  && ok "wp cache flush and transient delete --all ran as $wuser" || bad "wp log: $(cat /tmp/cc-wp.log 2>&1)"
rm -f "$phar"; [[ -e $phar.cc-saved ]] && mv "$phar.cc-saved" "$phar"

# 5. Bitrix: contents of the three cache directories, as the site user.
cli site add --domain "$B" --profile bitrix --php "$php" --create-db yes --confirm yes >/tmp/cc-add-b.out 2>&1 \
  || { bad 'add bitrix'; tail -10 /tmp/cc-add-b.out; }
bdoc=$(docroot "$B"); bowner=$(stat -c %U:%G "$bdoc")
for c in cache managed_cache stack_cache; do mkdir -p "$bdoc/bitrix/$c/s1/ab"; echo x >"$bdoc/bitrix/$c/s1/ab/f.php"; done
mkdir -p "$bdoc/bitrix/modules"; echo keep >"$bdoc/bitrix/modules/keep.txt"
chown -R "$bowner" "$bdoc/bitrix"
res=$(cli site cache-clear --domain "$B" --confirm yes --output json 2>/dev/null)
[[ "$(item framework <<<"$res")" == "cleared|" ]] && ok "bitrix caches cleared ($(j "next(i['detail'] for i in d['data']['items'] if i['name']=='framework')" <<<"$res"))" \
  || bad "bitrix: ${res:0:600}"
left=$(find "$bdoc/bitrix/cache" "$bdoc/bitrix/managed_cache" "$bdoc/bitrix/stack_cache" -mindepth 1 2>/dev/null | wc -l)
[[ "$left" == 0 && -d $bdoc/bitrix/managed_cache && -f $bdoc/bitrix/modules/keep.txt ]] \
  && ok 'cache directories emptied and kept; other files untouched' || bad "bitrix left $left entries"

# 6. A redirect site has no caches of its own.
r=$(cli site cache-clear --domain "$R" --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['refusal']" <<<"$r")" == "failed|profile_unsupported" ]] && ok 'CLI plan refuses a redirect site' || bad "redirect: ${r:0:400}"
cli site cache-clear --domain "$R" --confirm yes >/dev/null 2>&1 && bad 'redirect site cleared' || ok 'confirmed clear refuses a redirect site'

# 7. Panel gateway: plan, job with its result, refusal.
cli panel gate-enable --confirm yes >/tmp/cc-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/cc-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req site:cache-clear "{\"domain\":\"$B\"}")")
[[ "$(j "d['kind']+'|'+','.join(i['name']+':'+i['state'] for i in d['data']['clear'])" <<<"$a")" == "plan|opcache:planned,nginx_cache:skipped,framework:planned" ]] \
  && ok 'gateway plan lists what will be cleared' || bad "gateway plan: ${a:0:600}"
a=$(gate "$(req site:cache-clear "{\"domain\":\"$R\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:profile_unsupported ]] && ok 'gateway refuses profile_unsupported' || bad "gateway refusal: ${a:0:400}"
a=$(gate "$(req site:cache-clear "{\"domain\":\"$R\"}" ',"confirm":true')")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:profile_unsupported ]] && ok 'gateway refuses the job too' || bad "gateway job refusal: ${a:0:400}"
echo x >"$bdoc/bitrix/cache/again.php"; chown "$bowner" "$bdoc/bitrix/cache/again.php"
a=$(gate "$(req site:cache-clear "{\"domain\":\"$B\"}" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a"); st=""
for _ in $(seq 1 60); do
  s=$(gate "$(req job:status "{\"job_id\":\"$jid\"}")"); st=$(j "d['data']['state']" <<<"$s" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok 'gateway job succeeds' || bad "gateway job: $st"
[[ "$(j "d['data']['result']['schema']+'|'+next(i['state'] for i in d['data']['result']['items'] if i['name']=='framework')" <<<"$s")" == "simai-site-cache/1|cleared" ]] \
  && ok 'job result lists what was cleared' || bad "job result: ${s:0:600}"
[[ ! -e $bdoc/bitrix/cache/again.php ]] && ok 'the job cleared the Bitrix cache' || bad 'job left the cache'

# site remove that keeps the database user moves db.env out of the site folder.
if [[ -f "/etc/simai-env/sites/$L/db.env" ]]; then
  cli site remove --domain "$L" --remove-files yes --drop-db yes --drop-db-user no --confirm yes >/tmp/rm-keep 2>&1
  kept=$(ls /etc/simai-env/kept-db/${L}-*.env 2>/dev/null | head -1)
  [[ ! -e "/etc/simai-env/sites/$L" && -n "$kept" && "$(stat -c '%U %a' "$kept")" == "root 600" ]] \
    && ok 'kept database user: db.env moved to kept-db, site folder gone' || bad "kept db.env: $(ls -la /etc/simai-env/sites/$L /etc/simai-env/kept-db 2>&1 | head -5)"
  grep -q "kept-db/${L}-" /tmp/rm-keep && ok 'site remove says where the credentials went' || bad 'no kept-db path in output'
else
  bad "no db.env for $L to test"
fi
for d in "$G1" "$G2" "$L" "$W" "$B" "$R"; do
  cli site remove --domain "$d" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
done
echo "failures=$fails"; exit "$fails"

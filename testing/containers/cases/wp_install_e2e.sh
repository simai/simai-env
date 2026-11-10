#!/usr/bin/env bash
# WordPress by one click: wp install (plan, install, the admin password only
# in the result: not in the admin log, the audit log, a job log or any file),
# the login page and a real login, wp status steps, the panel gateway
# (wp:status, wp:install plan and job, the password once in job:status),
# wp restore-ready of a copy of the first site into a second domain with
# home/siteurl and links rewritten, and the WordPress profile rules with
# site check-fix. Needs wordpress.org (and the WP-CLI phar): without them the
# case SKIPs.
set -uo pipefail
rm -rf /root/simai-env-wp
cp -r /src /root/simai-env-wp
cd /root/simai-env-wp || exit 1
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
skip() { echo "SKIP $*"; cleanup; echo "failures=$fails"; exit "$fails"; }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
D=wpone.test D2=wptwo.test D3=wpjob.test D4=wpjson.test
root=/home/simai/www/$D root2=/home/simai/www/$D2
cleanup() {
  local s
  for s in "$D" "$D2" "$D3" "$D4"; do
    cli site remove --domain "$s" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
  done
}
status() { cli wp status --domain "$1" --output json 2>/dev/null; }
step() { status "$1" | j "d['data']['route']+'/'+d['data']['step']"; }
# Where the password must never be: logs, toolkit state, site files.
leaks() { grep -rlF -- "$1" /var/log /etc/simai-env /var/lib/simai-env /home/simai/www 2>/dev/null; }
http() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1$2"; }
login() {  # domain user password -> HTTP code and Location of the login POST
  curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $1" -b 'wordpress_test_cookie=WP%20Cookie%20check' \
    --data-urlencode "log=$2" --data-urlencode "pwd=$3" -d 'wp-submit=Log+In&testcookie=1' "http://127.0.0.1/wp-login.php"
}

curl -fsS --max-time 30 -o /dev/null 'https://api.wordpress.org/core/version-check/1.7/' \
  || skip 'wordpress.org is not reachable from the container; WordPress install not tested'

cli profile init --mode all --confirm yes >/tmp/wp-profile.out 2>&1 \
  || cli profile enable --id wordpress --confirm yes >>/tmp/wp-profile.out 2>&1 || bad 'enable profiles'
cli profile enable --id wordpress --confirm yes >/dev/null 2>&1 || true
for s in "$D" "$D2" "$D3" "$D4"; do
  cli site add --domain "$s" --profile wordpress --php 8.3 --create-db yes --confirm yes >"/tmp/wp-add-$s.out" 2>&1 \
    || { bad "add WordPress site $s"; tail -15 "/tmp/wp-add-$s.out"; }
done

# 1. Plans change nothing; the plan refuses bad arguments.
[[ "$(step "$D")" == none/prepare ]] && ok 'empty site: route none, step prepare' || bad "first step: $(step "$D")"
[[ "$(status "$D" | j "d['data']['next']")" == wp:install ]] && ok 'next is wp:install' || bad 'next before install'
p=$(cli wp install --domain "$D" --title 'Demo WP' --admin-user admin --admin-email admin@example.com 2>&1)
[[ "$p" == *"Rerun with --confirm yes"* && "$p" == *"shown once"* && ! -d $root/public/wp-includes ]] \
  && ok 'wp install without confirm is a plan' || bad "plan: ${p:0:600}"
[[ "$(cli wp install --domain "$D" --title 'Demo WP' --admin-user admin --admin-email admin@example.com --output json 2>/dev/null | j "d['status']")" == planned ]] \
  && ok 'JSON plan: planned' || bad 'JSON plan'
[[ "$(cli wp install --domain "$D" --title 'Demo WP' --admin-user admin --admin-email nope --output json 2>/dev/null | j "d['status']")" == failed ]] \
  && ok 'the plan refuses a bad e-mail' || bad 'bad e-mail planned'

# 2. Install.
out=$(cli wp install --domain "$D" --title 'Demo WP' --admin-user admin --admin-email admin@example.com --confirm yes 2>/tmp/wp-install.err)
rc=$?
if (( rc != 0 )) && grep -qiE 'download|checksum|WP-CLI could not' /tmp/wp-install.err; then
  tail -5 /tmp/wp-install.err
  skip 'WordPress or WP-CLI download failed; WordPress install not tested'
fi
(( rc == 0 )) && ok 'wp install' || { bad "wp install rc=$rc"; tail -30 /tmp/wp-install.err; }
pw=$(awk -F'|' '$2 ~ /Admin password/ {gsub(/ /, "", $3); print $3}' <<<"$out")
[[ ${#pw} -ge 20 ]] && ok 'the result shows a generated admin password' || bad "no password in the result: ${out:0:800}"
[[ -z "$(leaks "$pw")" ]] && ok 'password in no log, audit log, toolkit state or site file' || bad "password leaked: $(leaks "$pw")"
grep -q 'section=wp cmd=install phase=finish exit=0' /var/log/simai-audit.log && ok 'the install is audited' || bad 'no audit line'
[[ "$(http "$D" /wp-login.php)" == 200 ]] && ok 'login page answers 200' || bad "login page: $(http "$D" /wp-login.php)"
l=$(login "$D" admin "$pw")
[[ "$l" == "302 "*wp-admin* ]] && ok 'the shown password logs in' || bad "login: $l"
[[ "$(login "$D" admin wrong-password)" == 200* ]] && ok 'a wrong password does not' || bad 'wrong password accepted'
s=$(status "$D")
[[ "$(j "d['data']['route']+'/'+d['data']['step']+'|'+str(d['data']['pending'])+'|'+str(d['data']['next'])+'|'+d['data']['url']" <<<"$s")" == "new/done|[]|None|http://$D/wp-admin/" ]] \
  && ok 'installed site: route new, step done, admin url' || bad "status after install: ${s:0:700}"
[[ "$(stat -c %a "$root/public/wp-config.php")" == 640 && "$(stat -c %U "$root/public/wp-config.php")" == "$(stat -c %U "$root/public")" ]] \
  && ok 'wp-config.php 0640, owned by the site user' || bad "wp-config: $(stat -c '%a %U' "$root/public/wp-config.php")"
[[ -x /usr/local/lib/simai-env/wp-cli.phar && "$(stat -c %U /usr/local/lib/simai-env/wp-cli.phar)" == root ]] \
  && ok 'WP-CLI phar is the toolkit one (root, checked)' || bad 'wp-cli phar'
[[ "$(cli wp install --domain "$D" --title x --admin-user a --admin-email a@example.com --output json 2>/dev/null | j "d['status']")" == failed ]] \
  && ok 'a second install is refused' || bad 'second install planned'

# 3. JSON answer carries the password as data, and only there.
js=$(cli wp install --domain "$D4" --title 'JSON WP' --admin-user boss --admin-email boss@example.com --locale en_US --confirm yes --output json 2>/dev/null)
pw4=$(j "d['data']['admin_password']" <<<"$js" 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['schema']+'|'+d['data']['login_status']" <<<"$js")" == "success|simai-wp-install/1|200" && ${#pw4} -ge 20 ]] \
  && ok 'JSON install: admin_password in data' || bad "JSON install: ${js:0:500}"
[[ -z "$(leaks "$pw4")" ]] && ok 'JSON password stays out of every log and file' || bad "JSON password leaked: $(leaks "$pw4")"
[[ "$(login "$D4" boss "$pw4")" == "302 "*wp-admin* ]] && ok 'the JSON password logs in' || bad 'JSON login'

# 4. Panel gateway: wp:status, a plan, a job, the password once.
cli panel gate-enable --confirm yes >/tmp/wp-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/wp-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req wp:status "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']+'|'+d['data']['schema']+'|'+d['data']['step']" <<<"$a")" == 'ok|simai-wp-status/1|done' ]] && ok 'gateway wp:status' || bad "gateway status: ${a:0:400}"
ins="{\"domain\":\"$D3\",\"title\":\"Job WP\",\"admin-user\":\"editor\",\"admin-email\":\"editor@example.com\"}"
a=$(gate "$(req wp:install "$ins")")
[[ "$(j "d['kind']+'|'+d['data']['command']" <<<"$a")" == 'plan|wp:install' ]] && ok 'gateway wp:install plans' || bad "gateway plan: ${a:0:400}"
a=$(gate "$(req wp:install "{\"domain\":\"$D3\",\"title\":\"-x\",\"admin-user\":\"e\",\"admin-email\":\"e@example.com\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:invalid_argument ]] && ok 'gateway refuses a title like an option' || bad "title: $a"
a=$(gate "$(req wp:restore-ready "{\"domain\":\"$D2\",\"files\":\"../x.tar.gz\",\"dump\":\"d.sql\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:invalid_argument ]] && ok 'gateway refuses .. in a restore path' || bad "restore path: $a"
a=$(gate "$(req wp:install "$ins" ',"confirm":true')")
jid=$(j "d.get('job_id','')" <<<"$a")
first=""
for _ in $(seq 1 300); do
  first=$(gate "$(req job:status "{\"job_id\":\"$jid\"}")")
  st=$(j "d['data']['state']" <<<"$first" 2>/dev/null)
  [[ "$st" == running || -z "$st" ]] || break; sleep 1
done
[[ "$st" == succeeded ]] && ok 'gateway wp:install job succeeds' || { bad "job: $st"; tail -20 "/var/lib/simai-env/panel-jobs/$jid/log"; }
pw3=$(j "(d['data']['result'] or {}).get('admin_password', '')" <<<"$first")
[[ ${#pw3} -ge 20 && "$(j "d['data']['result']['admin_user']" <<<"$first")" == editor ]] && ok 'first job:status carries the password' || bad "job result: ${first:0:500}"
again=$(gate "$(req job:status "{\"job_id\":\"$jid\"}")")
[[ "$(j "str('admin_password' in d['data']['result'])+'|'+str(d['data']['result'].get('shown_once'))" <<<"$again")" == "False|['admin_password']" ]] \
  && ok 'the next job:status no longer has it (shown_once)' || bad "second status: ${again:0:400}"
[[ "$(gate "$(req job:list '{}')")" != *"$pw3"* ]] && ok 'job:list never shows it' || bad 'job:list shows the password'
[[ -n "$pw3" ]] && ! grep -qF -- "$pw3" "/var/lib/simai-env/panel-jobs/$jid/log" && grep -q 'job result' "/var/lib/simai-env/panel-jobs/$jid/log" \
  && ok 'job log points to the result, without the password' || bad 'job log has the password'
[[ -n "$pw3" && -z "$(leaks "$pw3")" ]] && ok 'job password in no file or log (job dir included)' || bad "job password leaked: $(leaks "$pw3")"
[[ "$(login "$D3" editor "$pw3")" == "302 "*wp-admin* ]] && ok 'the job password logs in' || bad 'job login'

# 5. Restore a copy of the first site into a second domain.
mysql -e "UPDATE \`$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D/db.env")\`.wp_posts SET post_content='Visit http://$D/sample-page/ today' WHERE ID=1" \
  || bad 'plant a link'
db1=$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D/db.env")
db2=$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D2/db.env")
owner2=$(stat -c %U:%G "$root2/public")
# A fixed home URL in the copy's config must follow the new domain too.
sed -i "s#^\$table_prefix#define( 'WP_HOME', 'http://$D' );\n\$table_prefix#" "$root/public/wp-config.php"
grep -q "'WP_HOME'" "$root/public/wp-config.php" || bad 'plant WP_HOME'
tar -C "$root/public" -czf "$root2/copy.tar.gz" . && chown "$owner2" "$root2/copy.tar.gz"
[[ "$(step "$D2")" == restore/upload ]] && ok 'archive uploaded: route restore, step upload' || bad "upload step: $(step "$D2")"
mysqldump --single-transaction "$db1" | gzip -c >"$root2/public/dump.sql.gz" && chown "$owner2" "$root2/public/dump.sql.gz"
s=$(status "$D2")
[[ "$(j "d['data']['route']+'/'+d['data']['step']+'|'+d['data']['next']+'|'+','.join(d['data']['files'])+'|'+','.join(d['data']['dumps'])" <<<"$s")" == "restore/install|wp:restore-ready|copy.tar.gz|public/dump.sql.gz" ]] \
  && ok 'both uploaded: step install names the files' || bad "install step: ${s:0:500}"
ln -sf "$root2/copy.tar.gz" "$root2/link.tar.gz"
cli wp restore-ready --domain "$D2" --files link.tar.gz --dump public/dump.sql.gz --confirm yes >/tmp/wp-rr-link.out 2>&1 \
  && bad 'a symlinked archive was accepted' || ok 'a symlinked archive is refused'
rm -f "$root2/link.tar.gz"
cli wp restore-ready --domain "$D2" --files ../wpone.test/x.tar.gz --dump public/dump.sql.gz --confirm yes >/tmp/wp-rr-dots.out 2>&1 \
  && bad 'a .. path was accepted' || ok 'a .. path is refused'
p=$(cli wp restore-ready --domain "$D2" --files copy.tar.gz --dump public/dump.sql.gz 2>&1)
[[ "$p" == *"Rerun with --confirm yes"* && ! -d $root2/public/wp-includes ]] && ok 'restore-ready without confirm is a plan' || bad "restore plan: ${p:0:500}"
cli wp restore-ready --domain "$D2" --files copy.tar.gz --dump public/dump.sql.gz --confirm yes >/tmp/wp-rr.out 2>&1 \
  && ok 'wp restore-ready' || { bad 'wp restore-ready'; tail -40 /tmp/wp-rr.out; }
q() { mysql -NBe "SELECT option_value FROM \`$db2\`.wp_options WHERE option_name='$1'"; }
[[ "$(q home)|$(q siteurl)" == "http://$D2|http://$D2" ]] && ok 'home and siteurl rewritten to the new domain' || bad "urls: $(q home) $(q siteurl)"
[[ "$(mysql -NBe "SELECT post_content FROM \`$db2\`.wp_posts WHERE ID=1")" == "Visit http://$D2/sample-page/ today" ]] \
  && ok 'links in content rewritten' || bad "content: $(mysql -NBe "SELECT post_content FROM \`$db2\`.wp_posts WHERE ID=1")"
grep -qF "define( 'DB_NAME', '$db2' );" "$root2/public/wp-config.php" && ok 'wp-config DB constants from the new db.env' || bad 'wp-config DB_NAME'
grep -qF "define( 'WP_HOME', 'http://$D2' );" "$root2/public/wp-config.php" && ok 'a fixed WP_HOME follows the new domain' || bad 'WP_HOME'
cmp -s <(grep AUTH_KEY "$root/public/wp-config.php") <(grep AUTH_KEY "$root2/public/wp-config.php") && ok 'salts of the copy kept' || bad 'salts changed'
[[ ! -e $root2/public/dump.sql.gz && -f $root2/restore-archive/dump.sql.gz ]] && ok 'finalize moved the dump out of the web root' || bad 'dump still in web root'
[[ -z "$(find "$root2" -maxdepth 1 -name '.wp-restore-*')" ]] && ok 'no staging left' || bad 'staging left behind'
[[ "$(http "$D2" /wp-login.php)" == 200 && "$(login "$D2" admin "$pw")" == "302 "*wp-admin* ]] \
  && ok 'the copy answers and its users log in' || bad "copy login: $(login "$D2" admin "$pw")"
[[ "$(step "$D2")" == restore/done ]] && ok 'restored site: route restore, step done' || bad "after restore: $(step "$D2")"
cli wp restore-ready --domain "$D2" --files copy.tar.gz --dump restore-archive/dump.sql.gz --confirm yes >/tmp/wp-rr2.out 2>&1 \
  && bad 'restore over an installed site without --overwrite' || ok 'restore over a site needs --overwrite yes'

# 6. Profile rules and their one-click fixes.
cfg=$root2/public/wp-config.php
chmod 0644 "$cfg"
sed -i "s/define( 'WP_DEBUG', false );/define( 'WP_DEBUG', true );/; s/define( 'DISABLE_WP_CRON', true );/define( 'DISABLE_WP_CRON', false );/" "$cfg"
grep -q "'WP_DEBUG', true" "$cfg" || sed -i "s#^/\* That's all#define( 'WP_DEBUG', true );\n/* That's all#" "$cfg"
echo zip >"$root2/public/site-backup.zip"; chown "$owner2" "$root2/public/site-backup.zip"
echo zip >"$root2/public/brochure.zip"; chown "$owner2" "$root2/public/brochure.zip"
d=$(cli site doctor --domain "$D2" --output json 2>/dev/null)
for r in wordpress.leftovers:FAIL wordpress.config-perms:FAIL wordpress.debug-off:WARN wordpress.cron:WARN; do
  k=${r%%:*}; want=${r#*:}
  got=$(j "next((c['status']+'|'+str(c.get('fix')) for c in d['data']['checks'] if c.get('key')=='$k'), 'absent')" <<<"$d")
  [[ "$got" == "$want|$k" ]] && ok "doctor: $k $want with a fix" || bad "doctor $k: $got"
done
s=$(status "$D2")
[[ "$(j "d['data']['step']+'|'+','.join(sorted(d['data']['pending']))" <<<"$s")" == "finalize|wordpress.config-perms,wordpress.cron,wordpress.debug-off,wordpress.leftovers" ]] \
  && ok 'wp status: step finalize lists the rules' || bad "pending: ${s:0:500}"
[[ "$(cli site check-fix --domain "$D2" --id wordpress.config-perms --output json 2>/dev/null | j "d['status']")" == planned ]] \
  && ok 'check-fix without confirm is a plan' || bad 'check-fix plan'
a=$(gate "$(req site:check-fix "{\"domain\":\"$D2\",\"id\":\"wordpress.debug-off\"}")")
[[ "$(j "d['kind']+'|'+d['data']['check']['id']+'|'+str(bool(d['data']['check']['plan']))" <<<"$a")" == 'plan|wordpress.debug-off|True' ]] \
  && ok 'gateway check-fix plan for a WordPress rule' || bad "gateway rule plan: ${a:0:400}"
for k in wordpress.leftovers wordpress.config-perms wordpress.debug-off wordpress.cron; do
  cli site check-fix --domain "$D2" --id "$k" --confirm yes >"/tmp/wp-fix-$k.out" 2>&1 && ok "check-fix $k" || { bad "check-fix $k"; tail -15 "/tmp/wp-fix-$k.out"; }
done
[[ "$(stat -c %a "$cfg")" == 640 ]] && ok 'wp-config.php 0640 again' || bad "mode $(stat -c %a "$cfg")"
grep -q "define( 'WP_DEBUG', false );" "$cfg" && grep -q "define( 'DISABLE_WP_CRON', true );" "$cfg" && php -l "$cfg" >/dev/null \
  && ok 'debug off and DISABLE_WP_CRON true, wp-config still valid PHP' || bad 'wp-config after fixes'
[[ "$(stat -c %U "$cfg")" == "${owner2%%:*}" ]] && ok 'wp-config keeps its owner' || bad "owner $(stat -c %U "$cfg")"
[[ ! -e $root2/public/site-backup.zip && -f $root2/restore-archive/site-backup.zip ]] && ok 'zip moved out of the web root' || bad 'zip leftover'
[[ -f $root2/public/brochure.zip ]] && ok 'a zip the site serves stays' || bad 'brochure.zip moved'
d=$(cli site doctor --domain "$D2" --output json 2>/dev/null)
[[ "$(j "sorted({c['status'] for c in d['data']['checks'] if (c.get('fix') or '').startswith('wordpress.')})" <<<"$d")" == "['PASS']" ]] \
  && ok 'every WordPress rule passes after the fixes' || bad "after fixes: $(j "[(c['key'],c['status']) for c in d['data']['checks'] if (c.get('key') or '').startswith('wordpress.')]" <<<"$d")"
[[ "$(step "$D2")" == restore/done ]] && ok 'wp status back to done' || bad "done again: $(step "$D2")"
[[ "$(http "$D2" /wp-login.php)" == 200 ]] && ok 'the site still answers after the fixes' || bad 'site broken by fixes'
[[ "$(cli site check-fix --domain "$D2" --id wordpress.cron --output json 2>/dev/null | j "d['status']")" == failed ]] \
  && ok 'a rule that holds is refused' || bad 'check_ok refused'

cleanup
echo "failures=$fails"; exit "$fails"

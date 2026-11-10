#!/usr/bin/env bash
# Site creation routes for the panel wizard: self profiles answers routes
# (new, restore, repo) declared in the profile files, every step a gateway
# command or open_url and the last one site:doctor; site status answers one
# shape (simai-site-status/1) for bitrix, laravel and static sites, through
# the CLI and the panel gateway, with the owner scope.
set -uo pipefail
rm -rf /root/simai-env-routes
cp -r /src /root/simai-env-routes
cd /root/simai-env-routes || exit 1
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
status() { cli site status --domain "$1" --output json 2>/dev/null; }
shape="d['data']['schema']+'|'+d['data']['route']+'|'+d['data']['step']+'|'+str(d['data']['next'])"

cli profile init --mode all --confirm yes >/tmp/rt-profile.out 2>&1 \
  || { for p in bitrix laravel static generic wordpress proxy redirect node; do cli profile enable --id "$p" --confirm yes >>/tmp/rt-profile.out 2>&1; done; }

# 1. Routes in self profiles (CLI).
p=$(cli self profiles --output json 2>/dev/null)
routes() { j "{x['id']: [(r['id'], r['available']) for r in x['routes']] for x in d['data']['profiles']}['$1']" <<<"$p"; }
[[ "$(routes bitrix)" == "[('new', True), ('restore', True)]" ]] && ok 'bitrix: new and restore' || bad "bitrix routes: $(routes bitrix)"
[[ "$(routes laravel)" == "[('repo', True)]" ]] && ok 'laravel: repo' || bad "laravel routes: $(routes laravel)"
[[ "$(routes static)" == "[('new', True), ('repo', True)]" ]] && ok 'static: new and repo' || bad "static routes: $(routes static)"
[[ "$(routes generic)" == "[('new', True), ('restore', False)]" ]] && ok 'generic: new, restore planned' || bad "generic routes: $(routes generic)"
[[ "$(routes wordpress)" == "[('new', True), ('restore', True)]" ]] && ok 'wordpress: new and restore available' || bad "wordpress routes: $(routes wordpress)"
steps() { j "[s['id']+'='+s['command'] for x in d['data']['profiles'] if x['id']=='$1' for r in x['routes'] if r['id']=='$2' for s in r['steps']]" <<<"$p"; }
[[ "$(steps bitrix new)" == "['add=site:add', 'run_setup=open_url', 'finalize=bitrix:finalize', 'done=site:doctor']" ]] \
  && ok 'bitrix new steps' || bad "bitrix new: $(steps bitrix new)"
[[ "$(steps bitrix restore)" == "['add=site:add', 'upload=file:upload', 'validate=bitrix:restore-ready', 'run_restore=open_url', 'finalize=bitrix:finalize', 'done=site:doctor']" ]] \
  && ok 'bitrix restore steps' || bad "bitrix restore: $(steps bitrix restore)"
[[ "$(steps laravel repo)" == "['add=site:add', 'deploy=site:deploy', 'done=site:doctor']" ]] && ok 'laravel repo steps' || bad "laravel repo: $(steps laravel repo)"
[[ "$(j "[s['args'] for x in d['data']['profiles'] if x['id']=='bitrix' for r in x['routes'] for s in r['steps'] if s['id']=='add']" <<<"$p")" \
   == "[{'bitrix-files': 'setup'}, {'bitrix-files': 'restore'}]" ]] && ok 'site:add steps carry bitrix-files' || bad 'bitrix-files args'
[[ "$(j "[s['url_from'] for x in d['data']['profiles'] if x['id']=='bitrix' for r in x['routes'] for s in r['steps'] if s['command']=='open_url']" <<<"$p")" \
   == "['installer_url', 'restore_url']" ]] && ok 'open_url steps name their status key' || bad 'url_from'
[[ "$(j "sorted({r['steps'][-1]['command'] for x in d['data']['profiles'] for r in x['routes']})" <<<"$p")" == "['site:doctor']" ]] \
  && ok 'every route ends on site:doctor' || bad 'last steps'
[[ "$(j "[(i['name'], i['kind'], i['required']) for x in d['data']['profiles'] if x['id']=='laravel' for i in x['routes'][0]['inputs'] if i['name'] in ('git','ref')]" <<<"$p")" \
   == "[('git', 'url', True), ('ref', 'text', True)]" ]] && ok 'laravel repo asks for git url and ref' || bad 'laravel inputs'
[[ "$(j "[i.get('values') == [a for a in d['data']['php_installed']] for x in d['data']['profiles'] if x['id']=='bitrix' for i in x['routes'][0]['inputs'] if i['name']=='php']" <<<"$p")" \
   == "[True]" ]] && ok 'php input takes the installed versions' || bad "php input: $(j "[i for x in d['data']['profiles'] if x['id']=='bitrix' for i in x['routes'][0]['inputs']]" <<<"$p")"
[[ "$(j "sorted({i['kind'] for x in d['data']['profiles'] for r in x['routes'] for i in r['inputs']})" <<<"$p")" \
   == "['choice', 'file_on_server', 'text', 'upload', 'url']" ]] && ok 'input kinds' || bad 'input kinds'
cli self profiles 2>/dev/null | grep -q 'restore (planned)' && ok 'human answer lists routes' || bad 'human routes'

# 2. site status: static.
S=routes-static.test
cli site add --domain "$S" --profile static --create-db no --confirm yes >/tmp/rt-static.out 2>&1 || { bad 'add static'; tail -10 /tmp/rt-static.out; }
[[ "$(status "$S" | j "$shape")" == "simai-site-status/1|none|prepare|site:deploy" ]] && ok 'static placeholder: prepare, next site:deploy' || bad "static: $(status "$S")"
echo '<h1>mine</h1>' >"/home/simai/www/$S/public/index.html"
[[ "$(status "$S" | j "$shape")" == "simai-site-status/1|installed|done|None" ]] && ok 'static with own page: installed, done' || bad "static own: $(status "$S")"
[[ "$(status "$S" | j "sorted(d['data'])")" == "['detail', 'domain', 'installer_url', 'next', 'pending', 'profile', 'restore_url', 'route', 'schema', 'step']" ]] \
  && ok 'site status keys' || bad 'keys'

# 3. site status: laravel.
L=routes-lara.test
cli site add --domain "$L" --profile laravel --php 8.3 --create-db yes --confirm yes >/tmp/rt-lara.out 2>&1 || { bad 'add laravel'; tail -10 /tmp/rt-lara.out; }
LR=/home/simai/www/$L
[[ "$(status "$L" | j "$shape")" == "simai-site-status/1|none|deploy|site:deploy" ]] && ok 'laravel placeholder: deploy' || bad "laravel deploy: $(status "$L")"
# A release in place of a deploy (no composer in the test): artisan and bootstrap/app.php.
rel=$LR/releases/r1
mkdir -p "$rel/bootstrap" "$rel/public" && printf '<?php\n' >"$rel/artisan" && printf '<?php\n' >"$rel/bootstrap/app.php"
ln -sfn releases/r1 "$LR/current"
sed -i '/^APP_KEY=/d' "$LR/.env" 2>/dev/null || true
[[ "$(status "$L" | j "$shape+'|'+','.join(d['data']['pending'])")" == "simai-site-status/1|repo|configure|laravel:finalize|laravel.app-key" ]] \
  && ok 'laravel release without APP_KEY: configure' || bad "laravel configure: $(status "$L")"
echo 'APP_KEY=base64:dGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRlc3Q=' >>"$LR/.env"
slug=routes-lara-test
[[ -f /etc/cron.d/$slug ]] || bad "no scheduler file for $slug"
[[ "$(status "$L" | j "$shape")" == "simai-site-status/1|repo|done|None" ]] && ok 'laravel with key and scheduler: done' || bad "laravel done: $(status "$L")"
mv "/etc/cron.d/$slug" /tmp/rt-cron
[[ "$(status "$L" | j "$shape+'|'+','.join(d['data']['pending'])")" == "simai-site-status/1|repo|finalize|cron:add|laravel.scheduler" ]] \
  && ok 'laravel without scheduler: finalize, next cron:add' || bad "laravel finalize: $(status "$L")"
mkdir -p "$rel/.simai" && echo '{"schema":"simai-app/1","scheduler":false}' >"$rel/.simai/app.json"
[[ "$(status "$L" | j "d['data']['step']")" == "done" ]] && ok 'manifest without scheduler: done' || bad "scheduler false: $(status "$L")"
mv /tmp/rt-cron "/etc/cron.d/$slug"
status "$L" | grep -q 'base64:' && bad 'site status printed APP_KEY' || ok 'no secrets in the answer'

# 4. site status: bitrix.
B=routes-bx.test
cli site add --domain "$B" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/rt-bx.out 2>&1 || { bad 'add bitrix'; tail -10 /tmp/rt-bx.out; }
bx=/home/simai/www/$B/public
owner=$(stat -c %U:%G "$bx")
rm -f "$bx/restore.php" "$bx/bitrixsetup.php"
[[ "$(status "$B" | j "$shape")" == "simai-site-status/1|none|prepare|bitrix:restore-ready" ]] && ok 'bitrix empty: prepare' || bad "bitrix prepare: $(status "$B")"
echo '<?php // installer' >"$bx/bitrixsetup.php" && chown "$owner" "$bx/bitrixsetup.php"
s=$(status "$B")
[[ "$(j "$shape+'|'+str(bool(d['data']['installer_url']))+'|'+str(d['data']['restore_url'])" <<<"$s")" == "simai-site-status/1|new|run_setup|open_url|True|None" ]] \
  && ok 'bitrix installer: route new, run_setup with installer_url' || bad "bitrix setup: ${s:0:500}"
rm -f "$bx/bitrixsetup.php"
echo '<?php // restore wizard' >"$bx/restore.php" && chown "$owner" "$bx/restore.php"
[[ "$(status "$B" | j "$shape")" == "simai-site-status/1|restore|upload|file:upload" ]] && ok 'bitrix restore.php: upload' || bad "bitrix upload: $(status "$B")"
mkdir -p /tmp/rt-arch/bitrix && echo x >/tmp/rt-arch/bitrix/x.txt
tar -C /tmp/rt-arch -czf "$bx/site_20261110_full_abc.tar.gz" . && chown "$owner" "$bx/site_20261110_full_abc.tar.gz"
[[ "$(status "$B" | j "$shape+'|'+str(d['data']['detail']['archive'])")" == "simai-site-status/1|restore|validate|bitrix:restore-ready|site_20261110_full_abc.tar.gz" ]] \
  && ok 'bitrix archive: validate' || bad "bitrix validate: $(status "$B")"
cli bitrix restore-ready --domain "$B" --confirm yes >/tmp/rt-rr.out 2>&1 || { bad 'restore-ready'; tail -10 /tmp/rt-rr.out; }
s=$(status "$B")
[[ "$(j "$shape+'|'+str(d['data']['restore_url'])" <<<"$s")" == "simai-site-status/1|restore|run_restore|open_url|http://$B/restore.php" ]] \
  && ok 'bitrix validated: run_restore with restore_url' || bad "bitrix run_restore: ${s:0:500}"
b=$(cli bitrix status --domain "$B" --output json 2>/dev/null)
[[ "$(j "d['data']['step']+'|'+str(d['data']['next'])" <<<"$b")" == "run_restore|open_url" ]] && ok 'bitrix status agrees' || bad "bitrix status: ${b:0:300}"
cli site status --domain "$B" 2>&1 | grep -q 'run_restore' && ok 'human site status' || bad 'human status'

# 5. Panel gateway.
cli panel gate-enable --confirm yes >/tmp/rt-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/rt-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s}' "$1" "$2" "$3"; }
a=$(gate "$(req null self:profiles '{}')")
g=$(gate "$(req null self:describe '{}')")
allowed=$(j "','.join(d['data']['gate']['commands'])" <<<"$g")
cmds=$(j "' '.join(sorted({s['command'] for x in d['data']['profiles'] for r in x['routes'] for s in r['steps']}))" <<<"$a")
miss=""
for c in $cmds; do [[ "$c" == open_url || ",$allowed," == *",$c,"* ]] || miss+=" $c"; done
[[ -n "$cmds" && -z "$miss" ]] && ok "every route step is a gateway command ($cmds)" || bad "steps outside the gateway:$miss"
[[ "$(j "[len(x['routes']) for x in d['data']['profiles'] if x['id']=='bitrix']" <<<"$a")" == "[2]" ]] && ok 'gateway self:profiles carries routes' || bad "gateway routes: ${a:0:300}"
a=$(gate "$(req null site:status "{\"domain\":\"$B\"}")")
[[ "$(j "d['status']+'|'+d['data']['schema']+'|'+d['data']['step']" <<<"$a")" == "ok|simai-site-status/1|run_restore" ]] && ok 'gateway site:status bitrix' || bad "gateway bitrix: ${a:0:400}"
a=$(gate "$(req null site:status "{\"domain\":\"$L\"}")")
[[ "$(j "d['status']+'|'+d['data']['route']+'|'+d['data']['step']" <<<"$a")" == "ok|repo|done" ]] && ok 'gateway site:status laravel' || bad "gateway laravel: ${a:0:400}"
a=$(gate "$(req null site:status "{\"domain\":\"$S\"}")")
[[ "$(j "d['status']+'|'+d['data']['route']+'|'+d['data']['step']" <<<"$a")" == "ok|installed|done" ]] && ok 'gateway site:status static' || bad "gateway static: ${a:0:400}"
a=$(gate "$(req null site:status '{"domain":"../x"}')")
[[ "$(j "d['status']+':'+d.get('reason','')" <<<"$a")" == refused:invalid_argument ]] && ok 'gateway refuses a bad domain' || bad "bad domain: $a"
a=$(gate "$(printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"site:status","args":{"domain":"%s"},"confirm":true}' "$S")")
[[ "$(j "d['status']+':'+d.get('reason','')" <<<"$a")" == refused:not_allowed ]] && ok 'a read is never confirmed' || bad "confirm read: $a"
ssh-keygen -q -t ed25519 -N '' -f /root/rt-own <<<y >/dev/null 2>&1
cli owner create --name rtown --pubkey-file /root/rt-own.pub --confirm yes >/dev/null 2>&1
a=$(gate "$(req '"rtown"' site:status "{\"domain\":\"$S\"}")")
[[ "$(j "d['status']+':'+d.get('reason','')" <<<"$a")" == refused:owner_scope ]] && ok "an owner is refused another's site" || bad "owner scope: $a"

for d in "$S" "$L" "$B"; do cli site remove --domain "$d" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true; done
echo "failures=$fails"; exit "$fails"

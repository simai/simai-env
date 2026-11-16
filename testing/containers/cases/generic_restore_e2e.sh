#!/usr/bin/env bash
# Restore of a plain PHP site (generic profile): site restore-ready from a
# .tar.gz with a wrapping folder and a .sql.gz dump (the page reads the
# restored table), the archive and dump moved to the site's trash, refusals
# (not empty without --overwrite, wrong profile, path outside the site), a
# .zip archive that carries public/ itself, --overwrite with a backup first,
# a .zip with a '..' entry refused, the generic restore route in
# self profiles and the gateway plan.
set -uo pipefail
rm -rf /root/simai-env-gr
cp -r /src /root/simai-env-gr
cd /root/simai-env-gr || exit 1
# As on a server: the site user cannot enter root's working directory.
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
http() { curl -s -H "Host: $1" "http://127.0.0.1$2"; }
D=gr.test D2=grzip.test R=/home/simai/www/$D R2=/home/simai/www/$D2
cleanup() {
  local s
  for s in "$D" "$D2" grwp.test; do
    cli site remove --domain "$s" --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/dev/null 2>&1 || true
  done
}
cli profile enable --id generic --confirm yes >/dev/null 2>&1

cli site add --domain $D --profile generic --php 8.3 --create-db yes --confirm yes >/tmp/gr-add 2>&1 || { bad 'site add'; tail -5 /tmp/gr-add; }
owner=$(stat -c %U:%G $R)
# The copy: a folder around the site's files, a page that reads the database
# through the credentials the site's config would hold.
src=$(mktemp -d); mkdir -p "$src/mysite/inc"
cat >"$src/mysite/index.php" <<'PHP'
<?php
$e = parse_ini_file('/etc/simai-env/sites/gr.test/db.env', false, INI_SCANNER_RAW) ?: [];
require __DIR__ . '/inc/db.php';
PHP
cat >"$src/mysite/inc/db.php" <<'PHP'
<?php
$c = getenv('GR_DSN');
echo "RESTORED-FILES\n";
PHP
tar -C "$src" -czf $R/public/copy.tar.gz mysite
printf 'CREATE TABLE notes (id INT PRIMARY KEY, body VARCHAR(50));\nINSERT INTO notes VALUES (1, "from-the-dump");\n' | gzip -c >$R/dump.sql.gz
chown $owner $R/public/copy.tar.gz $R/dump.sql.gz

# Plan only.
cli site restore-ready --domain $D --files public/copy.tar.gz --dump dump.sql.gz >/tmp/gr-plan 2>&1 && grep -q 'Rerun with --confirm yes' /tmp/gr-plan \
  && ok 'plan without confirm' || { bad 'plan'; tail -5 /tmp/gr-plan; }
[[ ! -f $R/public/inc/db.php ]] && ok 'the plan changes nothing' || bad 'plan restored files'
cli site restore-ready --domain $D --files ../../etc/passwd --confirm yes >/dev/null 2>&1 && bad 'path outside the site accepted' || ok 'path outside the site refused'

cli site restore-ready --domain $D --files public/copy.tar.gz --dump dump.sql.gz --confirm yes >/tmp/gr-run 2>&1 && ok 'restore' || { bad 'restore'; tail -15 /tmp/gr-run; }
[[ "$(http $D /)" == *RESTORED-FILES* ]] && ok 'restored page answers' || bad "page: $(http $D / | head -c 200)"
[[ -f $R/public/inc/db.php && "$(stat -c %U $R/public/inc/db.php)" == "${owner%%:*}" ]] && ok 'wrapping folder stripped, files owned by the site user' || bad "files: $(ls -la $R/public | head)"
db=$(sed -n 's/^DB_NAME=//p' /etc/simai-env/sites/$D/db.env)
[[ "$(mysql -Nse "SELECT body FROM \`$db\`.notes WHERE id=1")" == from-the-dump ]] && ok 'dump imported into the site database' || bad 'dump not imported'
[[ ! -e $R/public/copy.tar.gz && ! -e $R/dump.sql.gz ]] && ok 'archive and dump left the web root' || bad "sources left: $(ls $R/public $R)"
[[ "$(cli file trash-list --domain $D --output json 2>/dev/null | j "len(d['data']['entries'])" 2>/dev/null)" == 2 ]] \
  && ok 'archive and dump are in the site trash' || bad "trash: $(cli file trash-list --domain $D --output json 2>&1 | head -c 300)"
[[ "$(cli site status --domain $D --output json 2>/dev/null | j "d['data']['step']")" == "done" ]] && ok 'site status: done' || bad 'site status'

# Again: the site has files and tables now.
tar -C "$src" -czf $R/public/copy2.tar.gz mysite && chown $owner $R/public/copy2.tar.gz
if cli site restore-ready --domain $D --files public/copy2.tar.gz --confirm yes >/tmp/gr-again 2>&1; then
  bad 'restore over files without --overwrite'
else
  grep -q 'overwrite yes' /tmp/gr-again && ok 'existing files need --overwrite' || bad "refusal: $(tail -3 /tmp/gr-again)"
fi
before=$(ls /var/backups/simai/$D 2>/dev/null | wc -l)
cli site restore-ready --domain $D --files public/copy2.tar.gz --overwrite yes --confirm yes >/tmp/gr-over 2>&1 && ok 'restore with --overwrite' || { bad 'overwrite'; tail -10 /tmp/gr-over; }
(( $(ls /var/backups/simai/$D 2>/dev/null | wc -l) > before )) && ok 'a backup is taken before overwriting' || bad 'no backup before overwrite'

# A .zip that carries the web root folder itself goes to the site root.
cli site add --domain $D2 --profile generic --php 8.3 --create-db no --confirm yes >/dev/null 2>&1 || bad 'site add zip'
z=$(mktemp -d); mkdir -p "$z/public" "$z/app"; echo '<?php echo "ZIP-RESTORED";' >"$z/public/index.php"; echo 'x' >"$z/app/lib.txt"
(cd "$z" && python3 -c 'import zipfile; z=zipfile.ZipFile("site.zip","w"); z.write("public/index.php"); z.write("app/lib.txt"); z.close()')
cp "$z/site.zip" $R2/site.zip && chown "$(stat -c %U:%G $R2)" $R2/site.zip
cli site restore-ready --domain $D2 --files site.zip --confirm yes >/tmp/gr-zip 2>&1 && ok 'restore from .zip' || { bad 'zip restore'; tail -10 /tmp/gr-zip; }
[[ "$(http $D2 /)" == ZIP-RESTORED && -f $R2/app/lib.txt && "$(stat -c %a $R2)" != 700 ]] && ok 'an archive with public/ lands in the site root' || bad "zip layout: $(http $D2 / | head -c 100); $(ls $R2)"
cli site restore-ready --domain $D2 --files site.zip --dump x.sql --confirm yes >/dev/null 2>&1 && bad 'dump without a database accepted' || ok 'a dump needs the site database'
python3 -c 'import zipfile; z=zipfile.ZipFile("/tmp/evil.zip","w"); z.writestr("../evil.php","x"); z.close()'
cp /tmp/evil.zip $R2/evil.zip && chown "$(stat -c %U:%G $R2)" $R2/evil.zip
cli site restore-ready --domain $D2 --files evil.zip --overwrite yes --confirm yes >/dev/null 2>&1 && bad '.. entry in a zip accepted' || ok "a zip entry with '..' is refused"
[[ ! -e /home/simai/www/evil.php ]] && ok 'nothing written outside the site' || bad 'zip escaped the site'

# Other profiles have their own restore.
cli profile enable --id wordpress --confirm yes >/dev/null 2>&1
cli site add --domain grwp.test --profile wordpress --php 8.3 --create-db yes --confirm yes >/dev/null 2>&1
cli site restore-ready --domain grwp.test --files x.tar.gz >/tmp/gr-wp 2>&1; grep -q 'wp restore-ready' /tmp/gr-wp && ok 'a WordPress site is sent to wp restore-ready' || bad "wp refusal: $(tail -2 /tmp/gr-wp)"

# Panel: the route and the gateway plan.
[[ "$(cli self profiles --output json 2>/dev/null | j "[[s['command'] for s in r['steps']] for p in d['data']['profiles'] if p['id']=='generic' for r in p['routes'] if r['id']=='restore' and r['available']]")" \
   == "[['site:add', 'file:upload', 'site:restore-ready', 'site:doctor']]" ]] && ok 'generic restore route is available' || bad 'route'
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"site:restore-ready","args":%s}' "$1"; }
cp "$z/site.zip" $R2/site2.zip && chown "$(stat -c %U:%G $R2)" $R2/site2.zip
[[ "$(gate "$(req "{\"domain\":\"$D2\",\"files\":\"site2.zip\",\"overwrite\":\"yes\"}")" | j "d['status']+'/'+d.get('kind','')")" == ok/plan ]] && ok 'gateway plan' || bad 'gateway plan'
[[ "$(gate "$(req "{\"domain\":\"$D2\",\"files\":\"../x.zip\"}")" | j "d['status']+'/'+d.get('reason','')")" == refused/invalid_argument ]] && ok 'gateway refuses ..' || bad 'gateway ..'

cleanup
echo "failures=$fails"; exit "$fails"

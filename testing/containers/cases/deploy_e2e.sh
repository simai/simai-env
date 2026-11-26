#!/usr/bin/env bash
# shellcheck disable=SC2010,SC2164  # container test script: loose quoting/cd checks are fine here
# Runs after adopt_e2e.sh in the same container (app.test adopted in place).
set -uo pipefail
export COMPOSER_ALLOW_SUPERUSER=1
cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { local arg; for arg; do if [[ "$arg" == --confirm || "$arg" == --confirm=* ]]; then ./simai-admin.sh "$@"; return; fi; done; ./simai-admin.sh "$@" --confirm yes; }
D=app.test; P=/home/simai/www/$D
page() { curl -s -H "Host: $D" "http://127.0.0.1/${1:-}"; }
key0=$(grep '^APP_KEY=' $P/.env)
set -a; . /etc/simai-env/sites/$D/db.env; set +a

mk_src() {  # $1 = version label
  rm -rf /root/src-$1; cp -a /root/laravel-src /root/src-$1; rm -rf /root/src-$1/vendor /root/src-$1/.env
  cp -a $P/.simai /root/src-$1/ 2>/dev/null || cp -a $P/current/.simai /root/src-$1/
  cat > /root/src-$1/routes/web.php <<PHP
<?php
use Illuminate\Support\Facades\Route;
Route::get('/', fn () => 'release-$1');
Route::get('/key', fn () => substr(config('app.key'), 0, 12));
PHP
}
mk_src v2
cat > /root/src-v2/database/migrations/2030_01_01_000000_create_widgets_table.php <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
return new class extends Migration {
    public function up(): void { Schema::create('widgets', function (Blueprint $t) { $t->id(); }); }
    public function down(): void { Schema::dropIfExists('widgets'); }
};
PHP
bash ./simai-admin.sh site deploy --domain $D --from /root/src-v2 >/tmp/dp 2>&1; grep -q 'Deploy plan for' /tmp/dp && [[ ! -d $P/releases ]] && ok "deploy shows its plan without conversion" || bad "plan"
cli site deploy --domain $D --from /root/src-v2 --confirm yes >/tmp/d1 2>&1 && ok "deploy v2" || { bad "deploy v2"; tail -20 /tmp/d1; grep -i error /var/log/simai-admin.log | tail -5; }
[[ -L $P/current && -d $P/releases ]] && ok "release layout active" || bad "layout"
ls $P/releases | grep -q -- '-initial$' && ok "adopted code kept as initial release" || bad "no initial release"
[[ "$(page)" == release-v2 ]] && ok "site serves release v2" || bad "page: $(page | head -c 80)"
[[ "$(readlink $P/current/storage)" == ../../storage && "$(readlink $P/current/.env)" == ../../.env ]] && ok "storage and .env shared" || bad "shared links"
[[ "$(grep '^APP_KEY=' $P/.env)" == "$key0" ]] && ok "APP_KEY unchanged by deploy" || bad "APP_KEY changed"
runuser -u postgres -- psql -d "$DB_NAME" -Atc "select to_regclass('public.widgets')" | grep -q widgets && ok "new migration ran" || bad "migration"
grep -q "WorkingDirectory=$P/current" /etc/systemd/system/laravel-queue-app-test.service && ok "worker runs from current" || bad "worker dir"
grep -q "cd $P/current &&" /etc/cron.d/app-test && ok "scheduler runs from current" || bad "cron dir"
sleep 7; systemctl is-active --quiet laravel-queue-app-test.service && ok "worker active after deploy (restarted gracefully)" || bad "worker"
grep -q "root $P/current/public;" /etc/nginx/sites-available/$D.conf && ok "nginx serves current/public" || bad "nginx root"

# Broken release: current keeps serving.
mk_src v3; echo '{broken' > /root/src-v3/composer.json
cli site deploy --domain $D --from /root/src-v3 --confirm yes >/tmp/d3 2>&1 && bad "broken deploy succeeded" || ok "broken deploy refused"
[[ "$(page)" == release-v2 ]] && ok "v2 still serving after failed deploy" || bad "page after failure"
[[ "$(ls $P/releases | wc -l)" == 2 ]] && ok "failed release cleaned up" || bad "releases: $(ls $P/releases)"

# Archive source with checksum.
mk_src v4; tar -czf /root/v4.tgz -C /root/src-v4 .
sum=$(sha256sum /root/v4.tgz | cut -d' ' -f1)
cli site deploy --domain $D --archive /root/v4.tgz --sha256 0000 --confirm yes >/dev/null 2>&1 && bad "bad checksum accepted" || ok "wrong sha256 refused"
cli site deploy --domain $D --archive /root/v4.tgz --sha256 $sum --confirm yes >/tmp/d4 2>&1 && ok "deploy v4 from archive" || { bad "archive deploy"; tail /tmp/d4; }
[[ "$(page)" == release-v4 ]] && ok "site serves v4" || bad "v4 page"
[[ "$(page key)" == "${key0:8:12}" ]] && ok "app reads the shared APP_KEY" || bad "key: $(page key) vs ${key0:8:12}"

# Rollback.
cli site deploy-rollback --domain $D --confirm yes >/tmp/rb 2>&1 && ok "rollback" || { bad rollback; tail /tmp/rb; }
[[ "$(page)" == release-v2 ]] && ok "rollback serves v2 again" || bad "after rollback: $(page | head -c 60)"
cli site deploy-status --domain $D 2>&1 | grep -q current && ok "deploy-status lists releases" || bad "status"

# Retention.
for v in v5 v6 v7; do mk_src $v; cli site deploy --domain $D --from /root/src-$v --keep 3 --confirm yes >/dev/null 2>&1; done
n=$(ls $P/releases | wc -l); [[ "$n" -le 4 ]] && ok "retention keeps a bounded number ($n)" || bad "releases kept: $n"
[[ "$(page)" == release-v7 ]] && ok "latest release live" || bad "latest"

# Data backup only archives the live release.
cli backup data --domain $D --keep 1 >/dev/null 2>&1 && ok "backup data on release layout" || bad backup
b=$(ls -1d /var/backups/simai/$D/2* | tail -1)
[[ "$(tar -tzf $b/files.tar.gz | grep -o '^\./releases/[^/]\+' | sort -u | wc -l)" == 1 ]] && ok "backup contains only the live release" || bad "backup releases"
# Deploy key extras (1.66.0): allowed artisan commands and env-set over SSH.
mk_src v8
cat >> /root/src-v8/routes/console.php <<'PHP'

Illuminate\Support\Facades\Artisan::command('gate:echo {words?*}', function () {
    $this->line('args=' . implode(',', $this->argument('words')) . ' stdin=' . trim((string) stream_get_contents(STDIN)) . ' user=:' . getenv('USER'));
});
Illuminate\Support\Facades\Artisan::command('gate:other', fn () => $this->line('other'));
PHP
cli site deploy --domain $D --from /root/src-v8 --confirm yes >/tmp/d8 2>&1 && ok "deploy v8" || { bad "deploy v8"; tail /tmp/d8; }
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl start ssh
ssh-keygen -q -t ed25519 -N '' -f /root/ci
cli site deploy-key-add --domain $D --pubkey-file /root/ci.pub --host 127.0.0.1 --confirm yes >/tmp/k 2>&1 && ok "deploy-key-add" || { bad "deploy-key-add"; tail -8 /tmp/k; }
sed -n '/SIMAI_DEPLOY_KNOWN_HOSTS/,$p' /tmp/k | grep '^127.0.0.1 ' >/root/ci_known_hosts
ci() { ssh -i /root/ci -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/ci_known_hosts simai-deploy@127.0.0.1 "$@"; }
kid=$(ls /etc/simai-env/deploy-keys | head -1)
rc=0; ci "artisan gate:echo a" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan refused before deploy-key-allow" || bad "artisan without allow rc=$rc"
cli site deploy-key-allow --key-id "$kid" --artisan tinker >/dev/null 2>&1 && bad "tinker accepted" || ok "dangerous artisan names refused"
cli site deploy-key-allow --key-id "$kid" --env-prefix APP_ >/dev/null 2>&1 && bad "APP_ prefix accepted" || ok "application prefixes refused"
cli site deploy-key-allow --key-id "$kid" --artisan gate:echo --env-prefix LARENA_SERVER_ >/tmp/ka 2>&1 && ok "deploy-key-allow" || { bad "deploy-key-allow"; tail /tmp/ka; }
out=$(printf 'from-stdin\n' | ci "artisan gate:echo one two=2 /p/x" 2>&1)
[[ "$out" == *"args=one,two=2,/p/x stdin=from-stdin"* ]] && ok "allowed artisan runs with args and stdin" || bad "artisan out: $out"
[[ "$out" == *":$(stat -c %U $P/.env)"* ]] && ok "artisan runs as the site user" || bad "artisan user: $out"
rc=0; ci "artisan gate:other" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "unlisted artisan refused" || bad "unlisted rc=$rc"
rc=0; ci "artisan gate:echo --env=testing" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan --env refused" || bad "--env rc=$rc"
rc=0; ci "artisan gate:echo a;id" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan shell characters refused" || bad "injection rc=$rc"
b64a() { python3 -c 'import base64,json,os,sys; print(base64.urlsafe_b64encode(json.dumps([os.fsencode(a).decode() for a in sys.argv[1:]]).encode()).decode().rstrip("="))' "$@"; }
out=$(ci "artisan-args gate:echo $(b64a 'Хранение файлов' 'Резервные копии; id' 'a$(id)b')" </dev/null 2>&1)
[[ "$out" == *'args=Хранение файлов,Резервные копии; id,a$(id)b stdin='* ]] && ok "artisan-args: spaces, Cyrillic and shell characters arrive as plain text" || bad "artisan-args out: $out"
rc=0; ci "artisan-args gate:other $(b64a x)" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan-args keeps the allowlist" || bad "artisan-args unlisted rc=$rc"
rc=0; ci "artisan-args gate:echo $(b64a '--env=testing')" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan-args refuses --env" || bad "artisan-args --env rc=$rc"
rc=0; ci "artisan-args gate:echo $(b64a $'two\nlines')" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan-args refuses control characters" || bad "artisan-args newline rc=$rc"
rc=0; ci "artisan-args gate:echo WyJcdWQ4MDAiXQ" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan-args refuses broken UTF-8" || bad "artisan-args surrogate rc=$rc"
rc=0; ci "artisan-args gate:echo bm90LWpzb24" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "artisan-args refuses what is not a JSON list" || bad "artisan-args not json rc=$rc"
# The gate's own patterns must stay small: with {1,12000} each call took over 1 GB (1.68.0).
gate_bin=$(command -v simai-deploy-gate || echo /usr/local/sbin/simai-deploy-gate)
out=$(prlimit --as=$((700*1024*1024)) -- bash "$gate_bin" "$kid" "artisan-args gate:echo $(python3 -c 'import base64,json; print(base64.urlsafe_b64encode(json.dumps(["я" * 900]).encode()).decode())')" </dev/null 2>&1)
[[ "$out" == *"args=яяя"* ]] && ok "artisan-args runs within 700 MB of address space" || bad "gate under a memory limit: ${out:0:200}"
rc=0; ci "artisan gate:echo $(head -c 201 /dev/zero | tr '\0' a)" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "an artisan word over 200 characters is refused" || bad "long word rc=$rc"
mode0=$(stat -c '%a %U:%G' $P/.env)
printf 'tok-SECRET-123 with space\n' | ci "env-set LARENA_SERVER_TOKEN" >/tmp/es 2>&1 && ok "env-set" || { bad "env-set"; cat /tmp/es; }
grep -qx 'LARENA_SERVER_TOKEN="tok-SECRET-123 with space"' $P/.env && ok "value written quoted" || bad "env line: $(grep LARENA_SERVER_TOKEN $P/.env)"
printf 'second\n' | ci "env-set LARENA_SERVER_TOKEN" >/dev/null 2>&1
[[ "$(grep -c '^LARENA_SERVER_TOKEN=' $P/.env)" == 1 ]] && grep -qx 'LARENA_SERVER_TOKEN=second' $P/.env && ok "env-set replaces the old value" || bad "replace"
[[ "$(stat -c '%a %U:%G' $P/.env)" == "$mode0" ]] && ok ".env mode and owner kept" || bad ".env now $(stat -c '%a %U:%G' $P/.env), was $mode0"
[[ "$(grep '^APP_KEY=' $P/.env)" == "$key0" ]] && ok "APP_KEY untouched by env-set" || bad "APP_KEY changed"
rc=0; printf 'x\n' | ci "env-set APP_KEY" >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && ok "env-set outside the prefix refused" || bad "APP_KEY rc=$rc"
rc=0; printf 'a\nb\n' | ci "env-set LARENA_SERVER_X" >/dev/null 2>&1 || rc=$?; [[ $rc -ne 0 ]] && ok "multi-line value refused" || bad "multi-line accepted"
grep -q 'SECRET' /var/log/simai-deploy-gate.log && bad "value leaked into the gate log" || ok "value not in the gate log"
grep -q 'env-set app.test LARENA_SERVER_TOKEN' /var/log/simai-deploy-gate.log && ok "env-set logged by name" || bad "env-set not logged"
cli site deploy-key-allow --key-id "$kid" --artisan "" >/dev/null 2>&1
rc=0; ci "artisan gate:echo" </dev/null >/dev/null 2>&1 || rc=$?; [[ $rc -eq 126 ]] && grep -q '^ENV_PREFIX=LARENA_SERVER_' /etc/simai-env/deploy-keys/$kid && ok "empty --artisan clears, prefix kept" || bad "clear rc=$rc"
cli site deploy-key-remove --key-id "$kid" --confirm yes >/dev/null 2>&1
# New laravel site, first deploy, then laravel finalize (1.66.0): the code is
# found in current, the shared .env gets .env.example names and an APP_KEY.
F=fin.test; FP=/home/simai/www/$F
fphp=$(./simai-admin.sh site describe --domain $D --output json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data", d)["php"])')
cli site add --domain $F --profile laravel --php "$fphp" --create-db yes --db-engine pgsql >/tmp/fa 2>&1 && ok "site add $F" || { bad "site add $F"; tail /tmp/fa; }
mk_src v9; rm -rf /root/src-v9/.simai; cp -a /root/laravel-src/vendor /root/src-v9/  # ships vendor/, like Larena
[[ -f /root/src-v9/.env.example ]] || printf 'APP_NAME=Laravel\nAPP_KEY=\nLOG_CHANNEL=stack\n' >/root/src-v9/.env.example
echo 'FIN_MARK=from-example' >>/root/src-v9/.env.example
cli site deploy --domain $F --from /root/src-v9 --confirm yes >/tmp/fd 2>&1 && ok "first deploy of $F" || { bad "first deploy $F"; tail /tmp/fd; grep -v "^\s*$" /var/log/simai-admin.log | tail -25 | cut -c1-300; }
fmode=$(stat -c '%a %U:%G' $FP/.env)
cli laravel finalize --domain $F --migrate yes --confirm yes >/tmp/ff 2>&1 && ok "laravel finalize on a release layout" || { bad "finalize"; grep -v '^\s*$' /tmp/ff | tail -12; }
grep -q '^APP_KEY=base64:' $FP/.env && ok "APP_KEY generated in the shared .env" || bad "no APP_KEY"
grep -qx 'FIN_MARK=from-example' $FP/.env && ok ".env.example names added" || bad "example names missing"
[[ -L $FP/current/.env ]] && ok "current/.env still a link" || bad "current/.env replaced"
[[ "$(stat -c '%a %U:%G' $FP/.env)" == "$fmode" ]] && ok ".env mode kept by finalize" || bad ".env $(stat -c '%a %U:%G' $FP/.env) was $fmode"
[[ "$(curl -s -H "Host: $F" http://127.0.0.1/)" == release-v9 ]] && ok "$F serves the release" || { bad "$F page: $(curl -s -o /dev/null -w "%{http_code}" -H "Host: $F" http://127.0.0.1/)"; tail -c 800 $FP/storage/logs/laravel.log; }
[[ -z "$(find $FP/storage -maxdepth 3 -type d -user root)" ]] && ok "shared storage levels belong to the site user" || bad "root-owned: $(find $FP/storage -maxdepth 3 -type d -user root)"
mv $FP/current/resources/views /root/fin-views
cli laravel finalize --domain $F --confirm yes >/tmp/ff2 2>&1 && ok "finalize without resources/views (API-only)" || { bad "finalize API-only"; grep -i error /tmp/ff2 | tail -3; }
mv /root/fin-views $FP/current/resources/views
echo "failures=$fails"; exit $fails

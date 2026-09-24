#!/usr/bin/env bash
# shellcheck disable=SC2010,SC2164  # container test script: loose quoting/cd checks are fine here
# Runs after adopt_e2e.sh in the same container (app.test adopted in place).
set -uo pipefail
export COMPOSER_ALLOW_SUPERUSER=1
cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
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
cli site deploy --domain $D --from /root/src-v2 >/tmp/dp 2>&1; grep -q "first deploy" /tmp/dp && ok "deploy plan mentions layout conversion" || bad "plan"
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
echo "failures=$fails"; exit $fails

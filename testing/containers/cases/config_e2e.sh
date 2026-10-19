#!/usr/bin/env bash
set -uo pipefail
rm -rf /root/simai-env-config
cp -r /src /root/simai-env-config
cd /root/simai-env-config || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { bash ./simai-admin.sh "$@"; }
D=budget.test
cli profile init --mode all --confirm yes >/tmp/profile.out 2>&1 || bad 'enable profiles'
cli site add --domain "$D" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/budget-add.out 2>&1 || { bad 'add Bitrix site'; tail -15 /tmp/budget-add.out; }
pool=/etc/php/8.3/fpm/pool.d/budget-test.conf
for mode in safe balanced aggressive parked; do
  cli site perf-tune --domain "$D" --mode "$mode" --confirm yes >/tmp/budget-perf.out 2>&1 || { bad "tune $mode"; tail /tmp/budget-perf.out; }
  [[ $(grep -c '^request_terminate_timeout =' "$pool") == 1 ]] && grep -q '^request_terminate_timeout = 300s' "$pool" && ok "Bitrix $mode has one 300s timeout" || bad "timeout $mode"
done
cli site php-ini-set --domain "$D" --name memory_limit --value 256M --apply yes --confirm yes >/tmp/budget-ini.out 2>&1 || bad 'set override'
[[ $(grep -c '^php_admin_value\[memory_limit\]' "$pool") == 1 ]] && grep -q 'memory_limit.*256M' "$pool" && ok 'override is unique and wins' || bad 'duplicate/ineffective override'
cli site php-ini-unset --domain "$D" --name memory_limit --apply yes --confirm yes >/tmp/budget-unset.out 2>&1 || bad 'unset override'
grep -q 'memory_limit.*512M' "$pool" && ok 'unsetting restores profile default' || bad 'lost profile default'
cli site config-normalize --domain "$D" --confirm yes >/tmp/normalize.out 2>&1 || { bad 'normalize'; tail /tmp/normalize.out; }
before=$(sha256sum "$pool")
cli site config-normalize --domain "$D" --confirm yes >/tmp/normalize2.out 2>&1 || bad 'repeat normalize'
[[ "$before" == "$(sha256sum "$pool")" ]] && ok 'normalize is idempotent' || bad 'normalize changed again'
grep -q 'fastcgi_read_timeout 300s' /etc/nginx/sites-available/budget.test.conf && nginx -t >/tmp/nginx.out 2>&1 && ok 'nginx budget matches PHP/FPM' || bad 'nginx timeout'
cli observer init --domain "$D" --schedule no --confirm yes >/tmp/observer-init.out 2>&1 || { bad 'observer init'; tail /tmp/observer-init.out; }
root=/var/lib/simai-env/runtime-observer/budget-test
before=$(find "$root" -type f -printf '%p:%T@\n' | sort | sha256sum)
cli observer status --domain "$D" >/tmp/observer-status.out 2>&1 || bad 'observer status'
[[ "$before" == "$(find "$root" -type f -printf '%p:%T@\n' | sort | sha256sum)" ]] && ok 'observer status leaves files unchanged' || bad 'status wrote state'
cli observer status --domain "$D" --refresh yes >/tmp/observer-preview.out 2>&1
grep -q 'No handler was executed' /tmp/observer-preview.out && ok 'refresh requires confirmation' || bad 'refresh bypassed guard'
cli site doctor --domain "$D" --output json >/tmp/doctor.json 2>/tmp/doctor.err || true
python3 -c 'import json; d=json.load(open("/tmp/doctor.json")); assert d["data"]["schema"]=="simai-site-diagnostics/1" and d["data"]["checks"] and d["verification"]=="diagnostic_checks"; assert all("details" not in row for row in d["data"]["checks"])' && ok 'doctor reports actual checks without raw configuration details' || { bad 'doctor JSON'; head -25 /tmp/doctor.json; }
echo "failures=$fails"; exit "$fails"

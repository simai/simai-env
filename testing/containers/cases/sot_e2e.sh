#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
D=bx.test; P=/home/simai/www/$D
./simai-admin.sh site add --domain $D --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/a 2>&1 || { bad "bitrix site add"; tail -15 /tmp/a; }
pool=/etc/php/8.3/fpm/pool.d/bx-test.conf
grep -q '; simai-profile-ini-begin' $pool && ok "new pool has profile block" || bad "no profile block"
[[ -f /etc/php/8.3/cli/conf.d/99-simai-bitrix.ini && "$(php8.3 -r 'echo ini_get("short_open_tag");')" == 1 ]] && ok "CLI short_open_tag on via conf.d" || bad "CLI short tag"
u=$(cat /etc/simai-env/site-users/bx-test)
printf '<? echo "mem=", ini_get("memory_limit"), " short=", ini_get("short_open_tag");\n' >$P/public/sot.php; chown $u:$u $P/public/sot.php
h() { curl -s -H "Host: $D" http://127.0.0.1/sot.php; }
[[ "$(h)" == "mem=512M short=1" ]] && ok "short tag works before php-ini set ($(h))" || bad "before: $(h)"
./simai-admin.sh site php-ini-set --domain $D --name memory_limit --value 256M --apply yes --confirm yes >/tmp/i 2>&1 || { bad "php-ini set"; tail -5 /tmp/i; }
sleep 1
[[ "$(h)" == "mem=256M short=1" ]] && ok "after php-ini set: override wins, short tag kept ($(h))" || bad "after: $(h)"
# Legacy layout: baseline inside site block, cron without flag.
./simai-admin.sh site php-ini-unset --domain $D --name memory_limit --apply yes --confirm yes >/dev/null 2>&1
sed -i '/; simai-profile-ini-begin/,/; simai-profile-ini-end/d' $pool
printf '; simai-site-ini-begin\nphp_admin_value[memory_limit] = 128M\n; simai-site-ini-end\n' >>$pool
rm -f /etc/php/8.3/cli/conf.d/99-simai-bitrix.ini
sed -i 's/ -d short_open_tag=1//' /etc/cron.d/bx-test
systemctl reload php8.3-fpm; sleep 1
[[ "$(h)" == *short=* && "$(h)" != *"short=1"* || "$(h)" == "<?"* ]] && ok "legacy layout reproduces the bug: $(h | head -c 40)" || echo "INFO legacy output: $(h | head -c 60)"
./simai-admin.sh self migrate --confirm yes >/tmp/m 2>&1; grep Migrated /tmp/m | sed 's/^/  /'
sleep 1
[[ "$(h)" == "mem=128M short=1" ]] && ok "after self migrate: short tag back, site override kept ($(h))" || bad "after migrate: $(h)"
grep -q 'short_open_tag=1.*cron_events' /etc/cron.d/bx-test && ok "cron flag restored" || bad "cron flag"
[[ -f /etc/php/8.3/cli/conf.d/99-simai-bitrix.ini ]] && ok "CLI conf restored" || bad "CLI conf"
./simai-admin.sh self migrate --confirm yes >/tmp/sot-second.out 2>&1
grep -q "nothing to migrate" /tmp/sot-second.out && ok "migrate idempotent" || { bad "migrate not idempotent"; tail /tmp/sot-second.out; }
echo "failures=$fails"; exit $fails

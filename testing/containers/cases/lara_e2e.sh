#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
P=/home/simai/www/lara.test
mkdir -p "$P/public" "$P/bootstrap/cache" "$P/storage"
echo '<?php echo "lara";' >"$P/public/index.php"
printf '<?php\nwhile (true) { sleep(60); }\n' >"$P/artisan"
echo '<?php' >"$P/bootstrap/app.php"
./simai-admin.sh site add --domain lara.test --profile laravel --php 8.3 --create-db yes --path "$P" --confirm yes >/tmp/lara 2>&1 || { bad "laravel site add"; tail -25 /tmp/lara; }
grep -q ' site-lara-test cd ' /etc/cron.d/lara-test && ok "laravel cron runs as site user" || { bad "cron"; cat /etc/cron.d/lara-test; }
u=/etc/systemd/system/laravel-queue-lara-test.service
grep -q '^User=site-lara-test' "$u" && grep -q '^Group=site-lara-test' "$u" && ok "queue unit User/Group = site user" || { bad "queue unit"; grep -E '^(User|Group)=' "$u"; }
systemctl start laravel-queue-lara-test.service; sleep 2
[[ "$(ps -o user= -C php8.3 2>/dev/null | sort -u | tr '\n' ' ')" == *site-lara-test* ]] && ok "queue worker process runs as site user" || bad "worker user: $(ps -o user=,cmd= -C php8.3)"
[[ "$(curl -s -H 'Host: lara.test' http://127.0.0.1/)" == lara ]] && ok "laravel site served" || bad "laravel http"
./simai-admin.sh cron add --domain lara.test --user root --confirm yes >/tmp/c 2>&1 && bad "cron --user root accepted" || ok "cron --user root refused"
echo "failures=$fails"; exit $fails

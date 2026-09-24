#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh; cd /root/simai-env
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
P=/home/simai/www/lara.test; mkdir -p $P/public $P/bootstrap/cache $P/storage
echo '<?php echo "lara";' >$P/public/index.php; printf '<?php\nwhile (true) { sleep(60); }\n' >$P/artisan; echo '<?php' >$P/bootstrap/app.php
./simai-admin.sh site add --domain lara.test --profile laravel --php 8.3 --create-db yes --path $P >/tmp/a 2>&1 || { bad add; tail /tmp/a; }
systemctl start laravel-queue-lara-test.service; sleep 2
./simai-admin.sh owner create --name acme >/dev/null 2>&1
./simai-admin.sh site isolate --domain lara.test --owner acme --confirm yes >/tmp/m 2>&1 && ok "move laravel with running queue" || { bad move; tail /tmp/m; }
sleep 2
id site-lara-test >/dev/null 2>&1 && bad "old site user left: $(pgrep -u site-lara-test -l)" || ok "old site user removed"
[[ "$(ps -o user= -C php8.3 | sort -u | tr '\n' ' ')" == *acme* ]] && ok "worker now runs as acme" || bad "worker user"
[[ "$(curl -s -H 'Host: lara.test' http://127.0.0.1/)" == lara ]] && ok "site served" || bad http
echo "failures=$fails"; exit $fails

#!/usr/bin/env bash
set -uo pipefail
cp -r /src /root/simai-env-menu
cd /root/simai-env-menu || exit 1
fails=0
bash ./simai-admin.sh self auto-update-disable --confirm yes >/tmp/menu-off.out 2>&1 || { cat /tmp/menu-off.out; exit 1; }
python3 testing/containers/menu_probe.py || fails=$((fails + 1))
# All wizard fields are supplied; only the explicit final confirmation remains.
rc=0
printf '1\n' | SIMAI_ADMIN_MENU=1 SIMAI_MENU_BACKEND=text bash ./simai-admin.sh site add \
  --domain cancelled.test --profile generic --php 8.3 --create-db no --ssl none \
  --usage standard --host-mode standard --access-create no >/tmp/menu-cancel.out 2>&1 || rc=$?
if [[ $rc == 89 && ! -e /etc/nginx/sites-available/cancelled.test.conf && ! -e /home/simai/www/cancelled.test ]] && grep -q 'cancelled at step' /tmp/menu-cancel.out; then
  echo 'PASS wizard cancellation reports stage and creates no site'
else
  echo 'FAIL wizard cancellation'; tail -20 /tmp/menu-cancel.out; fails=$((fails + 1))
fi
echo "failures=$fails"; exit "$fails"

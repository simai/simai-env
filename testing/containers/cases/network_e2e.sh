#!/usr/bin/env bash
set -uo pipefail
cp -r /src /root/simai-env-network
cd /root/simai-env-network || exit 1
fails=0
bash ./simai-admin.sh db network-localize --ack-no-external yes >/tmp/network-plan.out 2>&1
if [[ ! -e /etc/mysql/conf.d/99-simai-network.cnf ]] && grep -q 'No handler was executed' /tmp/network-plan.out; then echo 'PASS network preview changes nothing'; else echo 'FAIL network preview'; fails=$((fails + 1)); fi
if bash ./simai-admin.sh db network-localize --ack-no-external yes --confirm yes >/tmp/network-apply.out 2>&1; then
  echo 'PASS network restriction applies after acknowledgement'
else
  echo 'FAIL network restriction'; tail -12 /tmp/network-apply.out; fails=$((fails + 1))
fi
mysql -NBe 'SELECT 1' | grep -q '^1$' && echo 'PASS local database connection survives' || { echo 'FAIL local connection'; fails=$((fails + 1)); }
backup=$(find /var/backups/simai-system/mysql-network -name mysql-config.tar.gz | head -n1)
if [[ -n "$backup" ]] && gzip -t "$backup" && tar -tzf "$backup" >/dev/null; then echo 'PASS network config recovery archive verified'; else echo 'FAIL recovery archive'; fails=$((fails + 1)); fi
echo "failures=$fails"; exit "$fails"

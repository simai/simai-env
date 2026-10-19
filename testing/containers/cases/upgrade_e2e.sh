#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Upgrade from 1.14.0: managed cron written before confirmation existed must
# keep working after `self update`, which on old hosts runs the OLD handler
# (it calls `self migrate` without --confirm).
set -uo pipefail
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
OLD_REF="previous release (/opt/simai-baseline, exported by run.sh)"

[[ -f /opt/simai-baseline/simai-admin.sh ]] || { echo "FAIL baseline toolkit missing in /opt/simai-baseline"; exit 1; }
# There is no upgrade path from a release that did not support this OS.
if ! bash -c 'source /opt/simai-baseline/lib/platform.sh; platform_detect_os; platform_is_supported_os'; then
  echo "PASS skipped: the baseline does not support $(. /etc/os-release; echo "$PRETTY_NAME")"; echo "failures=0"; exit 0
fi
rm -rf /root/simai-env && cp -a /opt/simai-baseline /root/simai-env
chmod +x /root/simai-env/*.sh
cd /root/simai-env
[[ "$(cat VERSION)" == 1.14.0 ]] && ok "old toolkit ${OLD_REF} installed" || bad "old version $(cat VERSION)"
id simai >/dev/null 2>&1 || useradd -m simai

# State created by the old toolkit.
./simai-admin.sh site add --domain upg.test --profile generic --php 8.3 --create-db yes >/tmp/u-add 2>&1 \
  && ok "old: site add" || { bad "old site add"; tail -5 /tmp/u-add; }
./simai-admin.sh backup data-schedule --domain upg.test --time 03:30 --keep 2 >/dev/null 2>&1
cat >/etc/cron.d/simai-scheduler <<'CRON'
# simai-scheduler-begin
* * * * * root flock -n /run/lock/simai-scheduler.lock /root/simai-env/simai-admin.sh self scheduler >> /var/log/simai-scheduler.log 2>&1
# simai-scheduler-end
CRON
chmod 0644 /etc/cron.d/simai-scheduler
grep -q -- '--confirm' /etc/cron.d/simai-backup-upg-test && bad "old cron already confirmed?" || ok "old: backup cron without --confirm"

# Code swap as update.sh does it, then the old handler's post-update step.
rm -rf /root/simai-env.old && mv /root/simai-env /root/simai-env.old
cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
SIMAI_ADMIN_MENU=0 bash /root/simai-env/simai-admin.sh self migrate >/tmp/u-mig 2>&1 \
  && ok "new: self migrate without --confirm (1.14.0 handler path)" || { bad "migrate rc"; tail -8 /tmp/u-mig; }
grep -q "No handler was executed" /tmp/u-mig && bad "migrate only previewed" || ok "migrate executed, not previewed"
grep -q -- 'backup data --domain upg.test .*--confirm yes' /etc/cron.d/simai-backup-upg-test && ok "backup cron got --confirm yes" || { bad "backup cron"; cat /etc/cron.d/simai-backup-upg-test; }
grep -q -- 'self scheduler --confirm yes' /etc/cron.d/simai-scheduler && ok "scheduler cron got --confirm yes" || { bad "scheduler cron"; cat /etc/cron.d/simai-scheduler; }
ls /var/backups/simai-system/cron-confirm/simai-backup-upg-test.* >/dev/null 2>&1 && ok "original cron kept in recovery storage" || bad "no recovery copy"

# The migrated cron line must really run a backup.
cmd=$(grep -v '^#' /etc/cron.d/simai-backup-upg-test | grep . | sed -E 's/^([^ ]+ +){5}root +//')
bash -c "$cmd"
if ls -d /var/backups/simai/upg.test/2* >/dev/null 2>&1; then ok "scheduled backup command creates a backup"; else bad "cron command did not back up: ${cmd}"; fi
# Idempotent.
SIMAI_ADMIN_MENU=0 bash /root/simai-env/simai-admin.sh self migrate >/tmp/u-mig2 2>&1
grep -q "nothing to migrate" /tmp/u-mig2 && ok "second migrate is a no-op" || { bad "migrate not idempotent"; grep -i "migrated\|warn" /tmp/u-mig2 | head -8; }
# Other mutating commands still require confirmation.
./simai-admin.sh site add --domain nope.test --profile generic --php 8.3 2>&1 | grep -q "No handler was executed" && ok "mutations without --confirm still preview" || bad "confirmation bypassed"
echo "failures=$fails"; exit $fails

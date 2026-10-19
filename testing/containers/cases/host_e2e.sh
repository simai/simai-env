#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Host baseline: OS support and PHP source, swap and firewall commands.
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
. /etc/os-release

# OS support and PHP source.
bash -c 'source lib/platform.sh; platform_detect_os; platform_is_supported_os' && ok "${PRETTY_NAME} is supported" || bad "unsupported ${PRETTY_NAME}"
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')
case "$VERSION_CODENAME" in jammy) want=8.1 ;; noble) want=8.3 ;; resolute) want=8.5 ;; *) want="" ;; esac
[[ -n "$native" && "$native" == "$want" ]] && ok "native PHP ${native}" || bad "native PHP '${native}'"
[[ -x "$(command -v "php${native}")" ]] && ok "native PHP ${native} is the one installed in the image" || bad "php${native} missing"
rm -f /tmp/ppa-added
bash -c 'source lib/platform.sh; source admin/lib/apt_utils.sh; info() { :; }; error() { :; }; run_long() { :; }
  os_cmd_pkg_update() { OS_CMD=(true); }; os_cmd_pkg_install() { OS_CMD=(true); }
  has_ondrej_php_repo() { return 1; }; os_cmd_pkg_add_ppa() { touch /tmp/ppa-added; OS_CMD=(true); }
  ensure_ondrej_php_repo "$1"' _ "$native" >/dev/null 2>&1 \
  && [[ ! -e /tmp/ppa-added ]] && ok "native PHP needs no PPA" || bad "PPA requested for native PHP"
bash simai-env.sh bootstrap --mysql nosuch >/tmp/h-boot 2>&1 && bad "invalid --mysql accepted" || { grep -q "expected mysql, percona or none" /tmp/h-boot && ok "bootstrap validates --mysql" || bad "bootstrap message"; }

# Swap: plan without confirmation, then apply (swapon may be refused on the
# container's overlay filesystem; then nothing may be left behind).
cli self swap-ensure --size 1G >/tmp/h-swap-plan 2>&1
grep -q "Swap plan" /tmp/h-swap-plan && [[ ! -e /swapfile ]] && ok "swap-ensure shows its plan and changes nothing" || { bad "swap plan"; cat /tmp/h-swap-plan; }
if [[ "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" != 0 ]]; then
  cli self swap-ensure --size 1G --confirm yes >/tmp/h-swap 2>&1 && grep -q "already provided" /tmp/h-swap && [[ ! -e /swapfile ]] \
    && ok "existing swap is respected (no file added)" || { bad "existing swap"; tail -5 /tmp/h-swap; }
elif cli self swap-ensure --size 1G --confirm yes >/tmp/h-swap 2>&1; then
  swapon --show=NAME --noheadings | grep -qx /swapfile && grep -q '^/swapfile ' /etc/fstab && ok "swap file active and in fstab" || bad "swap not active"
  [[ "$(cat /proc/sys/vm/swappiness)" == 10 ]] && ok "swappiness 10" || bad "swappiness $(cat /proc/sys/vm/swappiness)"
  cli self swap-ensure --size 1G --confirm yes >/dev/null 2>&1 && [[ $(grep -c '^/swapfile ' /etc/fstab) -eq 1 ]] && ok "swap-ensure is idempotent" || bad "swap not idempotent"
  swapoff /swapfile; sed -i '\#^/swapfile #d' /etc/fstab; rm -f /swapfile
elif [[ ! -e /swapfile ]] && ! grep -q '^/swapfile ' /etc/fstab; then
  ok "swap refused by this filesystem and cleaned up"
else
  bad "failed swap left state behind"
fi

# Firewall.
cli self firewall-ensure --allow '10050/tcp@not-an-ip' >/tmp/h-fw-bad 2>&1 && bad "invalid --allow accepted" || ok "invalid --allow rejected"
python3 -m http.server 18080 --bind 0.0.0.0 >/dev/null 2>&1 & srv=$!
for _ in {1..30}; do ss -ltnH | grep -q ':18080 ' && break; sleep 0.5; done
ports=$(bash -c 'source admin/commands/self_host.sh 2>/dev/null; self_firewall_ssh_ports')
[[ "$ports" == 22 ]] && ok "SSH port falls back to 22 without sshd" || bad "ssh ports '${ports}'"
sleep 1
cli self firewall-ensure --allow '10050/tcp@192.0.2.10' >/tmp/h-fw-plan 2>&1
grep -q 'Firewall plan' /tmp/h-fw-plan && grep -q '18080/tcp' /tmp/h-fw-plan && grep -q '10050/tcp from 192.0.2.10' /tmp/h-fw-plan \
  && ok "firewall plan lists exceptions and services it would block" || { bad "firewall plan"; cat /tmp/h-fw-plan; }
kill "$srv" 2>/dev/null
command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active' && bad "plan enabled the firewall" || ok "plan changed nothing"
if cli self firewall-ensure --allow '10050/tcp@192.0.2.10' --confirm yes >/tmp/h-fw 2>&1; then
  st=$(ufw status)
  grep -q 'Status: active' <<<"$st" && grep -qE '^22/tcp +ALLOW' <<<"$st" && grep -qE '^80/tcp +ALLOW' <<<"$st" && grep -qE '^443/tcp +ALLOW' <<<"$st" \
    && grep -qE '^10050/tcp +ALLOW +192\.0\.2\.10' <<<"$st" && ok "firewall active with SSH/HTTP/HTTPS and the exception" || { bad "firewall rules"; echo "$st"; }
  ufw status verbose | grep -q 'deny (incoming)' && ok "incoming denied by default" || bad "default policy"
  cli self firewall-disable --confirm yes >/dev/null 2>&1 && ufw status | grep -q 'Status: inactive' && ok "firewall-disable rolls back" || bad "disable"
else
  bad "firewall-ensure failed"; tail -5 /tmp/h-fw
fi
# Host settings: allowlisted keys only, validated values, one managed block.
cli self setting-set --key SIMAI_EVIL --value x --confirm yes >/dev/null 2>&1 && bad "unknown key accepted" || ok "unknown setting rejected"
cli self setting-set --key SIMAI_SITE_ISOLATION --value 'no;id' --confirm yes >/dev/null 2>&1 && bad "unsafe value accepted" || ok "unsafe value rejected"
cli self setting-set --key SIMAI_SITE_ISOLATION --value no --confirm yes >/tmp/h-set 2>&1 && grep -q '^SIMAI_SITE_ISOLATION=no$' /etc/simai-env.conf \
  && ok "SIMAI_SITE_ISOLATION=no written" || { bad "setting-set"; tail -5 /tmp/h-set; }
cli self setting-set --key SIMAI_LOCK_WAIT --value 30 --confirm yes >/dev/null 2>&1
[[ $(grep -c '^SIMAI_SITE_ISOLATION=' /etc/simai-env.conf) -eq 1 ]] && grep -q '^SIMAI_LOCK_WAIT=30$' /etc/simai-env.conf && ok "settings block keeps both keys" || bad "settings block"
cli self settings 2>&1 | grep -A1 'SIMAI_SITE_ISOLATION' | grep -q 'no —' && ok "self settings shows the value" || bad "settings view"
cli site add --domain shared.test --profile static --confirm yes >/tmp/h-add 2>&1
[[ "$(stat -c %U /home/simai/www/shared.test 2>/dev/null)" == simai ]] && ! getent passwd site-shared-test >/dev/null && ok "new site runs as the shared simai account" || { bad "shared account"; grep -i "runs as" /tmp/h-add; }
cli site remove --domain shared.test --remove-files yes --confirm yes >/dev/null 2>&1
cli self setting-set --key SIMAI_SITE_ISOLATION --value yes --confirm yes >/dev/null 2>&1
# certbot renewals by certbot.timer must reload nginx too.
mkdir -p /etc/letsencrypt/live
cli self migrate --confirm yes >/tmp/h-mig 2>&1
hook=/etc/letsencrypt/renewal-hooks/deploy/simai-reload-nginx
[[ -x $hook ]] && grep -q "reload nginx" $hook && grep -q "certbot reloads nginx" /tmp/h-mig && ok "migrate installs the certbot reload hook" || { bad "certbot hook"; tail -5 /tmp/h-mig; }
sh $hook && ok "reload hook runs" || bad "reload hook failed"
cli self migrate --confirm yes 2>&1 | grep -q "certbot reloads nginx" && bad "hook migration not idempotent" || ok "hook migration is idempotent"
echo "failures=$fails"; exit $fails

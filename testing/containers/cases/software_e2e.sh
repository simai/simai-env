#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Server software: list components and system updates, install Redis and
# Node.js, refuse a Node.js major change under node sites, install security
# updates with a site check; the same through the panel gateway.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
comp() { cli software list --output json 2>/dev/null | js "[c['$2'] for c in d['data']['components'] if c['name']=='$1'][0]"; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain soft.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
apt-get update -qq >/dev/null 2>&1
l=$(cli software list --output json 2>/dev/null)
[[ "$(js 'd["data"]["schema"]' <<<"$l")" == simai-software/1 ]] && ok "software list answers simai-software/1" || bad "software list: ${l:0:300}"
[[ "$(js '[c["key"] for c in d["data"]["components"]]' <<<"$l")" == "['nginx', 'apache', 'certbot', 'fail2ban', 'mysql', 'postgresql', 'redis', 'memcached', 'php', 'node', 'composer', 'git', 'imagemagick', 'jpegoptim', 'optipng', 'ffmpeg', 'supervisor']" ]] && ok "the catalogue lists the programs" || bad "components: ${l:0:300}"
[[ "$(js 'all(set(("title","purpose","group","state","can_install","can_update","can_remove","install_blocked","remove_blocked","keeps","sites")) <= set(c) for c in d["data"]["components"])' <<<"$l")" == True ]] && ok "every program has its state and actions" || bad "fields"
[[ "$(comp nginx remove_blocked)" == *required_by_env* && "$(comp php remove_blocked)" == *managed_elsewhere* && "$(comp mysql can_install)" == False ]] && ok "simai-env's own programs cannot be removed" || bad "protected: $(comp nginx remove_blocked)"
[[ "$(comp php version)" == *"$native"* && "$(comp redis php_extensions)" == *"php${native}-redis"* ]] && ok "PHP versions and their extensions are named" || bad "php: $(comp php version) $(comp redis php_extensions)"
cli software remove --name nginx --confirm yes >/tmp/x 2>&1 && bad "nginx removed" || { dpkg -l nginx | grep -q '^ii' && ok "removing nginx is refused" || bad "nginx gone"; }

# Memcached: install with the PHP extension, then remove keeping its configuration.
[[ "$(comp memcached can_install)" == True && "$(comp memcached group)" == cache ]] && ok "Memcached can be installed" || bad "memcached installable"
cli software install --name memcached --confirm yes >/tmp/m 2>&1 && systemctl is-active --quiet memcached && "php-fpm${native}" -m | grep -qx memcached \
  && [[ "$(comp memcached state)" == running ]] && ok "Memcached is installed and running with php${native}-memcached" || { bad "memcached install"; tail -5 /tmp/m; }
cli software remove --name memcached >/tmp/m 2>&1; grep -q 'configuration and data stay' /tmp/m && dpkg -l memcached | grep -q '^ii' && ok "remove without confirm is a plan" || { bad "remove plan"; tail -3 /tmp/m; }
cli software remove --name memcached --confirm yes >/tmp/m 2>&1 && ! dpkg -l memcached 2>/dev/null | grep -q '^ii' && [[ -f /etc/memcached.conf && "$(comp memcached state)" == not_installed ]] \
  && ok "Memcached is removed and its configuration kept" || { bad "memcached remove"; tail -5 /tmp/m; }
cli software remove --name memcached --confirm yes >/dev/null 2>&1 && bad "removed twice" || ok "removing what is not installed is refused"
cli software install --name jpegoptim --confirm yes >/dev/null 2>&1 && command -v jpegoptim >/dev/null && ok "a tool installs" || bad "jpegoptim"
# Slow apt answers are kept until the package state changes, even outside simai-env.
[[ "$(stat -c %a /var/lib/simai-env/cache/apt 2>/dev/null)" == 700 && -n "$(ls /var/lib/simai-env/cache/apt)" ]] && ok "apt answers are kept, root only" || bad "apt cache: $(ls -ld /var/lib/simai-env/cache/apt 2>&1)"
[[ "$(comp optipng installed)" == False ]] && apt-get install -y -qq optipng >/dev/null 2>&1 && [[ "$(comp optipng installed)" == True ]] \
  && ok "a package installed outside simai-env shows at once" || bad "stale cache: $(comp optipng installed)"
apt-get remove -y -qq optipng >/dev/null 2>&1
[[ "$(js 'type(d["data"]["system"]["updates"]).__name__' <<<"$l")" == int ]] && ok "system updates are counted" || bad "system: ${l:0:300}"

# Redis: a plan first, then the install with the PHP extension.
dpkg -l redis-server 2>/dev/null | grep -q '^ii' && apt-get purge -y -qq redis-server >/dev/null 2>&1
[[ "$(comp redis installable)" == True ]] && ok "Redis can be installed" || bad "redis installable"
cli software install --name redis >/tmp/p 2>&1; grep -q '^Plan:' /tmp/p && ! dpkg -l redis-server 2>/dev/null | grep -q '^ii' && ok "without confirm only a plan" || { bad "redis plan"; tail -3 /tmp/p; }
cli software install --name redis --confirm yes >/tmp/i 2>&1 && systemctl is-active --quiet redis-server && "php-fpm${native}" -m | grep -qx redis \
  && ok "Redis is installed with php${native}-redis" || { bad "redis install"; tail -5 /tmp/i; }
[[ "$(comp redis active)" == True ]] && ok "the list shows Redis running" || bad "redis active"
cli software install --name redis --version 7 --confirm yes >/dev/null 2>&1 && bad "a Redis version was accepted" || ok "Redis takes no version"
cli software install --name mongodb --confirm yes >/dev/null 2>&1 && bad "an unknown component passed" || ok "an unknown component is refused"

# Node.js: one runtime per server, a major change stops at node sites.
if ! command -v node >/dev/null 2>&1; then
  cli software install --name node --version 22 --confirm yes >/tmp/n 2>&1 && node -v | grep -q '^v22\.' && ok "Node.js 22 from NodeSource" || { bad "node install"; tail -5 /tmp/n; }
fi
if command -v node >/dev/null 2>&1; then
  major=$(node -v | sed 's/^v//; s/\..*//')
  cli software install --name node --version "$major" >/tmp/n 2>&1; grep -q 'nothing to do' /tmp/n && ok "the installed major is nothing to do" || { bad "node same"; tail -3 /tmp/n; }
  printf '# simai-profile: node\nserver { listen 80; server_name nodeapp.test; }\n' >/etc/nginx/sites-available/nodeapp.test.conf
  [[ "$(comp node sites)" == "['nodeapp.test']" ]] && ok "the list names node sites" || bad "node sites: $(comp node sites)"
  other=$([[ "$major" == 22 ]] && echo 20 || echo 22)
  cli software install --name node --version "$other" --confirm yes >/tmp/n 2>&1 && bad "changed Node.js under a node site" \
    || { grep -q 'nodeapp.test' /tmp/n && node -v | grep -q "^v${major}\." && ok "a major change names the node site and keeps Node.js ${major}" || bad "node refusal: $(tail -2 /tmp/n)"; }
  cli software remove --name node --confirm yes >/tmp/n 2>&1 && bad "removed Node.js under a node site" \
    || { grep -q 'nodeapp.test' /tmp/n && command -v node >/dev/null && ok "removing Node.js names the node site and keeps it" || bad "node remove: $(tail -2 /tmp/n)"; }
  rm -f /etc/nginx/sites-available/nodeapp.test.conf
fi

# System updates: refresh, plan, security updates with the site check.
cli software refresh --confirm yes >/tmp/r 2>&1 && grep -q 'Security updates' /tmp/r && ok "software refresh" || { bad "refresh"; tail -3 /tmp/r; }
cli software update >/tmp/u 2>&1; grep -q '^Plan:' /tmp/u && ok "software update without confirm is a plan" || { bad "update plan"; tail -3 /tmp/u; }
cli software update --security-only yes --confirm yes >/tmp/u 2>&1 && grep -q 'Stopped answering *| none' /tmp/u && grep -q 'Configuration *| ok' /tmp/u \
  && ok "security updates keep the site answering" || { bad "security update"; tail -8 /tmp/u; }
[[ "$(cli software list --output json 2>/dev/null | js 'd["data"]["system"]["security"]')" == 0 ]] && ok "no security update waits after it" || bad "security left"

# Through the panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
a=$(gate "$(req null software:list '{}')")
[[ "$(js 'd["data"]["schema"]' <<<"$a")" == simai-software/1 ]] && ok "software:list through the gateway" || bad "gate software:list: ${a:0:300}"
[[ "$(gate "$(req '"acme"' software:list '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot list software" || bad "owner software:list"
[[ "$(gate "$(req '"acme"' software:update '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot update the system" || bad "owner software:update"
a=$(gate "$(req null software:update '{"security-only":"yes"}')")
[[ "$(js 'd["kind"]' <<<"$a")" == plan && "$(js '"updates" in d["data"]["update"]' <<<"$a")" == True ]] && ok "software:update plan carries the waiting updates" || bad "update plan: ${a:0:300}"
a=$(gate "$(req null software:remove '{"name":"redis"}')")
[[ "$(js 'd["kind"] == "plan" and d["data"]["software"]["key"] == "redis" and d["data"]["software"]["can_remove"]' <<<"$a")" == True ]] && ok "software:remove plan carries the program" || bad "remove plan: ${a:0:300}"
[[ "$(gate "$(req '"acme"' software:remove '{"name":"redis"}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot remove programs" || bad "owner remove"
[[ "$(gate "$(req null software:install '{"name":"x;id"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "a component name with shell characters is refused" || bad "install validation"
a=$(gate "$(req null software:refresh '{}' 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..120}; do s=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded ]] && ok "software:refresh job" || bad "refresh job: $s"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain soft.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

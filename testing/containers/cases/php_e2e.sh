#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# PHP versions as software of the host: list with sites and updates, install
# another version, turn extensions on and off, update, and remove only a
# version nothing uses; the same through the panel gateway.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain php.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
apt-get update -qq >/dev/null 2>&1
l=$(cli php list --output json 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]))')
[[ "$(js 'd["schema"]' <<<"$l")" == simai-php/1 ]] && ok "php list answers simai-php/1" || bad "php list: ${l:0:300}"
[[ "$(js '"php.test" in [v["sites"] for v in d["versions"] if v["version"]==d["native"]][0]' <<<"$l")" == True ]] && ok "the site is listed on its version" || bad "sites: $l"
[[ "$(js '[v["removable"] for v in d["versions"] if v["version"]==d["native"]][0]' <<<"$l")" == False ]] && ok "the system version is not removable" || bad "native removable"
cli php remove --php "$native" --confirm yes >/tmp/r 2>&1 && bad "removed the system version" || ok "php remove refuses the system version"

# Outdated PHP (1.69.0): 7.4 and 8.0 are allowed where the profile allows
# them, with a note; older versions are refused; JSON marks them outdated.
plan() { cli "$@" --output json 2>/dev/null; }
note='PHP 7.4 is outdated and no longer gets security fixes'
p=$(plan site add --domain old.test --profile generic --php 7.4 --create-db no)
[[ "$(js 'd["status"] == "planned" and any("'"$note"'" in n for n in d["plan_checks"]["notes"])' <<<"$p")" == True ]] && ok "generic with PHP 7.4: planned with the outdated note" || bad "generic 7.4 plan: ${p:0:400}"
p=$(plan site add --domain old.test --profile wordpress --php 8.0 --create-db yes)
[[ "$(js 'd["status"] == "planned" and any("PHP 8.0 is outdated" in n for n in d["plan_checks"]["notes"])' <<<"$p")" == True ]] && ok "wordpress with PHP 8.0: planned with the note" || bad "wordpress 8.0 plan: ${p:0:400}"
p=$(plan site add --domain old.test --profile generic --php 5.6 --create-db no)
[[ "$(js 'd["status"] == "failed" and any("PHP 5.6 is not supported" in n for n in d["plan_checks"]["blockers"])' <<<"$p")" == True ]] && ok "PHP 5.6 is refused in the plan" || bad "5.6 plan: ${p:0:400}"
p=$(plan site add --domain old.test --profile laravel --php 7.4 --create-db yes)
[[ "$(js 'd["status"] == "failed" and any("not allowed for profile laravel" in n for n in d["plan_checks"]["blockers"])' <<<"$p")" == True ]] && ok "laravel with PHP 7.4 is refused in the plan" || bad "laravel 7.4 plan: ${p:0:400}"
p=$(plan site add --domain old.test --profile generic --php "$native" --create-db no)
[[ "$(js 'd["status"] == "planned" and not any("outdated" in n for n in d["plan_checks"]["notes"])' <<<"$p")" == True ]] && ok "a current version has no outdated note" || bad "native plan: ${p:0:400}"
p=$(plan site set-php --domain php.test --php 7.4)
[[ "$(js 'd["status"] == "planned" and any("'"$note"'" in n for n in d["plan_checks"]["notes"])' <<<"$p")" == True ]] && ok "set-php to 7.4: planned with the note" || bad "set-php 7.4 plan: ${p:0:400}"
p=$(plan site set-php --domain php.test --php 5.6)
[[ "$(js 'd["status"] == "failed"' <<<"$p")" == True ]] && ok "set-php to 5.6 is refused in the plan" || bad "set-php 5.6 plan: ${p:0:400}"
p=$(plan php install --php 7.4)
[[ "$(js 'd["status"] == "planned" and any("'"$note"'" in n for n in d["plan_checks"]["notes"])' <<<"$p")" == True ]] && ok "php install 7.4: planned with the note" || bad "php install 7.4 plan: ${p:0:400}"
cli php install --php 5.6 --confirm yes >/tmp/i56 2>&1 && bad "php install 5.6 ran" || { grep -q 'PHP 5.6 is not supported' /tmp/i56 && ! dpkg -l php5.6-fpm 2>/dev/null | grep -q '^ii' && ok "php install 5.6 is refused before apt" || bad "5.6 install: $(tail -2 /tmp/i56)"; }
[[ "$(js 'd["outdated"] == ["7.4", "8.0"] and all(v["outdated"] == (v["version"] in ("7.4", "8.0")) for v in d["versions"]) and "5.6" not in d["installable"]' <<<"$l")" == True ]] && ok "php list marks outdated versions" || bad "php list outdated: ${l:0:400}"
cli php list >/tmp/pl 2>&1; ! grep -q 'outdated' /tmp/pl && ok "php list has no outdated note for current versions" || bad "human list: $(cat /tmp/pl)"
h=$(cli self describe 2>/dev/null)
[[ "$(js '"php_outdated" in d and all(v in d["php_versions"] for v in d["php_outdated"])' <<<"$h")" == True ]] && ok "self describe lists php_outdated" || bad "self describe: ${h:0:300}"
[[ "$(cli site describe --domain php.test 2>/dev/null | js 'd["php_outdated"]')" == False ]] && ok "site describe carries php_outdated" || bad "site describe php_outdated"
pr=$(cli self profiles --output json 2>/dev/null)
[[ "$(js 'd["data"]["php_outdated"] == ["7.4", "8.0"] and {p["id"]: p["php"]["min"] for p in d["data"]["profiles"] if p["php"]} == {"bitrix": "8.2", "generic": "7.4", "laravel": "8.1", "wordpress": "7.4"} and all("outdated" in p["php"] for p in d["data"]["profiles"] if p["php"])' <<<"$pr")" == True ]] && ok "self profiles: bounds 7.4/8.1/8.2 and php_outdated" || bad "self profiles: ${pr:0:600}"

# Extensions: an included one off and on, and one that needs its package.
cli php extension --php "$native" --name calendar --enabled no --confirm yes >/tmp/e 2>&1 && ! "php-fpm${native}" -m | grep -qx calendar && ok "an extension turns off" || { bad "extension off"; tail -3 /tmp/e; }
cli php extension --php "$native" --name calendar --enabled yes --confirm yes >/tmp/e 2>&1 && "php-fpm${native}" -m | grep -qx calendar && ok "and on again" || { bad "extension on"; tail -3 /tmp/e; }
if apt-cache show "php${native}-igbinary" >/dev/null 2>&1; then
  cli php extension --php "$native" --name igbinary --enabled yes --confirm yes >/tmp/e 2>&1 && "php-fpm${native}" -m | grep -qx igbinary && ok "turning on installs the package" || { bad "igbinary"; tail -3 /tmp/e; }
fi
cli php extension --php "$native" --name nosuchext --enabled yes --confirm yes >/tmp/e 2>&1 && bad "an unknown extension passed" || ok "an unknown extension is refused"
cli php extension --php "$native" --name calendar --enabled no >/tmp/e 2>&1; "php-fpm${native}" -m | grep -qx calendar && ok "without confirm only a plan" || bad "plan changed the extension"

# Update: fixes within the version, the site still answers.
cli php update --php "$native" --confirm yes >/tmp/u 2>&1 && grep -q 'Stopped answering *| none' /tmp/u && ok "php update checks the site" || { bad "php update"; tail -5 /tmp/u; }

# Another version: install, a site holds it, remove only when free.
# Another version comes from the apt index, else from ondrej/php when it covers this release.
extra=$(js '(d["installable"] or [""])[-1]' <<<"$l")
if [[ -z "$extra" ]] && bash -c 'source lib/platform.sh; platform_detect_os; platform_ondrej_php_available'; then
  extra=$([[ "$native" == 8.4 ]] && echo 8.3 || echo 8.4)
fi
if [[ -n "$extra" ]]; then
  cli php install --php "$extra" --confirm yes >/tmp/i 2>&1 && [[ -x "/usr/sbin/php-fpm${extra}" ]] && ok "php install ${extra}" || { bad "install ${extra}"; tail -5 /tmp/i; }
  grep -qx 'process_control_timeout = 10s' "/etc/php/${extra}/fpm/php-fpm.conf" && ok "php install ${extra} sets process_control_timeout" || bad "no process_control_timeout after php install ${extra}"
  [[ "$(readlink -f /etc/alternatives/php)" == "/usr/bin/php${native}" ]] && ok "the php command stays on ${native}" || bad "php command moved to $(readlink -f /etc/alternatives/php)"
  cli site set-php --domain php.test --php "$extra" --confirm yes >/dev/null 2>&1
  cli php remove --php "$extra" --confirm yes >/tmp/r 2>&1 && bad "removed a version in use" || { grep -q 'php.test' /tmp/r && ok "php remove names the site that uses it" || bad "remove message: $(tail -2 /tmp/r)"; }
  cli site set-php --domain php.test --php "$native" --confirm yes >/dev/null 2>&1
  [[ "$(cli php list --output json 2>/dev/null | js "[v['removable'] for v in d['data']['versions'] if v['version']=='${extra}'][0]")" == True ]] && ok "a free version is removable" || bad "removable flag"
  cli php remove --php "$extra" --confirm yes >/tmp/r 2>&1 && [[ ! -d "/etc/php/${extra}/fpm" ]] && ! dpkg -l "php${extra}-fpm" 2>/dev/null | grep -q '^ii' && ok "php remove ${extra}" || { bad "remove ${extra}"; tail -5 /tmp/r; }
else
  ok "no other PHP version in the apt index of this release; install and remove not run"
fi

# PHP 7.4 for real where ondrej/php provides it: installs, a generic site
# switches to it, and the JSON marks it outdated.
if [[ -n "$extra" ]] && bash -c 'source lib/platform.sh; platform_detect_os; platform_ondrej_php_available'; then
  if cli php install --php 7.4 --confirm yes >/tmp/i74 2>&1; then
    grep -q "$note" /tmp/i74 && [[ -x /usr/sbin/php-fpm7.4 ]] && ok "php install 7.4 with the note" || bad "install 7.4 note: $(tail -3 /tmp/i74)"
    [[ "$(cli php list --output json 2>/dev/null | js "[v['outdated'] for v in d['data']['versions'] if v['version']=='7.4']")" == "[True]" ]] && ok "php list marks 7.4 outdated" || bad "7.4 row"
    cli php list 2>/dev/null | grep -q '^7\.4 .*outdated, insecure' && ok "human php list says outdated, insecure" || bad "human 7.4 row: $(cli php list 2>&1 | grep '^7.4')"
    cli site set-php --domain php.test --php 7.4 --confirm yes >/tmp/s74 2>&1 && ok "set-php to 7.4" || bad "set-php 7.4: $(tail -3 /tmp/s74)"
    grep -q "$note" /tmp/s74 && ok "set-php to 7.4 names the outdated version" || bad "set-php 7.4 note: $(grep -c . /tmp/s74) lines, $(grep -i 'warn' /tmp/s74 | tail -2)"
    [[ -S /run/php/php7.4-fpm-php-test.sock || -n "$(ls /run/php/php7.4-fpm-*.sock 2>/dev/null)" ]] && systemctl is-active --quiet php7.4-fpm && ok "php7.4-fpm serves the site's pool" || bad "7.4 pool: $(ls /run/php/ 2>&1)"
    [[ "$(cli site describe --domain php.test 2>/dev/null | js 'd["php"] + " " + str(d["php_outdated"])')" == "7.4 True" ]] && ok "site describe: php_outdated true" || bad "site describe 7.4"
    [[ "$(cli self describe 2>/dev/null | js 'd["php_outdated"]')" == "['7.4']" ]] && ok "self describe: php_outdated [7.4]" || bad "self describe 7.4"
    cli site set-php --domain php.test --php "$native" --confirm yes >/dev/null 2>&1
    cli php remove --php 7.4 --confirm yes >/dev/null 2>&1 && ok "php remove 7.4" || bad "remove 7.4"
  elif grep -q 'is not available on' /tmp/i74; then
    ok "PHP 7.4 is not provided for this release; refused with a clear message"
  else
    bad "install 7.4: $(tail -5 /tmp/i74)"
  fi
fi

# Reloads let busy workers finish: process_control_timeout in [global] (before
# the pool include), from self migrate on existing hosts and from php install.
fpmconf="/etc/php/${native}/fpm/php-fpm.conf"
pct_ok() { awk '/^include=/{exit} /^process_control_timeout = 10s$/{f=1} END{exit !f}' "$fpmconf"; }
sed -i '/^; simai-env: let busy workers/d;/^process_control_timeout/d' "$fpmconf"
cli self migrate >/tmp/m1 2>&1
pct_ok && "php-fpm${native}" -t >/dev/null 2>&1 && grep -q 'process_control_timeout' /tmp/m1 && ok "self migrate sets process_control_timeout in [global]" || { bad "self migrate process_control_timeout"; grep -n process_control "$fpmconf"; tail -5 /tmp/m1; }
sum1=$(md5sum "$fpmconf"); cli self migrate >/tmp/m2 2>&1
[[ "$(md5sum "$fpmconf")" == "$sum1" ]] && ! grep -q 'process_control_timeout' /tmp/m2 && ok "second self migrate leaves php-fpm.conf alone" || { bad "second migrate changed php-fpm.conf"; tail -5 /tmp/m2; }
sed -i '/^; simai-env: let busy workers/d;/^process_control_timeout/d' "$fpmconf"
cli php install --php "$native" --confirm yes >/tmp/i0 2>&1 && pct_ok && ok "php install of an installed version sets process_control_timeout" || { bad "php install process_control_timeout"; tail -5 /tmp/i0; }
sed -i 's/^process_control_timeout = 10s$/process_control_timeout = 30s/' "$fpmconf"
cli self migrate >/dev/null 2>&1; grep -qx 'process_control_timeout = 30s' "$fpmconf" && ok "an administrator's process_control_timeout stays" || bad "custom process_control_timeout replaced"
sed -i 's/^process_control_timeout = 30s$/process_control_timeout = 10s/' "$fpmconf"

# Bitrix host baseline: OPcache memory and realpath cache per PHP version, in
# one file that loads last and never lowers what other ini files set.
opc="/etc/php/${native}/fpm/conf.d/99-zz-simai-opcache.ini"
fpmi() { "php-fpm${native}" -i | awk -F' => ' -v k="$1" '$1==k{print $2; exit}'; }
printf 'opcache.memory_consumption=128\n' >"/etc/php/${native}/fpm/conf.d/99-simai-performance.ini"
cli site add --domain bx.test --profile bitrix --php "$native" --create-db yes --confirm yes >/tmp/bx 2>&1 || { bad "bitrix site add"; tail -5 /tmp/bx; }
grep -qx 'opcache.memory_consumption=256' "$opc" && grep -qx 'opcache.interned_strings_buffer=16' "$opc" \
  && grep -qx 'opcache.max_accelerated_files=20000' "$opc" && grep -qx 'realpath_cache_ttl=600' "$opc" \
  && ok "a Bitrix site writes the OPcache baseline" || { bad "opcache baseline file"; cat "$opc"; }
[[ "$(fpmi opcache.memory_consumption)/$(fpmi opcache.interned_strings_buffer)/$(fpmi opcache.max_accelerated_files)/$(fpmi realpath_cache_ttl)" == 256/16/20000/600 ]] \
  && ok "PHP-FPM sees the baseline over the performance preset" || bad "fpm values: $(fpmi opcache.memory_consumption) $(fpmi realpath_cache_ttl)"
cli site doctor --domain bx.test >/tmp/doc 2>&1 || true
w=$(grep -E '^\[WARN\].*(opcache\.memory_consumption|opcache\.interned_strings_buffer|opcache\.max_accelerated_files|realpath_cache_ttl)' /tmp/doc || true)
[[ -z "$w" ]] && grep -q '^\[PASS\] INI recommended — opcache.memory_consumption=256' /tmp/doc && ok "site doctor passes the OPcache checks" || { bad "doctor opcache"; echo "$w"; grep 'INI recommended' /tmp/doc; }
sum2=$(md5sum "$opc"); cli bitrix php-baseline-sync --domain bx.test --confirm yes >/tmp/bs 2>&1 || { bad "php-baseline-sync"; tail -5 /tmp/bs; }
cli self migrate >/tmp/m3 2>&1
[[ "$(md5sum "$opc")" == "$sum2" ]] && ! grep -q 'OPcache baseline' /tmp/m3 && ! grep -q 'OPcache baseline written' /tmp/bs && ok "a second run changes nothing" || { bad "second run changed the baseline"; tail -3 /tmp/bs; tail -3 /tmp/m3; }
rm -f "/etc/php/${native}/fpm/conf.d/99-simai-performance.ini"
printf 'opcache.memory_consumption=512\n' >"/etc/php/${native}/fpm/conf.d/95-admin.ini"
cli bitrix php-baseline-sync --domain bx.test --confirm yes >/dev/null 2>&1
grep -qx 'opcache.memory_consumption=512' "$opc" && [[ "$(fpmi opcache.memory_consumption)" == 512 ]] && ok "a higher value set by the administrator stays" || bad "baseline lowered: $(grep memory "$opc")"
rm -f "/etc/php/${native}/fpm/conf.d/95-admin.ini"
cli bitrix php-baseline-sync --domain bx.test --confirm yes >/dev/null 2>&1
grep -qx 'opcache.memory_consumption=256' "$opc" && ok "and the baseline returns when it is gone" || bad "baseline after removal: $(grep memory "$opc")"
rm -f "$opc"; cli self migrate >/tmp/m4 2>&1
[[ -f "$opc" ]] && grep -q 'OPcache baseline' /tmp/m4 && ok "self migrate writes the baseline for an existing Bitrix site" || { bad "migrate opcache"; tail -5 /tmp/m4; }
cli site remove --domain bx.test --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1

# Through the panel gateway: administrator only.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
a=$(gate "$(req null php:list '{}')")
[[ "$(js 'd["data"]["schema"]' <<<"$a")" == simai-php/1 ]] && ok "php:list through the gateway" || bad "gate php:list: ${a:0:300}"
[[ "$(gate "$(req '"acme"' php:list '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot list PHP versions" || bad "owner php:list"
[[ "$(gate "$(req '"acme"' php:install '{"php":"8.4"}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot install PHP" || bad "owner php:install"
[[ "$(gate "$(req null php:remove "{\"php\":\"${native}\"}")" | js 'd["kind"]')" == plan ]] && ok "php:remove answers a plan" || bad "remove plan"
[[ "$(gate "$(req null php:extension "{\"php\":\"${native}\",\"name\":\"x;id\",\"enabled\":\"yes\"}")" | js 'd["reason"]')" == invalid_argument ]] && ok "an extension name with shell characters is refused" || bad "ext validation"
a=$(gate "$(req null php:extension "{\"php\":\"${native}\",\"name\":\"calendar\",\"enabled\":\"no\"}" 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..60}; do s=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded ]] && ! "php-fpm${native}" -m | grep -qx calendar && ok "php:extension job" || bad "extension job: $s"
cli php extension --php "$native" --name calendar --enabled yes --confirm yes >/dev/null 2>&1

# Outdated PHP in gateway plans: the php row is marked, the note is there.
a=$(gate '{"schema":"simai-panel-request/1","request_id":"r2","lang":"ru","actor":{"user":"admin@x","owner":null},"command":"site:set-php","args":{"domain":"php.test","php":"7.4"}}')
[[ "$(js '[r["outdated"] for r in d["data"]["display"] if r["key"] == "php"] == [True] and [r["words"] for r in d["data"]["display"] if r["key"] == "php"] == ["7.4 (устаревшая, небезопасная)"] and any("'"$note"'" in n for n in d["data"]["checks"]["notes"])' <<<"$a")" == True ]] && ok "gateway set-php plan marks PHP 7.4 outdated" || bad "gate set-php 7.4: ${a:0:600}"
a=$(gate "$(req null site:set-php "{\"domain\":\"php.test\",\"php\":\"${native}\"}")")
[[ "$(js '[r["outdated"] for r in d["data"]["display"] if r["key"] == "php"]' <<<"$a")" == "[False]" ]] && ok "a current version is not marked" || bad "gate set-php native: ${a:0:400}"
a=$(gate "$(req null site:add '{"domain":"old.test","profile":"generic","php":"5.6","create-db":"no"}')")
[[ "$(js 'd.get("kind") != "plan" or bool((d.get("data") or {}).get("failed"))' <<<"$a")" == True ]] && ok "gateway site:add with PHP 5.6 is not a plan" || bad "gate 5.6: ${a:0:400}"
cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain php.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

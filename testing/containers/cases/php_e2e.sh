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
[[ "$(js '[v["sites"] for v in d["versions"] if v["version"]==d["native"]][0]' <<<"$l")" == "['php.test']" ]] && ok "the site is listed on its version" || bad "sites: $l"
[[ "$(js '[v["removable"] for v in d["versions"] if v["version"]==d["native"]][0]' <<<"$l")" == False ]] && ok "the system version is not removable" || bad "native removable"
cli php remove --php "$native" --confirm yes >/tmp/r 2>&1 && bad "removed the system version" || ok "php remove refuses the system version"

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
  [[ "$(readlink -f /etc/alternatives/php)" == "/usr/bin/php${native}" ]] && ok "the php command stays on ${native}" || bad "php command moved to $(readlink -f /etc/alternatives/php)"
  cli site set-php --domain php.test --php "$extra" --confirm yes >/dev/null 2>&1
  cli php remove --php "$extra" --confirm yes >/tmp/r 2>&1 && bad "removed a version in use" || { grep -q 'php.test' /tmp/r && ok "php remove names the site that uses it" || bad "remove message: $(tail -2 /tmp/r)"; }
  cli site set-php --domain php.test --php "$native" --confirm yes >/dev/null 2>&1
  [[ "$(cli php list --output json 2>/dev/null | js "[v['removable'] for v in d['data']['versions'] if v['version']=='${extra}'][0]")" == True ]] && ok "a free version is removable" || bad "removable flag"
  cli php remove --php "$extra" --confirm yes >/tmp/r 2>&1 && [[ ! -d "/etc/php/${extra}/fpm" ]] && ! dpkg -l "php${extra}-fpm" 2>/dev/null | grep -q '^ii' && ok "php remove ${extra}" || { bad "remove ${extra}"; tail -5 /tmp/r; }
else
  ok "no other PHP version in the apt index of this release; install and remove not run"
fi

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

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain php.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))

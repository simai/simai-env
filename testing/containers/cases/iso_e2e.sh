#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
# Runs inside the systemd container. Real site add/isolate/remove + HTTP probes.
set -uo pipefail
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { local arg; for arg; do if [[ "$arg" == --confirm || "$arg" == --confirm=* ]]; then ./simai-admin.sh "$@"; return; fi; done; ./simai-admin.sh "$@" --confirm yes; }
http() { curl -s -H "Host: $1" "http://127.0.0.1$2"; }

add_site() {
  local d="$1"; shift
  if ! cli site add --domain "$d" --profile generic --php 8.3 --create-db no "$@" >/tmp/add.$d 2>&1; then
    bad "site add $d"; tail -25 /tmp/add.$d; return 1
  fi
  ok "site add $d"
}

SIMAI_SITE_ISOLATION=no add_site legacy.test
add_site alpha.test
add_site beta.test

ua=$(cat /etc/simai-env/site-users/alpha-test 2>/dev/null); ub=$(cat /etc/simai-env/site-users/beta-test 2>/dev/null)
[[ "$ua" == site-alpha-test && "$ub" == site-beta-test ]] && ok "registry has site users ($ua, $ub)" || bad "registry: '$ua' '$ub'"
[[ ! -e /etc/simai-env/site-users/legacy-test ]] && ok "legacy site stays on shared user" || bad "legacy registered"
grep -q '^user = site-alpha-test' /etc/php/8.3/fpm/pool.d/alpha-test.conf && ok "alpha pool runs as site-alpha-test" || bad "alpha pool user"
grep -q '^user = simai' /etc/php/8.3/fpm/pool.d/legacy-test.conf && ok "legacy pool runs as simai" || bad "legacy pool user"
A=/home/simai/www/alpha.test; B=/home/simai/www/beta.test; L=/home/simai/www/legacy.test
[[ "$(stat -c '%U:%G %a' "$A")" == "site-alpha-test:site-alpha-test 750" ]] && ok "alpha root owned by its user, 0750" || bad "alpha root: $(stat -c '%U:%G %a' "$A")"
id -nG www-data | grep -qw site-alpha-test && ok "www-data in site group" || bad "www-data groups: $(id -nG www-data)"

probe='<?php
header("Content-Type: text/plain");
echo "user=", posix_getpwuid(posix_geteuid())["name"], "\n";
foreach (explode(",", $_GET["f"] ?? "") as $f) { if ($f === "") continue; echo $f, "=", (@file_get_contents($f) === false ? "DENIED" : "READ"), "\n"; }'
for s in alpha beta legacy; do
  d=/home/simai/www/$s.test
  printf '%s' "$probe" >"$d/public/probe.php"; echo "secret-$s" >"$d/secret.txt"
  o=$(stat -c '%U:%G' "$d"); chown "$o" "$d/public/probe.php" "$d/secret.txt"; chmod 0644 "$d/secret.txt"
done
out=$(http alpha.test "/probe.php?f=$A/secret.txt,$B/secret.txt,$L/secret.txt")
echo "$out" | grep -q '^user=site-alpha-test' && ok "alpha PHP runs as site-alpha-test" || bad "alpha probe: $out"
echo "$out" | grep -q "$A/secret.txt=READ" && ok "alpha reads its own files" || bad "alpha own read"
echo "$out" | grep -q "$B/secret.txt=DENIED" && ok "alpha cannot read beta" || bad "alpha read beta!"
out=$(http legacy.test "/probe.php?f=$A/secret.txt,$B/secret.txt")
echo "$out" | grep -q '^user=simai' && ok "legacy PHP runs as simai" || bad "legacy probe: $out"
echo "$out" | grep -q "$A/secret.txt=DENIED" && ok "legacy cannot read isolated alpha" || bad "legacy read alpha!"
[[ "$(http alpha.test /index.php | head -c 200)" != "" ]] && ok "alpha index served" || bad "alpha index empty"

# Site-scoped command runs as the site user (dispatcher context).
cli site php-ini set --domain alpha.test --name memory_limit --value 256M >/tmp/ini 2>&1 || true
grep -q '^user = site-alpha-test' /etc/php/8.3/fpm/pool.d/alpha-test.conf && ok "pool user survives php-ini change" || bad "pool user reset by php-ini"

# Migrate legacy.
bash ./simai-admin.sh site isolate --domain legacy.test >/tmp/plan 2>&1; grep -q 'Rerun with --confirm yes' /tmp/plan && ok "isolate prints plan" || bad "isolate plan"
cli site isolate --domain legacy.test --confirm yes >/tmp/iso 2>&1 && ok "site isolate legacy.test" || { bad "isolate"; tail -20 /tmp/iso; }
sleep 1
out=$(http legacy.test "/probe.php?f=$L/secret.txt,$A/secret.txt")
echo "$out" | grep -q '^user=site-legacy-test' && ok "migrated site runs as its own user" || bad "migrated probe: $out"
echo "$out" | grep -q "$L/secret.txt=READ" && ok "migrated site reads its files" || bad "migrated own read: $out"
out=$(http alpha.test "/probe.php?f=$L/secret.txt")
echo "$out" | grep -q "=DENIED" && ok "alpha cannot read migrated site" || bad "alpha reads migrated: $out"
cli site isolate --domain legacy.test --confirm yes 2>&1 | grep -q 'already runs as' && ok "isolate is idempotent" || bad "isolate not idempotent"

# Remove with files deletes the site user.
cli site remove --domain beta.test --remove-files yes --confirm yes >/tmp/rm 2>&1 || { bad "site remove"; tail -15 /tmp/rm; }
id site-beta-test >/dev/null 2>&1 && bad "site user left after remove" || ok "site user removed with site"
[[ ! -e /etc/simai-env/site-users/beta-test ]] && ok "registry entry removed" || bad "registry left"

# Rollback: failing isolate restores ownership.
SIMAI_SITE_ISOLATION=no add_site gamma.test
G=/home/simai/www/gamma.test
chattr +i "$G/public/index.php" 2>/dev/null && immutable=1 || immutable=0
if [[ $immutable -eq 1 ]]; then
  cli site isolate --domain gamma.test --confirm yes >/tmp/iso2 2>&1 && bad "isolate succeeded despite failure" || ok "isolate fails cleanly"
  chattr -i "$G/public/index.php"
  [[ "$(stat -c %U "$G")" == simai ]] && ok "rollback restored ownership" || bad "rollback owner $(stat -c %U "$G")"
  id site-gamma-test >/dev/null 2>&1 && bad "rollback left site user" || ok "rollback removed site user"
  grep -q '^user = simai' /etc/php/8.3/fpm/pool.d/gamma-test.conf && ok "rollback kept pool on simai" || bad "rollback pool"
else
  echo "SKIP rollback (chattr unavailable)"
fi

echo "failures=${fails}"
exit "$fails"

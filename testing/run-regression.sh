#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/testing/test-config.env"
MODE="${1:-smoke}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing ${CONFIG_FILE}. Copy testing/test-config.example.env first." >&2
  exit 1
fi

USER_TEST_SYNC_UPDATE="${TEST_SYNC_UPDATE:-}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
if [[ -n "$USER_TEST_SYNC_UPDATE" ]]; then
  TEST_SYNC_UPDATE="$USER_TEST_SYNC_UPDATE"
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required config variable: ${name}" >&2
    exit 1
  fi
}

require_var "TEST_SERVER_HOST"
require_var "TEST_SERVER_USER"

SSH_TARGET="${TEST_SERVER_USER}@${TEST_SERVER_HOST}"
SIMAI_ROOT="${TEST_SIMAI_ROOT:-/root/simai-env}"

_test_domain=""
_wp_test_domain=""
_bitrix_test_domain=""
_test_db_name=""
_test_db_user=""
_wp_db_name=""
_wp_db_user=""
_bitrix_db_name=""
_bitrix_db_user=""
_feat_domain=""
_feat_db_name=""
_feat_db_user=""
_iso_domain=""
_feat_owner=""

# One multiplexed connection for the whole run: fewer handshakes, and no
# burst of logins for fail2ban to throttle.
SSH_CONTROL_PATH="/tmp/simai-rg-%C"  # unix socket paths are limited to ~104 bytes
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15
  -o ControlMaster=auto -o "ControlPath=${SSH_CONTROL_PATH}" -o ControlPersist=120)
# Interactive menu probes need their own TTY session, not the shared one.
SSH_TTY_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlPath=none)

remote() {
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
}

run_cmd() {
  local title="$1"
  shift
  echo "[run] ${title}"
  remote "cd '${SIMAI_ROOT}' && $*"
}

run_cmd_expect_fail() {
  local title="$1"
  shift
  echo "[run] ${title} (expect fail)"
  if remote "cd '${SIMAI_ROOT}' && $* >/dev/null 2>&1"; then
    echo "[fail] ${title}: command unexpectedly succeeded" >&2
    exit 1
  fi
}

run_menu_case() {
  local title="$1"
  local payload="$2"
  local expected="$3"
  echo "[run] ${title}"
  local output=""
  output=$(
    ssh -tt "${SSH_TTY_OPTS[@]}" "$SSH_TARGET" \
      "cd '${SIMAI_ROOT}' && SIMAI_MENU_BACKEND=text timeout 45 ./simai-admin.sh menu" \
      <<<"$payload" 2>&1 || true
  )
  if ! grep -Fq -- "$expected" <<<"$output"; then
    echo "[fail] ${title}: expected '${expected}'" >&2
    echo "---- menu output ----" >&2
    echo "$output" >&2
    echo "---------------------" >&2
    exit 1
  fi
}

capture_db_identity() {
  local domain="$1"
  remote "set -a; source '/etc/simai-env/sites/${domain}/db.env'; set +a; printf '%s %s\\n' \"\$DB_NAME\" \"\$DB_USER\""
}

assert_remote_site_absent() {
  local domain="$1" db_name="${2:-}" db_user="${3:-}"
  local project="${domain//./-}"
  if ! remote "set -e; test ! -e '/etc/nginx/sites-available/${domain}.conf'; test ! -e '/etc/nginx/sites-enabled/${domain}.conf'; test ! -e '/home/simai/www/${domain}'; test ! -e '/etc/simai-env/sites/${domain}'; test ! -e '/etc/cron.d/${project}'; test ! -e '/etc/systemd/system/laravel-queue-${project}.service'; ! find /etc/php -path '*/pool.d/${project}.conf' -print -quit | grep -q .; ! find /etc/nginx/sites-available /root/simai-backups /tmp -maxdepth 2 -name '*${domain}*' -print -quit | grep -q .; [[ -z '${db_name}' ]] || [[ \$(mysql -NBe \"SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db_name}'\" 2>/dev/null) -eq 0 ]]; [[ -z '${db_user}' ]] || [[ \$(mysql -NBe \"SELECT COUNT(*) FROM mysql.user WHERE User='${db_user}'\" 2>/dev/null) -eq 0 ]]"; then
    echo "[fail] cleanup residue remains for ${domain}" >&2
    return 1
  fi
}

cleanup_one() {
  local domain="$1" db_name="${2:-}" db_user="${3:-}" failed=0
  [[ -n "$domain" ]] || return 0
  echo "[cleanup] ${domain}"
  remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site db-drop --domain '${domain}' --remove_files yes --confirm yes >/dev/null 2>&1 || true" || failed=1
  remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site remove --domain '${domain}' --remove-files yes --confirm yes >/dev/null 2>&1 || true" || failed=1
  remote "rm -f -- /root/simai-backups/'${domain}'-regression.tar.gz /root/simai-backups/'${domain}'-negative-base.tar.gz /root/simai-backups/'${domain}'-negative-unknown-profile.tar.gz /root/simai-backups/'${domain}'-negative-phpnone.tar.gz /etc/nginx/sites-available/'${domain}'.conf.bak.* /etc/nginx/sites-available/'${domain}'.conf.failed.*; rm -rf -- /tmp/simai-neg-unknown-'${domain}' /tmp/simai-neg-phpnone-'${domain}'" || failed=1
  assert_remote_site_absent "$domain" "$db_name" "$db_user" || failed=1
  return "$failed"
}

cleanup() {
  local failed=0
  cleanup_one "${_test_domain:-}" "${_test_db_name:-}" "${_test_db_user:-}" || failed=1
  cleanup_one "${_wp_test_domain:-}" "${_wp_db_name:-}" "${_wp_db_user:-}" || failed=1
  cleanup_one "${_bitrix_test_domain:-}" "${_bitrix_db_name:-}" "${_bitrix_db_user:-}" || failed=1
  cleanup_one "${_feat_domain:-}" "${_feat_db_name:-}" "${_feat_db_user:-}" || failed=1
  cleanup_one "${_iso_domain:-}" || failed=1
  if [[ -n "${_feat_owner:-}" ]]; then
    echo "[cleanup] owner ${_feat_owner}"
    remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh owner remove --name '${_feat_owner}' --confirm yes >/dev/null 2>&1 || true; rm -rf /root/simai-regression-backups" || failed=1
    remote "! id '${_feat_owner}' >/dev/null 2>&1" || { echo "[fail] owner ${_feat_owner} remains" >&2; failed=1; }
  fi
  return "$failed"
}

cleanup_on_exit() {
  local rc=$?
  trap - EXIT
  cleanup || rc=1
  exit "$rc"
}

trap cleanup_on_exit EXIT

run_smoke() {
  if [[ "${TEST_SYNC_UPDATE:-no}" == "yes" ]]; then
    run_cmd "self update (sync test host)" "SIMAI_UPDATE_SMOKE_STRICT=yes ./simai-admin.sh self update >/dev/null"
  fi
  run_cmd "self status" "./simai-admin.sh self status >/dev/null"
  run_cmd "self platform-status" "./simai-admin.sh self platform-status >/dev/null"
  run_cmd "db status" "./simai-admin.sh db status >/dev/null"
  run_cmd "site list" "./simai-admin.sh site list >/dev/null"
  run_cmd "ssl list" "./simai-admin.sh ssl list >/dev/null"
  run_cmd "profile validate" "./simai-admin.sh profile validate >/dev/null"
}

run_core() {
  [[ "${ALLOW_DESTRUCTIVE_TESTS:-no}" == "yes" ]] || { echo "Set ALLOW_DESTRUCTIVE_TESTS=yes for core tests" >&2; exit 1; }
  [[ "${AUTO_CLEANUP_TEST_SITES:-no}" == "yes" ]] || { echo "Set AUTO_CLEANUP_TEST_SITES=yes for core tests" >&2; exit 1; }
  local suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
  local stamp
  stamp="$(date +%y%m%d-%H%M%S)"
  _test_domain="t-core-${stamp}${suffix}"

  run_cmd "site add (generic + db)" "./simai-admin.sh site add --domain '${_test_domain}' --profile generic --php 8.2 --db yes >/dev/null"
  read -r _test_db_name _test_db_user < <(capture_db_identity "${_test_domain}")
  run_cmd "site info" "./simai-admin.sh site info --domain '${_test_domain}' >/dev/null"
  run_cmd "site db-status" "./simai-admin.sh site db-status --domain '${_test_domain}' >/dev/null"
  run_cmd "site db-export" "./simai-admin.sh site db-export --domain '${_test_domain}' --confirm yes >/dev/null"
  run_cmd "site db-rotate" "./simai-admin.sh site db-rotate --domain '${_test_domain}' --confirm yes >/dev/null"
  local backup_file="/root/simai-backups/${_test_domain}-regression.tar.gz"
  run_cmd "backup export" "./simai-admin.sh backup export --domain '${_test_domain}' --out '${backup_file}' >/dev/null"
  run_cmd "backup inspect" "./simai-admin.sh backup inspect --file '${backup_file}' >/dev/null"
  run_cmd "backup import plan" "./simai-admin.sh backup import --file '${backup_file}' --apply no >/dev/null"

  local wp_suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
  local wp_stamp
  wp_stamp="$(date +%y%m%d-%H%M%S)"
  _wp_test_domain="t-wp-${wp_stamp}${wp_suffix}"
  run_cmd "site add (wordpress + db)" "./simai-admin.sh site add --domain '${_wp_test_domain}' --profile wordpress --php 8.2 --db yes >/dev/null"
  read -r _wp_db_name _wp_db_user < <(capture_db_identity "${_wp_test_domain}")
  run_cmd "wp status" "./simai-admin.sh wp status --domain '${_wp_test_domain}' >/dev/null"
  run_cmd "wp cron-status" "./simai-admin.sh wp cron-status --domain '${_wp_test_domain}' >/dev/null"
  run_cmd "wp cron-sync" "./simai-admin.sh wp cron-sync --domain '${_wp_test_domain}' >/dev/null"

  local bx_suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
  local bx_stamp
  bx_stamp="$(date +%y%m%d-%H%M%S)"
  _bitrix_test_domain="t-bitrix-${bx_stamp}${bx_suffix}"
  run_cmd "site add (bitrix + db)" "./simai-admin.sh site add --domain '${_bitrix_test_domain}' --profile bitrix --php 8.2 --db yes >/dev/null"
  read -r _bitrix_db_name _bitrix_db_user < <(capture_db_identity "${_bitrix_test_domain}")
  run_cmd "bitrix status" "./simai-admin.sh bitrix status --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix cron-status" "./simai-admin.sh bitrix cron-status --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix cron-sync" "./simai-admin.sh bitrix cron-sync --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix agents-status" "./simai-admin.sh bitrix agents-status --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix agents-sync plan" "./simai-admin.sh bitrix agents-sync --domain '${_bitrix_test_domain}' >/dev/null"
}

run_menu() {
  run_menu_case "menu site info cancel" $'1\n3\n0\n\n0\n0\n' "---- done (site info), exit=89 ----"
  run_menu_case "menu ssl status cancel" $'2\n2\n0\n\n0\n0\n' "---- done (ssl status), exit=89 ----"
  run_menu_case "menu site remove cancel" $'1\n10\n0\n\n0\n0\n' "---- done (site remove), exit=89 ----"
  run_menu_case "menu backup inspect cancel" $'8\n2\n0\n\n0\n0\n' "---- done (backup inspect), command_exit=not_started ----"
  run_menu_case "menu access pre-dispatch cancel" $'5\n3\n0\n\n0\n0\n' "---- done (access create-project), command_exit=not_started ----"
}

run_backend() {
  if ! remote "command -v whiptail >/dev/null 2>&1"; then
    echo "[skip] backend whiptail probe (whiptail not installed)"
    return 0
  fi
  echo "[run] backend whiptail probe"
  local output=""
  output=$(
    ssh -tt "${SSH_TTY_OPTS[@]}" "$SSH_TARGET" \
      "cd '${SIMAI_ROOT}' && SIMAI_MENU_BACKEND=whiptail timeout 8 ./simai-admin.sh menu" \
      <<<"" 2>&1 || true
  )
  if ! grep -Fq -- "Menu backend: whiptail" <<<"$output"; then
    echo "[fail] backend probe: whiptail backend marker not found" >&2
    echo "---- menu output ----" >&2
    echo "$output" >&2
    echo "---------------------" >&2
    exit 1
  fi
  if grep -Fq -- "Select section:" <<<"$output"; then
    echo "[fail] backend probe: text fallback detected while whiptail backend requested" >&2
    echo "---- menu output ----" >&2
    echo "$output" >&2
    echo "---------------------" >&2
    exit 1
  fi
}

run_negative() {
  [[ "${ALLOW_DESTRUCTIVE_TESTS:-no}" == "yes" ]] || { echo "Set ALLOW_DESTRUCTIVE_TESTS=yes for negative tests" >&2; exit 1; }
  [[ "${AUTO_CLEANUP_TEST_SITES:-no}" == "yes" ]] || { echo "Set AUTO_CLEANUP_TEST_SITES=yes for negative tests" >&2; exit 1; }
  if [[ -z "${_test_domain:-}" ]]; then
    local suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
    local stamp
    stamp="$(date +%y%m%d-%H%M%S)"
    _test_domain="t-neg-${stamp}${suffix}"
    run_cmd "site add (negative fixture)" "./simai-admin.sh site add --domain '${_test_domain}' --profile generic --php 8.2 --db no >/dev/null"
  fi

  local backup_base="/root/simai-backups/${_test_domain}-negative-base.tar.gz"
  local backup_unknown="/root/simai-backups/${_test_domain}-negative-unknown-profile.tar.gz"
  local backup_phpnone="/root/simai-backups/${_test_domain}-negative-phpnone.tar.gz"
  local tmp_unknown="/tmp/simai-neg-unknown-${_test_domain}"
  local tmp_phpnone="/tmp/simai-neg-phpnone-${_test_domain}"
  run_cmd "backup export (negative fixture)" "./simai-admin.sh backup export --domain '${_test_domain}' --out '${backup_base}' >/dev/null"
  run_cmd "prepare backup (unknown profile)" "rm -rf '${tmp_unknown}' && mkdir -p '${tmp_unknown}' && tar -xzf '${backup_base}' -C '${tmp_unknown}' && python3 -c \"import json; p='${tmp_unknown}/manifest.json'; d=json.load(open(p)); d['profile']='missing-profile'; open(p,'w').write(json.dumps(d,ensure_ascii=False,indent=2)+'\\\\n')\" && tar -czf '${backup_unknown}' -C '${tmp_unknown}' ."
  run_cmd "prepare backup (php none mismatch)" "rm -rf '${tmp_phpnone}' && mkdir -p '${tmp_phpnone}' && tar -xzf '${backup_base}' -C '${tmp_phpnone}' && python3 -c \"import json; p='${tmp_phpnone}/manifest.json'; d=json.load(open(p)); d['profile']='generic'; d['php']='none'; open(p,'w').write(json.dumps(d,ensure_ascii=False,indent=2)+'\\\\n')\" && tar -czf '${backup_phpnone}' -C '${tmp_phpnone}' ."

  run_cmd_expect_fail "site info missing domain" "./simai-admin.sh site info --domain does-not-exist-zzz.env.sf8.ru"
  run_cmd_expect_fail "ssl status missing domain" "./simai-admin.sh ssl status --domain does-not-exist-zzz.env.sf8.ru"
  if [[ -n "${_test_domain:-}" ]]; then
    run_cmd_expect_fail "wp status on non-wordpress profile" "./simai-admin.sh wp status --domain '${_test_domain}'"
    run_cmd_expect_fail "bitrix status on non-bitrix profile" "./simai-admin.sh bitrix status --domain '${_test_domain}'"
    run_cmd_expect_fail "bitrix agents-status on non-bitrix profile" "./simai-admin.sh bitrix agents-status --domain '${_test_domain}'"
  fi
  run_cmd_expect_fail "backup inspect missing file" "./simai-admin.sh backup inspect --file /root/simai-backups/does-not-exist-zzz.tar.gz"
  run_cmd_expect_fail "backup import apply unknown profile" "./simai-admin.sh backup import --file '${backup_unknown}' --apply yes --enable no --reload no"
  run_cmd_expect_fail "backup import apply php none mismatch" "./simai-admin.sh backup import --file '${backup_phpnone}' --apply yes --enable no --reload no"
  if [[ -n "${_test_domain:-}" ]]; then
    run_cmd_expect_fail "ssl install broken cert path" "./simai-admin.sh ssl install --domain '${_test_domain}' --cert /root/test-certs/does-not-exist.crt --key /root/test-certs/does-not-exist.key"
  fi
}

# Site isolation, owners, data backups and host migrations.
run_features() {
  [[ "${ALLOW_DESTRUCTIVE_TESTS:-no}" == "yes" ]] || { echo "Set ALLOW_DESTRUCTIVE_TESTS=yes for feature tests" >&2; exit 1; }
  [[ "${AUTO_CLEANUP_TEST_SITES:-no}" == "yes" ]] || { echo "Set AUTO_CLEANUP_TEST_SITES=yes for feature tests" >&2; exit 1; }
  local suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}" stamp
  stamp="$(date +%y%m%d-%H%M%S)"
  _feat_owner="rt-${stamp}"
  _feat_domain="t-feat-${stamp}${suffix}"
  _iso_domain="t-iso-${stamp}${suffix}"
  local feat_project="${_feat_domain//./-}" iso_project="${_iso_domain//./-}"

  run_cmd "owner create" "./simai-admin.sh owner create --name '${_feat_owner}' >/dev/null"
  run_cmd "site add (generic + db, owner)" "./simai-admin.sh site add --domain '${_feat_domain}' --profile generic --php 8.2 --db yes --owner '${_feat_owner}' >/dev/null"
  read -r _feat_db_name _feat_db_user < <(capture_db_identity "${_feat_domain}")
  run_cmd "owner site pool runs as owner" "grep -q '^user = ${_feat_owner}\$' /etc/php/8.2/fpm/pool.d/${feat_project}.conf"
  run_cmd "site info shows owner" "./simai-admin.sh site info --domain '${_feat_domain}' 2>&1 | grep -A1 'Runs as' | grep -q '${_feat_owner}'"
  run_cmd "site add (isolated, no owner)" "./simai-admin.sh site add --domain '${_iso_domain}' --profile generic --php 8.2 --db no >/dev/null"
  run_cmd "isolated site has own user" "grep -q '^user = site-' /etc/php/8.2/fpm/pool.d/${iso_project}.conf && test \"\$(stat -c %a /home/simai/www/${_iso_domain})\" = 750"
  run_cmd "sites of different users cannot read each other" "! sudo -u '${_feat_owner}' cat /home/simai/www/${_iso_domain}/public/index.php >/dev/null 2>&1"
  run_cmd "backup data" "./simai-admin.sh backup data --domain '${_feat_domain}' --keep 1 --dest /root/simai-regression-backups >/dev/null"
  run_cmd "backup data-verify with restore test" "./simai-admin.sh backup data-verify --path \"\$(ls -1d /root/simai-regression-backups/${_feat_domain}/2* | tail -1)\" --restore-test yes >/dev/null"
  run_cmd_expect_fail "owner remove while it runs sites" "./simai-admin.sh owner remove --name '${_feat_owner}' --confirm yes"
  run_cmd "self migrate is idempotent" "./simai-admin.sh self migrate >/tmp/simai-regression-migrate.log 2>&1 && grep -q 'nothing to migrate' /tmp/simai-regression-migrate.log"
  run_cmd "catch-all rejects unknown host on 443" "! curl -sk --resolve regression-unknown.invalid:443:127.0.0.1 https://regression-unknown.invalid/ -o /dev/null --max-time 5"
  run_cmd "site remove deletes the per-site user" "./simai-admin.sh site remove --domain '${_iso_domain}' --remove-files yes --confirm yes >/dev/null && ! getent passwd 'site-${iso_project}' >/dev/null"
  _iso_domain=""
}

case "$MODE" in
  smoke)
    run_smoke
    ;;
  core)
    run_smoke
    run_core
    ;;
  menu)
    run_menu
    ;;
  backend)
    run_backend
    ;;
  negative)
    run_negative
    ;;
  features)
    run_features
    ;;
  full)
    run_smoke
    run_core
    run_menu
    run_backend
    run_negative
    run_features
    ;;
  *)
    echo "Usage: testing/run-regression.sh [smoke|core|menu|backend|negative|features|full]" >&2
    exit 1
    ;;
esac

echo "[ok] regression mode=${MODE}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/testing/test-config.env"
MODE="${1:-smoke}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing ${CONFIG_FILE}. Copy testing/test-config.example.env first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

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

remote() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
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
    ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
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

cleanup() {
  if [[ -z "${_test_domain}" ]]; then
    return 0
  fi
  echo "[cleanup] ${_test_domain}"
  remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site db-drop --domain '${_test_domain}' --confirm yes >/dev/null 2>&1 || true"
  remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site remove --domain '${_test_domain}' --remove-files yes --confirm yes >/dev/null 2>&1 || true"
  if [[ -n "${_wp_test_domain}" ]]; then
    echo "[cleanup] ${_wp_test_domain}"
    remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site db-drop --domain '${_wp_test_domain}' --confirm yes >/dev/null 2>&1 || true"
    remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site remove --domain '${_wp_test_domain}' --remove-files yes --confirm yes >/dev/null 2>&1 || true"
  fi
  if [[ -n "${_bitrix_test_domain}" ]]; then
    echo "[cleanup] ${_bitrix_test_domain}"
    remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site db-drop --domain '${_bitrix_test_domain}' --confirm yes >/dev/null 2>&1 || true"
    remote "cd '${SIMAI_ROOT}' && ./simai-admin.sh site remove --domain '${_bitrix_test_domain}' --remove-files yes --confirm yes >/dev/null 2>&1 || true"
  fi
}

trap cleanup EXIT

run_smoke() {
  if [[ "${TEST_SYNC_UPDATE:-yes}" == "yes" ]]; then
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
  local suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
  local stamp
  stamp="$(date +%y%m%d-%H%M%S)"
  _test_domain="t-core-${stamp}${suffix}"

  run_cmd "site add (generic + db)" "./simai-admin.sh site add --domain '${_test_domain}' --profile generic --php-version 8.2 --db yes --force >/dev/null"
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
  run_cmd "site add (wordpress + db)" "./simai-admin.sh site add --domain '${_wp_test_domain}' --profile wordpress --php-version 8.2 --db yes --force >/dev/null"
  run_cmd "wp status" "./simai-admin.sh wp status --domain '${_wp_test_domain}' >/dev/null"
  run_cmd "wp cron-status" "./simai-admin.sh wp cron-status --domain '${_wp_test_domain}' >/dev/null"
  run_cmd "wp cron-sync" "./simai-admin.sh wp cron-sync --domain '${_wp_test_domain}' >/dev/null"

  local bx_suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
  local bx_stamp
  bx_stamp="$(date +%y%m%d-%H%M%S)"
  _bitrix_test_domain="t-bitrix-${bx_stamp}${bx_suffix}"
  run_cmd "site add (bitrix + db)" "./simai-admin.sh site add --domain '${_bitrix_test_domain}' --profile bitrix --php-version 8.2 --db yes --force >/dev/null"
  run_cmd "bitrix status" "./simai-admin.sh bitrix status --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix cron-status" "./simai-admin.sh bitrix cron-status --domain '${_bitrix_test_domain}' >/dev/null"
  run_cmd "bitrix cron-sync" "./simai-admin.sh bitrix cron-sync --domain '${_bitrix_test_domain}' >/dev/null"
}

run_menu() {
  run_menu_case "menu site info cancel" $'1\n3\n\n0\n0\n' "---- done (site info), exit=0 ----"
  run_menu_case "menu ssl status cancel" $'2\n2\n\n0\n0\n' "---- done (ssl status), exit=0 ----"
  run_menu_case "menu site remove cancel" $'1\n5\n\n0\n0\n' "---- done (site remove), exit=0 ----"
  run_menu_case "menu backup inspect cancel" $'7\n2\n\n0\n0\n' "---- done (backup inspect), exit=0 ----"
}

run_backend() {
  if ! remote "command -v whiptail >/dev/null 2>&1"; then
    echo "[skip] backend whiptail probe (whiptail not installed)"
    return 0
  fi
  echo "[run] backend whiptail probe"
  local output=""
  output=$(
    ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
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
  if [[ -z "${_test_domain:-}" ]]; then
    local suffix="${TEST_WILDCARD_SUFFIX:-.env.sf8.ru}"
    local stamp
    stamp="$(date +%y%m%d-%H%M%S)"
    _test_domain="t-neg-${stamp}${suffix}"
    run_cmd "site add (negative fixture)" "./simai-admin.sh site add --domain '${_test_domain}' --profile generic --php-version 8.2 --db no --force >/dev/null"
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
  fi
  run_cmd_expect_fail "backup inspect missing file" "./simai-admin.sh backup inspect --file /root/simai-backups/does-not-exist-zzz.tar.gz"
  run_cmd_expect_fail "backup import apply unknown profile" "./simai-admin.sh backup import --file '${backup_unknown}' --apply yes --enable no --reload no"
  run_cmd_expect_fail "backup import apply php none mismatch" "./simai-admin.sh backup import --file '${backup_phpnone}' --apply yes --enable no --reload no"
  if [[ -n "${_test_domain:-}" ]]; then
    run_cmd_expect_fail "ssl install broken cert path" "./simai-admin.sh ssl install --domain '${_test_domain}' --cert /root/test-certs/does-not-exist.crt --key /root/test-certs/does-not-exist.key"
  fi
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
  full)
    run_smoke
    run_core
    run_menu
    run_backend
    run_negative
    ;;
  *)
    echo "Usage: testing/run-regression.sh [smoke|core|menu|backend|negative|full]" >&2
    exit 1
    ;;
esac

echo "[ok] regression mode=${MODE}"

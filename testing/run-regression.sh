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

remote() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
}

run_cmd() {
  local title="$1"
  shift
  echo "[run] ${title}"
  remote "cd '${SIMAI_ROOT}' && $*"
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
}

trap cleanup EXIT

run_smoke() {
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
  run_cmd "backup export" "./simai-admin.sh backup export --domain '${_test_domain}' >/dev/null"
}

run_menu() {
  run_menu_case "menu site info cancel" $'1\n3\n\n0\n0\n' "---- done (site info), exit=0 ----"
  run_menu_case "menu ssl status cancel" $'2\n2\n\n0\n0\n' "---- done (ssl status), exit=0 ----"
  run_menu_case "menu site remove cancel" $'1\n6\n\n0\n0\n' "---- done (site remove), exit=0 ----"
  run_menu_case "menu backup inspect cancel" $'7\n2\n\n0\n0\n' "---- done (backup inspect), exit=0 ----"
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
  full)
    run_smoke
    run_core
    run_menu
    ;;
  *)
    echo "Usage: testing/run-regression.sh [smoke|core|menu|full]" >&2
    exit 1
    ;;
esac

echo "[ok] regression mode=${MODE}"

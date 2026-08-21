#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

fail() {
  echo "[correction-regression] FAIL: $*" >&2
  exit 1
}

assert_success() {
  "$@" || fail "expected success: $*"
}

assert_failure() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

test_install_mode_contract() {
  local install_script="${ROOT_DIR}/install.sh"
  local readme="${ROOT_DIR}/README.md"
  grep -Fqx 'curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo env SIMAI_INSTALL_MODE=scripts bash' "$readme" \
    || fail "README scripts-only command does not pass the mode into sudo bash"

  assert_success env SIMAI_INSTALL_SOURCE_ONLY=1 SIMAI_INSTALL_MODE=scripts bash -c \
    'source "$1"; install_mode_validate; ! install_bootstrap_enabled; ! install_profile_init_enabled' _ "$install_script"
  assert_success env SIMAI_INSTALL_SOURCE_ONLY=1 SIMAI_INSTALL_MODE=full bash -c \
    'source "$1"; install_mode_validate; install_bootstrap_enabled; install_profile_init_enabled' _ "$install_script"
  assert_success env SIMAI_INSTALL_SOURCE_ONLY=1 SIMAI_INSTALL_MODE=full SIMAI_INSTALL_NO_BOOTSTRAP=1 bash -c \
    'source "$1"; install_mode_validate; ! install_bootstrap_enabled; install_profile_init_enabled' _ "$install_script"
  assert_failure env SIMAI_INSTALL_SOURCE_ONLY=1 SIMAI_INSTALL_MODE=unknown bash -c \
    'source "$1"; install_mode_validate' _ "$install_script"
}

test_site_metadata_cleanup() {
  local tmp
  tmp=$(mktemp -d)
  error() { echo "$*" >&2; }
  # shellcheck source=../../admin/lib/site_cleanup_utils.sh
  source "${ROOT_DIR}/admin/lib/site_cleanup_utils.sh"

  mkdir -p "${tmp}/full"
  : >"${tmp}/full/db.env"
  : >"${tmp}/full/perf.env"
  : >"${tmp}/full/runtime.env"
  assert_success site_remove_metadata_cleanup "${tmp}/full" yes
  [[ ! -e "${tmp}/full" ]] || fail "empty full-removal metadata directory remains"

  mkdir -p "${tmp}/partial"
  : >"${tmp}/partial/db.env"
  : >"${tmp}/partial/perf.env"
  : >"${tmp}/partial/runtime.env"
  assert_success site_remove_metadata_cleanup "${tmp}/partial" no
  [[ -f "${tmp}/partial/db.env" && ! -e "${tmp}/partial/perf.env" && ! -e "${tmp}/partial/runtime.env" ]] \
    || fail "partial cleanup did not preserve db.env and remove managed runtime metadata"

  mkdir -p "${tmp}/unexpected"
  : >"${tmp}/unexpected/db.env"
  : >"${tmp}/unexpected/perf.env"
  : >"${tmp}/unexpected/owner-note"
  assert_failure site_remove_metadata_cleanup "${tmp}/unexpected" yes
  [[ -f "${tmp}/unexpected/owner-note" ]] || fail "unexpected metadata entry was removed"
  rm -rf "$tmp"
}

test_command_option_validation() {
  local core="${ROOT_DIR}/admin/core.sh"
  grep -Fq 'validate_command_options "$section" "$name" "$@" || return 1' "$core" \
    || fail "command dispatch does not validate options"
  grep -Fq 'Unknown option for ${section} ${name}: --${option}' "$core" \
    || fail "unknown-option error contract is missing"
  grep -Fq 'Unexpected positional argument for ${section} ${name}: ${arg}' "$core" \
    || fail "unexpected positional arguments do not fail closed"
}

test_access_add_key_preserves_metadata() {
  local access_commands="${ROOT_DIR}/admin/commands/access.sh"
  grep -Fq '"MOUNT_UNIT|${ACCESS_META[MOUNT_UNIT]:-}"' "$access_commands" \
    || fail "access add-key does not preserve the project bind-mount unit"
}

test_menu_contract() {
  local menu="${ROOT_DIR}/admin/menu.sh"
  grep -Fq '"10|Remove site"' "$menu" || fail "regular site action keys changed"
  grep -Fq '"20|Automatic optimization..."' "$menu" || fail "advanced site actions are not grouped"
  grep -Fq '10)' "$menu" || fail "System advanced toggle key is missing"
  grep -Fq 'show_advanced=0' "$menu" || fail "System advanced toggle is miswired"
  grep -Fq '11) menu_toggle_backend' "$menu" || fail "System backend toggle is miswired"
  grep -Fq 'select_from_list "Install required packages now?" "no" "no" "yes"' "$menu" || fail "bootstrap confirmation is not safe by default"
  grep -Fq 'menu_command_needs_confirmation' "$menu" || fail "managed-state menu confirmation gate is missing"
  grep -Fq '[[ -z "$choice" ]] && { echo ""; return 0; }' "$menu" || fail "blank menu choice can still terminate set -e menu"
  grep -Fq '"$cmd" != "create-global" && "$cmd" != "create-project"' "$menu" || fail "project access creation can reuse an existing-login picker"
}

test_second_audit_p2_p3_contracts() {
  local core="${ROOT_DIR}/admin/core.sh"
  local menu="${ROOT_DIR}/admin/menu.sh"
  local ui="${ROOT_DIR}/lib/ui.sh"
  local help="${ROOT_DIR}/simai-admin.sh"
  grep -Fq 'ui_terminal_geometry' "$core" || fail "terminal-aware dialog geometry is missing"
  grep -Fq '[WORKING] %s... %ss' "$core" || fail "non-TTY long-operation heartbeat is missing"
  grep -Fq 'for step in "$@"' "$ui" || fail "next steps are still discarded"
  grep -Fq 'command_exit=not_started' "$menu" || fail "pre-command cancellation marker is still misleading"
  grep -Fq 'Advanced Bitrix operations...' "$menu" || fail "Bitrix Advanced menu is still overloaded"
  grep -Fq 'Advanced system operations...' "$menu" || fail "System Advanced menu is still overloaded"
  grep -Fq 'simai-admin.sh help [section]' "$help" || fail "registry-derived help entrypoint is missing"
  ! grep -Fq -- '--pass secret' "$help" || fail "root help exposes a password literal"
  /usr/bin/python3 "${ROOT_DIR}/scripts/ci/command_coverage.py" --root "$ROOT_DIR" --check \
    | grep -Fq '"total": 132' || fail "command coverage does not classify all 132 commands"
}

test_second_audit_p1_contracts() {
  local site="${ROOT_DIR}/admin/commands/site.sh"
  local runner="${ROOT_DIR}/testing/run-regression.sh"
  local config="${ROOT_DIR}/testing/test-config.example.env"
  grep -Fq 'site_add_transaction_rollback' "$site" || fail "site add owned-resource rollback is missing"
  grep -Fq 'Site creation failed; rolling back resources created by this invocation' "$site" || fail "site add rollback is not observable"
  grep -Fq '"continue" \' "$site" || fail "profile expansion is not default-safe"
  local confirm_line ensure_line
  confirm_line=$(grep -n 'site_add_confirm_creation "$domain"' "$site" | tail -1 | cut -d: -f1)
  ensure_line=$(grep -n '^  ensure_user$' "$site" | tail -1 | cut -d: -f1)
  [[ -n "$confirm_line" && -n "$ensure_line" && $ensure_line -gt $confirm_line ]] \
    || fail "site add still ensures the platform user before final confirmation"
  grep -Fq 'TEST_SYNC_UPDATE:-no' "$runner" || fail "smoke update default is still mutating"
  grep -Fq -- '--remove_files yes' "$runner" || fail "runner cleanup retains db.env"
  grep -Fq 'cleanup_on_exit' "$runner" || fail "runner cleanup does not preserve/override final status"
  grep -Fqx 'TEST_SYNC_UPDATE=no' "$config" || fail "example config enables runtime sync"
  grep -Fqx 'ALLOW_DESTRUCTIVE_TESTS=no' "$config" || fail "example config enables destructive tests"
}

test_site_add_cancellation_ux() {
  local tmp trace output rc=0
  tmp=$(mktemp -d)
  trace="${tmp}/select.trace"

  (
    export ADMIN_DIR="${ROOT_DIR}/admin"
    register_cmd() { :; }
    # shellcheck source=../../admin/commands/site.sh
    source "${ROOT_DIR}/admin/commands/site.sh"
    select_from_list() {
      printf '%s\n' "$@" >"$trace"
      printf 'no\n'
    }
    command_cancelled() {
      printf '%s\n' "$1"
      return 89
    }
    set +e
    output=$(site_add_confirm_creation "update.rim1.ru")
    rc=$?
    set -e
    [[ $rc -eq 89 ]] || fail "final site confirmation no longer returns CANCELLED (89)"
    [[ "$output" == "Site creation cancelled at step 'final confirmation' for update.rim1.ru. No site changes were applied." ]] \
      || fail "final site cancellation message is not stage-specific"
    grep -Fq 'Final confirmation' "$trace" || fail "final confirmation heading is missing"
    grep -Fq 'Domain: update.rim1.ru' "$trace" || fail "final confirmation does not name the domain"
    grep -Fq 'Choose yes to create the site.' "$trace" || fail "final confirmation does not explain yes"
    grep -Fq 'Choose no to cancel without creating files or configuration.' "$trace" \
      || fail "final confirmation does not explain the safe no choice"
    [[ "$(tail -n 3 "$trace" | head -n 1)" == "no" ]] || fail "final confirmation is no longer default-safe"
  )

  rm -rf "$tmp"
}

test_bitrix_restore_preseed_php8_compatibility() {
  local tmp restore_root setup_root existing_root
  tmp=$(mktemp -d)
  restore_root="${tmp}/restore"
  setup_root="${tmp}/setup"
  existing_root="${tmp}/existing"
  mkdir -p "$restore_root" "$setup_root" "${existing_root}/bitrix/php_interface"

  (
    SIMAI_USER=$(id -un)
    export SIMAI_USER
    export SCRIPT_DIR="$ROOT_DIR"
    export SIMAI_ENV_ROOT="$ROOT_DIR"
    read_site_db_env() {
      printf '%s\n' \
        'DB_NAME|bitrix_restore_test' \
        'DB_USER|bitrix_restore_test' \
        'DB_PASS|local-test-password' \
        'DB_HOST|127.0.0.1'
    }
    bitrix_php_quote() {
      local value="$1"
      value=${value//\\/\\\\}
      value=${value//\'/\\\'}
      printf "'%s'" "$value"
    }
    # shellcheck source=../../admin/lib/site_utils.sh
    source "${ROOT_DIR}/admin/lib/site_utils.sh"

    assert_success bitrix_write_db_preseed_files example.test "$restore_root" no no no
    [[ -s "${restore_root}/bitrix/.settings.php" ]] || fail "restore preseed did not create .settings.php"
    [[ -s "${restore_root}/bitrix/php_interface/after_connect_d7.php" ]] || fail "restore preseed did not create after_connect_d7.php"
    [[ ! -e "${restore_root}/bitrix/php_interface/dbconn.php" ]] \
      || fail "restore preseed still creates premature dbconn.php"

    assert_success bitrix_write_db_preseed_files example.test "$setup_root" no yes
    [[ -s "${setup_root}/bitrix/php_interface/dbconn.php" ]] || fail "setup preseed no longer creates dbconn.php"
    grep -Fq 'define("BX_UTF", true);' "${setup_root}/bitrix/php_interface/dbconn.php" \
      || fail "setup preseed lost the UTF-8 contract"

    printf '%s\n' '<?php // existing site-owned dbconn' >"${existing_root}/bitrix/php_interface/dbconn.php"
    assert_success bitrix_write_db_preseed_files example.test "$existing_root" yes no no
    grep -Fq 'existing site-owned dbconn' "${existing_root}/bitrix/php_interface/dbconn.php" \
      || fail "restore preseed overwrote an existing site-owned dbconn.php"
  )

  rm -rf "$tmp"
}

test_bitrix_restore_archive_integrity_gate() {
  local tmp valid_root missing_root corrupt_root empty_root
  tmp=$(mktemp -d)
  valid_root="${tmp}/valid"
  missing_root="${tmp}/missing"
  corrupt_root="${tmp}/corrupt"
  empty_root="${tmp}/empty"
  mkdir -p "$valid_root" "$missing_root" "$corrupt_root" "$empty_root"

  /usr/bin/python3 - "$valid_root" <<'PY'
import gzip
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
parts = [b"first-volume\n" * 32, b"second-volume\n" * 32]
for index, payload in enumerate(parts):
    stream = gzip.compress(payload, mtime=0)
    extra = b"LN" + struct.pack("<H", len(parts) - 1) + b"BX" + struct.pack("<I", len(payload))
    stream = stream[:3] + b"\x04" + stream[4:10] + struct.pack("<H", len(extra)) + extra + stream[10:]
    suffix = "" if index == 0 else f".{index}"
    (root / f"backup.tar.gz{suffix}").write_bytes(stream)
PY

  cp -a "${valid_root}/." "$missing_root/"
  rm -f "${missing_root}/backup.tar.gz.1"
  cp -a "${valid_root}/." "$corrupt_root/"
  /usr/bin/python3 - "${corrupt_root}/backup.tar.gz.1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
path.write_bytes(data[:-8])
PY

  (
    export SCRIPT_DIR="$ROOT_DIR"
    export SIMAI_ENV_ROOT="$ROOT_DIR"
    # shellcheck source=../../admin/lib/site_utils.sh
    source "${ROOT_DIR}/admin/lib/site_utils.sh"

    assert_success bitrix_restore_archive_validate "$valid_root" auto
    [[ "$BITRIX_RESTORE_ARCHIVE_STATE" == "ready" && "$BITRIX_RESTORE_ARCHIVE_PARTS" == "2" ]] \
      || fail "valid multi-volume Bitrix archive did not pass"

    assert_failure bitrix_restore_archive_validate "$missing_root" auto
    [[ "$BITRIX_RESTORE_ARCHIVE_STATE" == "missing part" ]] \
      || fail "missing Bitrix archive part was not identified"

    assert_failure bitrix_restore_archive_validate "$corrupt_root" auto
    [[ "$BITRIX_RESTORE_ARCHIVE_STATE" == "corrupt part" ]] \
      || fail "corrupt Bitrix archive part was not identified"

    set +e
    bitrix_restore_archive_validate "$empty_root" auto
    local empty_rc=$?
    set -e
    [[ $empty_rc -eq 2 && "$BITRIX_RESTORE_ARCHIVE_STATE" == "not uploaded" ]] \
      || fail "empty restore directory is not reported as waiting for upload"
  )

  rm -rf "$tmp"
}

test_db_drop_failure_propagation() {
  local tmp calls=0
  tmp=$(mktemp -d)
  export LOG_FILE="${tmp}/db.log"
  # shellcheck source=../../admin/lib/db_utils.sh
  source "${ROOT_DIR}/admin/lib/db_utils.sh"
  error() { echo "$*" >&2; }
  mysql_root_detect_cli() { return 0; }
  mysql_root_exec_stdin() {
    calls=$((calls + 1))
    [[ $calls -ne 2 ]]
  }
  site_db_env_file() { printf '%s/db.env\n' "$tmp"; }
  : >"${tmp}/db.env"
  assert_failure site_db_apply_drop example.test db_name db_user yes
  [[ -f "${tmp}/db.env" ]] || fail "db.env was removed after a partial DB-user failure"
  rm -rf "$tmp"
}

write_update_fixture() {
  local fixture_root="$1" version="$2" smoke_mode="$3"
  mkdir -p "${fixture_root}/simai-env-fixture/scripts/ci"
  printf '%s\n' "$version" >"${fixture_root}/simai-env-fixture/VERSION"
  for script in simai-env.sh simai-admin.sh update.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${fixture_root}/simai-env-fixture/${script}"
    chmod +x "${fixture_root}/simai-env-fixture/${script}"
  done
  case "$smoke_mode" in
    pass)
      printf '#!/usr/bin/env bash\nexit 0\n' >"${fixture_root}/simai-env-fixture/scripts/ci/smoke.sh"
      ;;
    fail-after-activation)
      printf '#!/usr/bin/env bash\ncase "$PWD" in *.stage.*) exit 0;; *) exit 1;; esac\n' \
        >"${fixture_root}/simai-env-fixture/scripts/ci/smoke.sh"
      ;;
  esac
  tar -czf "${fixture_root}/fixture.tar.gz" -C "$fixture_root" simai-env-fixture
}

write_old_install() {
  local root="$1"
  mkdir -p "${root}/scripts/ci"
  printf '%s\n' old >"${root}/VERSION"
  printf '%s\n' stale >"${root}/stale-file"
  for script in simai-env.sh simai-admin.sh update.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/${script}"
    chmod +x "${root}/${script}"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/scripts/ci/smoke.sh"
}

test_updater_transaction() {
  local tmp harness fakebin install backup fixture rc
  tmp=$(mktemp -d)
  harness="${tmp}/harness"
  fakebin="${tmp}/bin"
  mkdir -p "${harness}/lib" "$fakebin"
  cp "${ROOT_DIR}/update.sh" "${harness}/update.sh"
  cat >"${harness}/lib/platform.sh" <<'EOF'
platform_detect_os() { PLATFORM_OS_PRETTY="test Ubuntu"; }
platform_supported_matrix_string() { echo "test"; }
platform_is_supported_os() { return 0; }
EOF
  cat >"${harness}/lib/update_channel.sh" <<'EOF'
update_ref_default() { echo refs/heads/main; }
update_ref_is_valid() { return 0; }
update_repo_http_url() { echo https://github.com/simai/simai-env; }
update_repo_is_allowed() { return 0; }
update_resolve_ref_sha() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
update_tarball_url() { echo https://fixture.invalid/archive.tar.gz; }
update_extract_archive() { tar -xzf "$1" -C "$2"; }
update_find_extracted_source_dir() { find "$1" -mindepth 1 -maxdepth 1 -type d -name 'simai-env-*' | head -1; }
EOF
  cat >"${fakebin}/curl" <<'EOF'
#!/usr/bin/env bash
set -e
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    cp "$FIXTURE_ARCHIVE" "$2"
    exit 0
  fi
  shift
done
exit 1
EOF
  chmod +x "${fakebin}/curl" "${harness}/update.sh"

  install="${tmp}/success/install"
  backup="${tmp}/success/backups"
  fixture="${tmp}/success/fixture"
  write_old_install "$install"
  mkdir -p "$fixture"
  write_update_fixture "$fixture" new pass
  PATH="${fakebin}:$PATH" FIXTURE_ARCHIVE="${fixture}/fixture.tar.gz" \
    INSTALL_DIR="$install" SIMAI_UPDATE_BACKUP_DIR="$backup" "${harness}/update.sh" >/dev/null
  [[ "$(cat "${install}/VERSION")" == new ]] || fail "updater did not activate staged tree"
  [[ ! -e "${install}/stale-file" ]] || fail "stale file survived exact-tree replacement"
  find "$backup" -type f -name 'simai-env-preupdate-*.tar.gz' -print -quit | grep -q . \
    || fail "successful update did not create a recovery archive"

  install="${tmp}/backup-fail/install"
  write_old_install "$install"
  mkdir -p "${tmp}/backup-fail"
  : >"${tmp}/backup-fail/not-a-directory"
  set +e
  PATH="${fakebin}:$PATH" FIXTURE_ARCHIVE="${fixture}/fixture.tar.gz" \
    INSTALL_DIR="$install" SIMAI_UPDATE_BACKUP_DIR="${tmp}/backup-fail/not-a-directory" \
    "${harness}/update.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 && "$(cat "${install}/VERSION")" == old && -f "${install}/stale-file" ]] \
    || fail "backup failure did not abort with the old tree untouched"

  install="${tmp}/smoke-fail/install"
  backup="${tmp}/smoke-fail/backups"
  fixture="${tmp}/smoke-fail/fixture"
  write_old_install "$install"
  mkdir -p "$fixture"
  write_update_fixture "$fixture" broken fail-after-activation
  set +e
  PATH="${fakebin}:$PATH" FIXTURE_ARCHIVE="${fixture}/fixture.tar.gz" \
    INSTALL_DIR="$install" SIMAI_UPDATE_BACKUP_DIR="$backup" "${harness}/update.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 && "$(cat "${install}/VERSION")" == old && -f "${install}/stale-file" ]] \
    || fail "post-activation smoke failure did not restore the old tree"
  [[ ! -e "${install}/broken-marker" ]] || fail "failed candidate residue remains after rollback"
  rm -rf "$tmp"
}

test_install_mode_contract
test_site_metadata_cleanup
test_command_option_validation
test_access_add_key_preserves_metadata
test_menu_contract
test_second_audit_p1_contracts
test_second_audit_p2_p3_contracts
test_site_add_cancellation_ux
test_bitrix_restore_preseed_php8_compatibility
test_bitrix_restore_archive_integrity_gate
test_db_drop_failure_propagation
test_updater_transaction
echo "[correction-regression] ok"

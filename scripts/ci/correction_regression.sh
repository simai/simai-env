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
  assert_success site_remove_metadata_cleanup "${tmp}/full" yes
  [[ ! -e "${tmp}/full" ]] || fail "empty full-removal metadata directory remains"

  mkdir -p "${tmp}/partial"
  : >"${tmp}/partial/db.env"
  : >"${tmp}/partial/perf.env"
  assert_success site_remove_metadata_cleanup "${tmp}/partial" no
  [[ -f "${tmp}/partial/db.env" && ! -e "${tmp}/partial/perf.env" ]] \
    || fail "partial cleanup did not preserve db.env and remove perf.env"

  mkdir -p "${tmp}/unexpected"
  : >"${tmp}/unexpected/db.env"
  : >"${tmp}/unexpected/perf.env"
  : >"${tmp}/unexpected/owner-note"
  assert_failure site_remove_metadata_cleanup "${tmp}/unexpected" yes
  [[ -f "${tmp}/unexpected/owner-note" ]] || fail "unexpected metadata entry was removed"
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
test_db_drop_failure_propagation
test_updater_transaction
echo "[correction-regression] ok"

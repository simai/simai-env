#!/usr/bin/env bash
set -euo pipefail

bitrix_cron_markers() {
  local cron_file="$1" domain="$2" slug="$3"
  BX_CRON_MANAGED="no"
  BX_CRON_DOMAIN_MATCH="no"
  BX_CRON_SLUG_MATCH="no"
  BX_CRON_ENTRY_MATCH="no"
  if [[ ! -f "$cron_file" ]]; then
    return 0
  fi
  grep -Eq "^# simai-managed: yes" "$cron_file" && BX_CRON_MANAGED="yes"
  grep -Eq "^# simai-domain: ${domain}$" "$cron_file" && BX_CRON_DOMAIN_MATCH="yes"
  grep -Eq "^# simai-slug: ${slug}$" "$cron_file" && BX_CRON_SLUG_MATCH="yes"
  grep -Eq "cron_events\\.php" "$cron_file" && BX_CRON_ENTRY_MATCH="yes"
}

bitrix_prepare_site() {
  local domain="$1"
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  local profile="${SITE_META[profile]:-}"
  if [[ "$profile" != "bitrix" ]]; then
    error "Bitrix commands are supported for bitrix profile only (got ${profile:-unknown})."
    return 2
  fi
  local root="${SITE_META[root]:-}"
  if ! validate_path "$root"; then
    return 1
  fi
  local public_dir="${SITE_META[public_dir]:-public}"
  local doc_root
  doc_root=$(site_compute_doc_root "$root" "$public_dir") || return 1
  local slug="${SITE_META[slug]:-${SITE_META[project]:-$(project_slug_from_domain "$domain")}}"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  local php_version="${SITE_META[php]:-}"
  BX_DOMAIN="$domain"
  BX_ROOT="$root"
  BX_DOC_ROOT="$doc_root"
  BX_SLUG="$slug"
  BX_PHP_VERSION="$php_version"
  BX_CRON_FILE="/etc/cron.d/${slug}"
  BX_SETTINGS_FILE="${doc_root}/bitrix/.settings.php"
  BX_DBCONN_FILE="${doc_root}/bitrix/php_interface/dbconn.php"
  BX_CRON_ENTRYPOINT="${doc_root}/bitrix/modules/main/tools/cron_events.php"
  BX_HAS_CORE="no"
  [[ -d "${doc_root}/bitrix/modules/main" && -f "${doc_root}/index.php" ]] && BX_HAS_CORE="yes"
  return 0
}

bitrix_dbconn_const_state() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*true" "$file"; then
    echo "true"
    return 0
  fi
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*false" "$file"; then
    echo "false"
    return 0
  fi
  echo "missing"
}

bitrix_dbconn_set_const_true() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local esc
  esc=$(printf '%s\n' "$const_name" | sed 's/[][^$.*/\\|+?(){}]/\\&/g')
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${esc}['\"][[:space:]]*," "$file"; then
    perl -0777 -i -pe "s/^\\s*define\\s*\\(\\s*(['\"])${esc}\\1\\s*,\\s*(true|false)\\s*\\)\\s*;\\s*\$/if (!defined('${const_name}')) {\\n    define('${const_name}', true);\\n}/img" "$file"
  fi
  if ! grep -Eqi "defined[[:space:]]*\\([[:space:]]*['\"]${esc}['\"]" "$file"; then
    {
      echo ""
      echo "// simai-managed: bitrix agents baseline"
      echo "if (!defined('${const_name}')) {"
      echo "    define('${const_name}', true);"
      echo "}"
    } >>"$file"
  fi
  return 0
}

bitrix_dbconn_drop_const() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local esc
  esc=$(printf '%s\n' "$const_name" | sed 's/[][^$.*/\\|+?(){}]/\\&/g')
  perl -0777 -i -pe "s/^\\s*define\\s*\\(\\s*(['\"])${esc}\\1\\s*,[^;]*\\)\\s*;\\s*\\n?//img" "$file"
  return 0
}

bitrix_agents_ready_state() {
  local cron_managed="$1" cron_domain_match="$2" cron_slug_match="$3" cron_entry="$4" crontab="$5" crontab_support="$6"
  if [[ "$cron_managed" == "yes" && "$cron_domain_match" == "yes" && "$cron_slug_match" == "yes" && "$cron_entry" == "yes" && "$crontab_support" == "true" ]]; then
    echo "yes"
    return 0
  fi
  echo "no"
}

bitrix_perf_read_mode() {
  local domain="$1"
  local mode="none"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "mode" ]]; then
      mode="${entry#*|}"
      break
    fi
  done < <(read_site_perf_settings "$domain")
  echo "$mode"
}

bitrix_perf_install_stage() {
  local short_install="$1" agents_ready="${2:-no}"
  if [[ "$agents_ready" == "yes" ]]; then
    echo "post-install"
    return 0
  fi
  case "$short_install" in
    true) echo "installer" ;;
    false) echo "post-install" ;;
    missing|unknown|"") echo "unknown" ;;
    *) echo "unknown" ;;
  esac
}

bitrix_perf_settings_init_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if grep -q "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci" "$file" 2>/dev/null \
    && grep -q "SET SESSION sql_mode=''" "$file" 2>/dev/null \
    && grep -q "SET SESSION innodb_strict_mode=0" "$file" 2>/dev/null; then
    echo "ready"
    return 0
  fi
  echo "partial"
}

bitrix_perf_after_connect_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if grep -q "innodb_strict_mode" "$file" 2>/dev/null \
    && grep -q "sql_mode=''" "$file" 2>/dev/null \
    && grep -q "utf8mb4_unicode_ci" "$file" 2>/dev/null; then
    echo "ready"
    return 0
  fi
  echo "partial"
}

bitrix_perf_cache_dirs_state() {
  local doc_root="$1"
  local present=0 total=3
  local dir
  for dir in \
    "${doc_root}/bitrix/cache" \
    "${doc_root}/bitrix/managed_cache" \
    "${doc_root}/bitrix/stack_cache"; do
    [[ -d "$dir" ]] && present=$((present + 1))
  done
  echo "${present}/${total} present"
}

bitrix_perf_site_mode_for_apply() {
  local mode="$1"
  case "$mode" in
    standard) echo "balanced" ;;
    high-load) echo "aggressive" ;;
    *)
      return 1
      ;;
  esac
}

bitrix_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · Bitrix status"
  local settings_present="no"
  local dbconn_present="no"
  local bx_crontab="unknown"
  local bx_crontab_support="unknown"
  local short_install="unknown"
  local setup_script=""
  local setup_state="missing"
  local setup_kind="missing"
  local archives="none"
  local cron_entrypoint="missing"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"

  [[ -f "$BX_SETTINGS_FILE" ]] && settings_present="yes"
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if [[ -s "$setup_script" ]]; then
    setup_kind=$(bitrix_setup_script_kind "$setup_script")
    case "$setup_kind" in
      site-management) setup_state="ready" ;;
      bitrix24-loader) setup_state="generic-loader" ;;
      *) setup_state="present" ;;
    esac
  fi
  archives=$(bitrix_detect_distribution_archives "$BX_DOC_ROOT")
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_present="yes"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
  fi
  [[ -f "$BX_CRON_ENTRYPOINT" ]] && cron_entrypoint="present"
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    if [[ "${BX_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Core files|${BX_HAS_CORE}" \
    ".settings.php|${settings_present}" \
    "dbconn.php|${dbconn_present}" \
    "bitrixsetup.php|${setup_script} (${setup_state})" \
    "Setup kind|${setup_kind}" \
    "Archives|${archives}" \
    "BX_CRONTAB|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT|${bx_crontab_support}" \
    "SHORT_INSTALL|${short_install}" \
    "Scheduler script|${cron_entrypoint}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}"
  ui_section "Next steps"
  ui_kv "Open installer" "$(site_primary_url "$BX_DOMAIN")/bitrixsetup.php?test=1"
  ui_kv "Doctor" "simai-admin.sh site doctor --domain ${BX_DOMAIN}"
  ui_kv "Installer ready" "simai-admin.sh bitrix installer-ready --domain ${BX_DOMAIN}"
  ui_kv "Scheduler sync" "simai-admin.sh bitrix cron-sync --domain ${BX_DOMAIN}"
  ui_kv "Agents status" "simai-admin.sh bitrix agents-status --domain ${BX_DOMAIN}"
}

bitrix_cron_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · Bitrix scheduler status"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    if [[ "${BX_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry (cron_events.php)|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}"
  ui_section "Next steps"
  ui_kv "Sync scheduler" "simai-admin.sh bitrix cron-sync --domain ${BX_DOMAIN}"
}

bitrix_cron_sync_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ -z "$BX_PHP_VERSION" || "$BX_PHP_VERSION" == "none" ]]; then
    error "Bitrix site PHP version is missing for ${domain}."
    return 1
  fi
  ui_header "SIMAI ENV · Bitrix scheduler sync"
  cron_site_write "$BX_DOMAIN" "$BX_SLUG" "bitrix" "$BX_ROOT" "$BX_PHP_VERSION"
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Scheduler file|${BX_CRON_FILE}" \
    "Profile|bitrix" \
    "PHP|${BX_PHP_VERSION}"
  ui_section "Next steps"
  ui_kv "Check scheduler" "simai-admin.sh bitrix cron-status --domain ${BX_DOMAIN}"
}

bitrix_agents_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · Bitrix agents status"
  local dbconn_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  local cron_file_state="missing"
  local cron_entry_match="no"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"

  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_state="present"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi
  local ready
  ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support")

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn.php|${dbconn_state}" \
    "BX_CRONTAB|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT|${bx_crontab_support}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "Scheduler entry (cron_events.php)|${cron_entry_match}" \
    "Agents via scheduler|${ready}"
  ui_section "Next steps"
  ui_kv "Plan sync" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN}"
  ui_kv "Apply sync" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN} --apply yes --confirm yes"
}

bitrix_agents_sync_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${apply,,}" == "yes" ]] || apply="no"
  [[ "${confirm,,}" == "yes" ]] || confirm="no"

  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ -z "$BX_PHP_VERSION" || "$BX_PHP_VERSION" == "none" ]]; then
    error "Bitrix site PHP version is missing for ${domain}."
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix agents sync"
  local dbconn_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_state="present"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi

  ui_section "Plan"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn.php|${BX_DBCONN_FILE} (${dbconn_state})" \
    "BX_CRONTAB current|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT current|${bx_crontab_support}" \
    "Scheduler target|${BX_CRON_FILE}" \
    "Apply mode|${apply}"

  if [[ "$apply" != "yes" ]]; then
    info "Plan only. No changes applied."
    ui_section "Next steps"
    ui_kv "Apply" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN} --apply yes --confirm yes"
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply Bitrix agents sync in CLI mode."
    return 1
  fi
  if [[ ! -f "$BX_DBCONN_FILE" ]]; then
    error "dbconn.php not found: ${BX_DBCONN_FILE}"
    return 1
  fi

  local ts backup
  ts=$(date +%Y%m%d-%H%M%S)
  backup="${BX_DBCONN_FILE}.bak.${ts}"
  cp -a "$BX_DBCONN_FILE" "$backup"
  if ! bitrix_dbconn_drop_const "$BX_DBCONN_FILE" "BX_CRONTAB"; then
    error "Failed to sanitize BX_CRONTAB in ${BX_DBCONN_FILE}"
    cp -a "$backup" "$BX_DBCONN_FILE" || true
    return 1
  fi
  if ! bitrix_dbconn_set_const_true "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT"; then
    error "Failed to update BX_CRONTAB_SUPPORT in ${BX_DBCONN_FILE}"
    cp -a "$backup" "$BX_DBCONN_FILE" || true
    return 1
  fi

  cron_site_write "$BX_DOMAIN" "$BX_SLUG" "bitrix" "$BX_ROOT" "$BX_PHP_VERSION"
  local cron_managed="no" cron_domain_match="no" cron_slug_match="no" cron_entry_match="no"
  if [[ -f "$BX_CRON_FILE" ]]; then
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn backup|${backup}" \
    "BX_CRONTAB|$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")" \
    "BX_CRONTAB_SUPPORT|$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")" \
    "Scheduler file|${BX_CRON_FILE}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "Scheduler entry (cron_events.php)|${cron_entry_match}"
  ui_section "Next steps"
  ui_kv "Verify" "simai-admin.sh bitrix agents-status --domain ${BX_DOMAIN}"
}

bitrix_cache_clear_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  ui_header "SIMAI ENV · Bitrix cache clear"
  local -a dirs=(
    "${BX_DOC_ROOT}/bitrix/cache"
    "${BX_DOC_ROOT}/bitrix/managed_cache"
    "${BX_DOC_ROOT}/bitrix/stack_cache"
  )
  local cleared=0 missing=0 dir
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + >/dev/null 2>&1 || true
      cleared=$((cleared + 1))
    else
      missing=$((missing + 1))
    fi
  done
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Cache dirs cleared|${cleared}" \
    "Cache dirs missing|${missing}"
  ui_section "Next steps"
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_list_sites() {
  local domain profile
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    if read_site_metadata "$domain"; then
      profile="${SITE_META[profile]:-}"
      if [[ "$profile" == "bitrix" ]]; then
        echo "$domain"
      fi
    fi
  done < <(list_sites)
}

bitrix_db_preseed_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local short_install="${PARSED_ARGS[short-install]:-yes}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"

  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  if ! read_site_db_env "$BX_DOMAIN" >/dev/null 2>&1; then
    error "db.env not found or incomplete for ${BX_DOMAIN}"
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix DB preseed"
  local status="failed"
  if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "$overwrite" "$short_install"; then
    status="ready"
  else
    error "Failed to generate Bitrix DB preseed files"
    return 1
  fi

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Overwrite|${overwrite}" \
    "SHORT_INSTALL|${short_install}" \
    ".settings.php|${BX_SETTINGS_FILE}" \
    "dbconn.php|${BX_DBCONN_FILE}" \
    "Status|${status}"
  ui_section "Next steps"
  ui_kv "Open installer" "https://${BX_DOMAIN}/bitrixsetup.php"
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_installer_ready_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local short_install="${PARSED_ARGS[short-install]:-yes}"
  local setup_overwrite="${PARSED_ARGS[setup-overwrite]:-no}"
  local archive="${PARSED_ARGS[archive]:-yes}"
  local edition="${PARSED_ARGS[edition]:-standard}"
  local archive_overwrite="${PARSED_ARGS[archive-overwrite]:-no}"
  local unpack="${PARSED_ARGS[unpack]:-yes}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"
  [[ "${setup_overwrite,,}" == "yes" ]] || setup_overwrite="no"
  [[ "${archive,,}" == "yes" ]] && archive="yes" || archive="no"
  [[ "${archive_overwrite,,}" == "yes" ]] || archive_overwrite="no"
  [[ "${unpack,,}" == "yes" ]] && unpack="yes" || unpack="no"
  edition=$(bitrix_distribution_edition_normalize "$edition") || {
    error "Unsupported Bitrix edition '${edition}'. Use: start, standard, small-business, business"
    return 1
  }

  if ! bitrix_prepare_site "$domain"; then
    return $?
  fi
  if ! read_site_db_env "$BX_DOMAIN" >/dev/null 2>&1; then
    error "db.env not found or incomplete for ${BX_DOMAIN}"
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix installer ready"
  local preseed_state="failed"
  if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "$overwrite" "$short_install"; then
    preseed_state="ready"
  fi
  local setup_state="failed"
  local setup_script
  local setup_kind="missing"
  local archive_state="skipped"
  local archive_path="n/a"
  local unpack_state="skipped"
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if bitrix_download_setup_script "$BX_DOC_ROOT" "$setup_overwrite"; then
    setup_kind=$(bitrix_setup_script_kind "$setup_script")
    case "$setup_kind" in
      site-management) setup_state="ready" ;;
      bitrix24-loader) setup_state="generic-loader" ;;
      *) setup_state="downloaded" ;;
    esac
  fi
  if [[ "$archive" == "yes" ]]; then
    archive_path=$(bitrix_distribution_archive_path "$BX_DOC_ROOT" "$edition") || archive_path="n/a"
    if bitrix_download_distribution_archive "$BX_DOC_ROOT" "$edition" "$archive_overwrite"; then
      archive_state="ready"
    else
      archive_state="failed"
    fi
  fi
  if [[ "$archive_state" == "ready" && "$unpack" == "yes" ]]; then
    if bitrix_unpack_distribution_archive "$BX_DOC_ROOT" "$edition"; then
      unpack_state="ready"
      if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "yes" "$short_install"; then
        preseed_state="ready"
      else
        preseed_state="failed"
      fi
    else
      unpack_state="failed"
    fi
  fi
  local status="ready"
  if [[ "$preseed_state" != "ready" ]]; then
    status="partial"
  elif [[ "$unpack_state" == "ready" ]]; then
    status="ready"
  elif [[ "$setup_state" == "ready" ]]; then
    status="ready"
  elif [[ "$setup_kind" == "bitrix24-loader" && "$archive_state" == "ready" ]]; then
    status="ready"
  else
    status="partial"
  fi

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "DB preseed|${preseed_state}" \
    "SHORT_INSTALL|${short_install}" \
    "Setup script|${setup_state}" \
    "Setup kind|${setup_kind}" \
    "Edition|${edition}" \
    "Archive|${archive_state}" \
    "Archive path|${archive_path}" \
    "Unpack|${unpack_state}" \
    "bitrixsetup.php|${setup_script}" \
    "Status|${status}"
  if [[ "$status" != "ready" ]]; then
    warn "Installer ready is partial. Check network access, db.env values, and whether the setup script plus local distro archive form a valid Site Management installer flow."
    return 1
  fi
  ui_section "Next steps"
  if [[ "$unpack_state" == "ready" ]]; then
    ui_kv "Open installer" "$(site_primary_url "$BX_DOMAIN")/"
  else
    ui_kv "Open installer" "$(site_primary_url "$BX_DOMAIN")/bitrixsetup.php?test=1"
  fi
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_php_baseline_sync_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local all="${PARSED_ARGS[all]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local include_recommended="${PARSED_ARGS[include-recommended]:-yes}"
  [[ "${all,,}" == "yes" ]] && all="yes" || all="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${include_recommended,,}" == "yes" ]] && include_recommended="yes" || include_recommended="no"

  local -a targets=()
  if [[ "$all" == "yes" ]]; then
    mapfile -t targets < <(bitrix_list_sites)
    if [[ ${#targets[@]} -eq 0 ]]; then
      warn "No bitrix sites found"
      return 0
    fi
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
      error "Bulk sync requires --confirm yes"
      return 1
    fi
  else
    if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
      local candidates=()
      mapfile -t candidates < <(bitrix_list_sites)
      if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No bitrix sites found"
        return 0
      fi
      domain=$(select_from_list "Select Bitrix site" "" "${candidates[@]}")
      if [[ -z "$domain" ]]; then
        warn "Cancelled."
        return 0
      fi
    fi
    require_args "domain" || return 1
    if ! bitrix_prepare_site "$domain"; then
      return $?
    fi
    targets=("$domain")
  fi

  ui_header "SIMAI ENV · Bitrix PHP baseline sync"
  local ok=0 fail=0 d
  local -a failed=()
  for d in "${targets[@]}"; do
    info "Applying PHP INI baseline for ${d}"
    if run_command site fix --domain "$d" --apply php-ini --include-recommended "$include_recommended" --confirm yes; then
      # Enforce critical Bitrix runtime keys in FPM pool regardless of CLI ini defaults.
      if bitrix_prepare_site "$d"; then
        local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$(project_slug_from_domain "$d")}}"
        if [[ -n "${BX_PHP_VERSION:-}" && "${BX_PHP_VERSION:-none}" != "none" ]]; then
          write_site_php_ini_overrides "$d" \
            "short_open_tag|1" \
            "memory_limit|512M" \
            "max_input_vars|10000" \
            "opcache.validate_timestamps|1" \
            "opcache.revalidate_freq|0"
          if apply_site_php_ini_overrides_to_pool "$d" "$BX_PHP_VERSION" "$socket_project" "yes"; then
            ok=$((ok + 1))
          else
            fail=$((fail + 1))
            failed+=("$d")
          fi
        else
          fail=$((fail + 1))
          failed+=("$d")
        fi
      else
        fail=$((fail + 1))
        failed+=("$d")
      fi
    else
      fail=$((fail + 1))
      failed+=("$d")
    fi
  done

  ui_section "Result"
  print_kv_table \
    "Scope|$([[ "$all" == "yes" ]] && echo all bitrix sites || echo single site)" \
    "Targets|${#targets[@]}" \
    "Applied|${ok}" \
    "Failed|${fail}" \
    "Include recommended|${include_recommended}"
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed sites: ${failed[*]}"
    return 1
  fi
  ui_section "Next steps"
  ui_kv "Verify one site" "simai-admin.sh site doctor --domain <bitrix-domain>"
  return 0
}

bitrix_perf_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  if ! bitrix_prepare_site "$domain"; then
    return $?
  fi

  local managed_mode="none"
  managed_mode=$(bitrix_perf_read_mode "$domain")
  local settings_present="no"
  local dbconn_present="no"
  local after_connect_state="missing"
  local settings_init_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  local short_install="unknown"
  local install_stage="unknown"
  local cron_file_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local cron_entry_match="no"
  local agents_ready="no"
  local cache_dirs="0/3 present"
  local php_bin=""
  local redis_ext="no"
  local redis_service="n/a"
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$BX_SLUG}}"
  local pool_file="/etc/php/${BX_PHP_VERSION}/fpm/pool.d/${socket_project}.conf"
  local memory_limit="n/a"
  local upload_max="n/a"
  local post_max="n/a"
  local max_input_vars="n/a"
  local max_execution_time="n/a"
  local short_open_tag="n/a"
  local opcache_revalidate="n/a"
  local opcache_memory="n/a"

  [[ -f "$BX_SETTINGS_FILE" ]] && settings_present="yes"
  if [[ -f "$BX_SETTINGS_FILE" ]]; then
    settings_init_state=$(bitrix_perf_settings_init_state "$BX_SETTINGS_FILE")
  fi
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_present="yes"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
  fi
  after_connect_state=$(bitrix_perf_after_connect_state "${BX_DOC_ROOT}/bitrix/php_interface/after_connect_d7.php")
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi
  agents_ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support")
  install_stage=$(bitrix_perf_install_stage "$short_install" "$agents_ready")
  cache_dirs=$(bitrix_perf_cache_dirs_state "$BX_DOC_ROOT")

  if [[ -f "$pool_file" ]]; then
    memory_limit=$(doctor_php_pool_ini_get "$pool_file" "memory_limit" || true)
    upload_max=$(doctor_php_pool_ini_get "$pool_file" "upload_max_filesize" || true)
    post_max=$(doctor_php_pool_ini_get "$pool_file" "post_max_size" || true)
    max_input_vars=$(doctor_php_pool_ini_get "$pool_file" "max_input_vars" || true)
    max_execution_time=$(doctor_php_pool_ini_get "$pool_file" "max_execution_time" || true)
    short_open_tag=$(doctor_php_pool_ini_get "$pool_file" "short_open_tag" || true)
    opcache_revalidate=$(doctor_php_pool_ini_get "$pool_file" "opcache.revalidate_freq" || true)
    opcache_memory=$(doctor_php_pool_ini_get "$pool_file" "opcache.memory_consumption" || true)
  fi
  php_bin=$(resolve_php_bin "$BX_PHP_VERSION")
  if [[ -n "$php_bin" ]] && "$php_bin" -m 2>/dev/null | grep -qi '^redis$'; then
    redis_ext="yes"
  fi
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_service="active"
    else
      redis_service="inactive"
    fi
  fi

  ui_header "SIMAI ENV · Bitrix optimization"
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Optimization mode|${managed_mode}" \
    "Install stage|${install_stage}" \
    "PHP|${BX_PHP_VERSION:-none}" \
    "Core files|${BX_HAS_CORE}" \
    ".settings.php|${settings_present}" \
    "dbconn.php|${dbconn_present}" \
    "Settings init_commands|${settings_init_state}" \
    "after_connect_d7.php|${after_connect_state}" \
    "Agents via cron ready|${agents_ready}" \
    "Cache dirs|${cache_dirs}" \
    "memory_limit|${memory_limit:-n/a}" \
    "upload_max_filesize|${upload_max:-n/a}" \
    "post_max_size|${post_max:-n/a}" \
    "max_input_vars|${max_input_vars:-n/a}" \
    "max_execution_time|${max_execution_time:-n/a}" \
    "short_open_tag|${short_open_tag:-n/a}" \
    "opcache.revalidate_freq|${opcache_revalidate:-n/a}" \
    "opcache.memory_consumption|${opcache_memory:-n/a}" \
    "Redis extension|${redis_ext}" \
    "Redis service|${redis_service}"
  ui_section "Next steps"
  ui_kv "Apply standard optimization" "simai-admin.sh bitrix perf-apply --domain ${BX_DOMAIN} --mode standard --confirm yes"
  ui_kv "Checker" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/site_checker.php"
  ui_kv "Perfmon" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/perfmon_panel.php"
}

bitrix_perf_apply_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local mode="${PARSED_ARGS[mode]:-standard}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local include_recommended="${PARSED_ARGS[include-recommended]:-yes}"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${include_recommended,,}" == "yes" ]] && include_recommended="yes" || include_recommended="no"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    standard|high-load) ;;
    *)
      error "Unsupported Bitrix performance mode: ${mode}"
      return 1
      ;;
  esac
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply Bitrix optimization changes"
    return 1
  fi
  if ! bitrix_prepare_site "$domain"; then
    return $?
  fi

  local site_mode=""
  site_mode=$(bitrix_perf_site_mode_for_apply "$mode") || return 1
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$BX_SLUG}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi
  local -a settings=()
  mapfile -t settings < <(site_perf_mode_defaults "bitrix" "$site_mode")
  write_site_perf_settings "$domain" "${settings[@]}"
  apply_site_perf_settings_to_pool "$domain" "$BX_PHP_VERSION" "$socket_project" || return 1

  local php_status="ok"
  local agents_status="skipped"
  local cache_status="skipped"
  if ! run_command bitrix php-baseline-sync --domain "$domain" --include-recommended "$include_recommended"; then
    php_status="failed"
    error "Bitrix PHP baseline sync failed for ${domain}"
    return 1
  fi

  local short_install="unknown"
  local cron_managed="no" cron_domain_match="no" cron_slug_match="no" cron_entry_match="no"
  local bx_crontab="missing" bx_crontab_support="missing"
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi
  if [[ -f "$BX_CRON_FILE" ]]; then
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi
  local agents_ready="no"
  agents_ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support")
  if [[ ("$short_install" != "true" || "$agents_ready" == "yes") && -f "$BX_DBCONN_FILE" ]]; then
    if run_command bitrix agents-sync --domain "$domain" --apply yes --confirm yes; then
      agents_status="applied"
    else
      agents_status="failed"
      error "Bitrix agents sync failed for ${domain}"
      return 1
    fi
  else
    agents_status="skipped (installer)"
  fi

  if [[ "$BX_HAS_CORE" == "yes" && ("$short_install" != "true" || "$agents_ready" == "yes") ]]; then
    if run_command bitrix cache-clear --domain "$domain"; then
      cache_status="cleared"
    else
      cache_status="failed"
      error "Bitrix cache clear failed for ${domain}"
      return 1
    fi
  else
    cache_status="skipped (installer)"
  fi

  ui_header "SIMAI ENV · Apply Bitrix optimization"
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Mode|${mode}" \
    "Site tune|applied (${site_mode})" \
    "PHP baseline|${php_status}" \
    "Agents sync|${agents_status}" \
    "Cache clear|${cache_status}"
  ui_section "Next steps"
  ui_kv "Review Bitrix status" "simai-admin.sh bitrix perf-status --domain ${BX_DOMAIN}"
}

register_cmd "bitrix" "status" "Show Bitrix status" "bitrix_status_handler" "domain" ""
register_cmd "bitrix" "cron-status" "Show Bitrix scheduler status" "bitrix_cron_status_handler" "domain" ""
register_cmd "bitrix" "cron-sync" "Write/rewrite Bitrix scheduler file" "bitrix_cron_sync_handler" "domain" ""
register_cmd "bitrix" "agents-status" "Show Bitrix agents-over-cron status" "bitrix_agents_status_handler" "domain" ""
register_cmd "bitrix" "agents-sync" "Plan/apply Bitrix agents-over-cron baseline" "bitrix_agents_sync_handler" "domain" "apply= confirm="
register_cmd "bitrix" "cache-clear" "Clear Bitrix cache directories" "bitrix_cache_clear_handler" "domain" ""
register_cmd "bitrix" "db-preseed" "Generate Bitrix DB config files from db.env" "bitrix_db_preseed_handler" "domain" "overwrite= short-install="
register_cmd "bitrix" "installer-ready" "Prepare Bitrix installer files (db preseed + setup script)" "bitrix_installer_ready_handler" "domain" "overwrite= short-install= setup-overwrite= archive= edition= archive-overwrite= unpack="
register_cmd "bitrix" "php-baseline-sync" "Apply Bitrix PHP INI baseline via site fix (single/all)" "bitrix_php_baseline_sync_handler" "" "domain= all= confirm= include-recommended="
register_cmd "bitrix" "perf-status" "Show Bitrix optimization status" "bitrix_perf_status_handler" "domain" ""
register_cmd "bitrix" "perf-apply" "Apply Bitrix optimization baseline" "bitrix_perf_apply_handler" "domain" "mode= confirm= include-recommended="

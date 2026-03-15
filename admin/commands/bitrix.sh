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
    perl -0777 -i -pe "s/define\\s*\\(\\s*(['\"])${esc}\\1\\s*,\\s*(true|false)\\s*\\)\\s*;/define(\"${const_name}\", true);/ig" "$file"
  fi
  if ! grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${esc}['\"][[:space:]]*," "$file"; then
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

bitrix_agents_ready_state() {
  local cron_managed="$1" cron_domain_match="$2" cron_slug_match="$3" cron_entry="$4" crontab="$5" crontab_support="$6"
  if [[ "$cron_managed" == "yes" && "$cron_domain_match" == "yes" && "$cron_slug_match" == "yes" && "$cron_entry" == "yes" && "$crontab" == "true" && "$crontab_support" == "true" ]]; then
    echo "yes"
    return 0
  fi
  echo "no"
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
  local cron_entrypoint="missing"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"

  [[ -f "$BX_SETTINGS_FILE" ]] && settings_present="yes"
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  [[ -s "$setup_script" ]] && setup_state="present"
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
    "BX_CRONTAB|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT|${bx_crontab_support}" \
    "SHORT_INSTALL|${short_install}" \
    "cron_events.php|${cron_entrypoint}" \
    "Cron file|${BX_CRON_FILE} (${cron_file_state})" \
    "Cron entry|${cron_line_state}" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}"
  ui_section "Next steps"
  ui_kv "Doctor" "simai-admin.sh site doctor --domain ${BX_DOMAIN}"
  ui_kv "Installer ready" "simai-admin.sh bitrix installer-ready --domain ${BX_DOMAIN}"
  ui_kv "Cron sync" "simai-admin.sh bitrix cron-sync --domain ${BX_DOMAIN}"
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

  ui_header "SIMAI ENV · Bitrix cron status"
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
    "Cron file|${BX_CRON_FILE} (${cron_file_state})" \
    "Cron line (cron_events.php)|${cron_line_state}" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}"
  ui_section "Next steps"
  ui_kv "Sync cron" "simai-admin.sh bitrix cron-sync --domain ${BX_DOMAIN}"
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
  ui_header "SIMAI ENV · Bitrix cron sync"
  cron_site_write "$BX_DOMAIN" "$BX_SLUG" "bitrix" "$BX_ROOT" "$BX_PHP_VERSION"
  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Cron file|${BX_CRON_FILE}" \
    "Profile|bitrix" \
    "PHP|${BX_PHP_VERSION}"
  ui_section "Next steps"
  ui_kv "Check cron" "simai-admin.sh bitrix cron-status --domain ${BX_DOMAIN}"
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
    "Cron file|${BX_CRON_FILE} (${cron_file_state})" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}" \
    "Cron entry (cron_events.php)|${cron_entry_match}" \
    "Agents via cron ready|${ready}"
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
    "Cron target|${BX_CRON_FILE}" \
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
  if ! bitrix_dbconn_set_const_true "$BX_DBCONN_FILE" "BX_CRONTAB"; then
    error "Failed to update BX_CRONTAB in ${BX_DBCONN_FILE}"
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
    "Cron file|${BX_CRON_FILE}" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}" \
    "Cron entry (cron_events.php)|${cron_entry_match}"
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
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"
  [[ "${setup_overwrite,,}" == "yes" ]] || setup_overwrite="no"

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
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if bitrix_download_setup_script "$BX_DOC_ROOT" "$setup_overwrite"; then
    setup_state="ready"
  fi
  local status="ready"
  [[ "$preseed_state" == "ready" && "$setup_state" == "ready" ]] || status="partial"

  ui_section "Result"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "DB preseed|${preseed_state}" \
    "SHORT_INSTALL|${short_install}" \
    "Setup script|${setup_state}" \
    "bitrixsetup.php|${setup_script}" \
    "Status|${status}"
  if [[ "$status" != "ready" ]]; then
    warn "Installer ready is partial. Check network access and db.env values."
    return 1
  fi
  ui_section "Next steps"
  ui_kv "Open installer" "https://${BX_DOMAIN}/bitrixsetup.php"
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
            "memory_limit|512M" \
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

register_cmd "bitrix" "status" "Show Bitrix operational status" "bitrix_status_handler" "domain" ""
register_cmd "bitrix" "cron-status" "Show Bitrix cron status" "bitrix_cron_status_handler" "domain" ""
register_cmd "bitrix" "cron-sync" "Write/rewrite Bitrix cron file" "bitrix_cron_sync_handler" "domain" ""
register_cmd "bitrix" "agents-status" "Show Bitrix agents-over-cron status" "bitrix_agents_status_handler" "domain" ""
register_cmd "bitrix" "agents-sync" "Plan/apply Bitrix agents-over-cron baseline" "bitrix_agents_sync_handler" "domain" "apply= confirm="
register_cmd "bitrix" "cache-clear" "Clear Bitrix cache directories" "bitrix_cache_clear_handler" "domain" ""
register_cmd "bitrix" "db-preseed" "Generate Bitrix DB config files from db.env" "bitrix_db_preseed_handler" "domain" "overwrite= short-install="
register_cmd "bitrix" "installer-ready" "Prepare Bitrix installer files (db preseed + setup script)" "bitrix_installer_ready_handler" "domain" "overwrite= short-install= setup-overwrite="
register_cmd "bitrix" "php-baseline-sync" "Apply Bitrix PHP INI baseline via site fix (single/all)" "bitrix_php_baseline_sync_handler" "" "domain= all= confirm= include-recommended="

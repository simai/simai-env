#!/usr/bin/env bash
set -euo pipefail

wp_cron_markers() {
  local cron_file="$1" domain="$2" slug="$3"
  WP_CRON_MANAGED="no"
  WP_CRON_DOMAIN_MATCH="no"
  WP_CRON_SLUG_MATCH="no"
  WP_CRON_ENTRY_MATCH="no"
  if [[ ! -f "$cron_file" ]]; then
    return 0
  fi
  grep -Eq "^# simai-managed: yes" "$cron_file" && WP_CRON_MANAGED="yes"
  grep -Eq "^# simai-domain: ${domain}$" "$cron_file" && WP_CRON_DOMAIN_MATCH="yes"
  grep -Eq "^# simai-slug: ${slug}$" "$cron_file" && WP_CRON_SLUG_MATCH="yes"
  grep -Eq "wp-cron\\.php" "$cron_file" && WP_CRON_ENTRY_MATCH="yes"
}

wp_prepare_site() {
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
  if [[ "$profile" != "wordpress" ]]; then
    error "WordPress commands are supported for wordpress profile only (got ${profile:-unknown})."
    return 2
  fi
  local root="${SITE_META[root]:-}"
  if ! validate_path "$root"; then
    return 1
  fi
  local public_dir
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then
    public_dir="public"
  else
    public_dir="${SITE_META[public_dir]}"
  fi
  local doc_root
  doc_root=$(site_compute_doc_root "$root" "$public_dir") || return 1
  local slug="${SITE_META[slug]:-${SITE_META[project]:-$(project_slug_from_domain "$domain")}}"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  local php_version="${SITE_META[php]:-}"
  WP_DOMAIN="$domain"
  WP_ROOT="$root"
  WP_DOC_ROOT="$doc_root"
  WP_SLUG="$slug"
  WP_PHP_VERSION="$php_version"
  WP_CRON_FILE="/etc/cron.d/${slug}"
  WP_CONFIG_FILE="${doc_root}/wp-config.php"
  WP_CRON_ENTRYPOINT="${doc_root}/wp-cron.php"
  WP_HAS_CORE="no"
  WP_CONFIG_READY="no"
  [[ -d "${doc_root}/wp-includes" && -f "${doc_root}/index.php" ]] && WP_HAS_CORE="yes"
  if [[ -f "$WP_CONFIG_FILE" ]]; then
    if grep -q "SIMAI placeholder" "$WP_CONFIG_FILE" 2>/dev/null; then
      WP_CONFIG_READY="placeholder"
    else
      WP_CONFIG_READY="yes"
    fi
  fi
  return 0
}

wp_state_summary() {
  WP_DB_STATE=$(wordpress_db_state_probe "$WP_DOMAIN")
  WP_WEB_STATE=$(wordpress_web_state_probe "$WP_DOMAIN")
  WP_INSTALL_STAGE=$(wordpress_install_stage "$WP_DB_STATE" "$WP_WEB_STATE")
  WP_INSTALLER_URL=$(wordpress_installer_open_url "$WP_DOMAIN")
  WP_ADMIN_URL="$(site_primary_url "$WP_DOMAIN")/wp-admin/"
}

wp_cron_disabled_state() {
  if [[ "${WP_CONFIG_READY:-no}" != "yes" ]]; then
    echo "unknown"
    return 0
  fi
  wordpress_wp_config_cron_mode "$WP_CONFIG_FILE"
}

wp_apply_optimization_mode() {
  local mode="$1"
  local site_mode="balanced"
  [[ "$mode" == "woocommerce-safe" ]] && site_mode="aggressive"
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$WP_SLUG}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$WP_DOMAIN")"
  fi
  local -a settings=()
  mapfile -t settings < <(site_perf_mode_defaults "wordpress" "$site_mode")
  write_site_perf_settings "$WP_DOMAIN" "${settings[@]}"
  apply_site_perf_settings_to_pool "$WP_DOMAIN" "$WP_PHP_VERSION" "$socket_project" || return 1
  cron_site_write "$WP_DOMAIN" "$WP_SLUG" "wordpress" "$WP_ROOT" "$WP_PHP_VERSION" || return 1

  WP_OPTIMIZATION_SITE_MODE="$site_mode"
  WP_OPTIMIZATION_CRON_SYNC="ok"
  WP_OPTIMIZATION_DISABLE_CRON="skipped"
  if [[ "${WP_CONFIG_READY:-no}" == "yes" ]]; then
    if wp_perf_set_disable_cron_true; then
      WP_OPTIMIZATION_DISABLE_CRON="true"
    else
      return 1
    fi
  elif [[ "${WP_CONFIG_READY:-no}" == "placeholder" ]]; then
    WP_OPTIMIZATION_DISABLE_CRON="skipped (placeholder)"
  fi
}

wp_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if wp_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · WordPress status"
  wp_state_summary
  local wp_cli="missing"
  local core_version="n/a"
  local config_present="${WP_CONFIG_READY:-no}"
  local cron_entrypoint="missing"
  local disable_wp_cron="unknown"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local ready_cli="no"
  local home_url="n/a"

  if command -v wp >/dev/null 2>&1; then
    wp_cli="present"
  fi
  disable_wp_cron=$(wp_cron_disabled_state)
  [[ -f "$WP_CRON_ENTRYPOINT" ]] && cron_entrypoint="present"
  if [[ -f "$WP_CRON_FILE" ]]; then
    cron_file_state="present"
    wp_cron_markers "$WP_CRON_FILE" "$WP_DOMAIN" "$WP_SLUG"
    cron_managed="${WP_CRON_MANAGED:-no}"
    cron_domain_match="${WP_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${WP_CRON_SLUG_MATCH:-no}"
    if [[ "${WP_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  if [[ "$wp_cli" == "present" && "$WP_HAS_CORE" == "yes" && "$config_present" == "yes" ]]; then
    ready_cli="yes"
  fi
  if [[ "$ready_cli" == "yes" ]]; then
    core_version=$(sudo -u "${SIMAI_USER:-simai}" -H wp core version --path="$WP_DOC_ROOT" 2>/dev/null || true)
    [[ -z "$core_version" ]] && core_version="unknown"
    home_url=$(timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp option get home --path="$WP_DOC_ROOT" 2>/dev/null || true)
    [[ -z "$home_url" ]] && home_url="unknown"
  fi

  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Docroot|${WP_DOC_ROOT}" \
    "Database state|${WP_DB_STATE}" \
    "Web state|${WP_WEB_STATE}" \
    "Install stage|${WP_INSTALL_STAGE}" \
    "WP-CLI|${wp_cli}" \
    "Core files|${WP_HAS_CORE}" \
    "Core version|${core_version}" \
    "wp-config.php|${config_present}" \
    "Ready for WP-CLI actions|${ready_cli}" \
    "Home URL|${home_url}" \
    "Built-in scheduler|${cron_entrypoint}" \
    "DISABLE_WP_CRON|${disable_wp_cron}" \
    "Server scheduler file|${WP_CRON_FILE} (${cron_file_state})" \
    "Server scheduler entry|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}"
  ui_next_steps
  case "$WP_WEB_STATE" in
    installer)
      ui_kv "Open installer" "${WP_INSTALLER_URL}"
      ui_kv "Complete setup" "simai-admin.sh wp finalize --domain ${WP_DOMAIN}"
      ;;
    installed)
      ui_kv "Open admin" "${WP_ADMIN_URL}"
      ui_kv "Complete setup" "simai-admin.sh wp finalize --domain ${WP_DOMAIN}"
      ;;
    *)
      ui_kv "Prepare installer" "simai-admin.sh wp installer-ready --domain ${WP_DOMAIN}"
      ui_kv "Open installer" "${WP_INSTALLER_URL}"
      ;;
  esac
  ui_kv "Doctor" "simai-admin.sh site doctor --domain ${WP_DOMAIN}"
}

wp_cron_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if wp_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · WordPress scheduler status"
  local config_present="${WP_CONFIG_READY:-no}"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local disable_wp_cron="unknown"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  if [[ -f "$WP_CRON_FILE" ]]; then
    cron_file_state="present"
    wp_cron_markers "$WP_CRON_FILE" "$WP_DOMAIN" "$WP_SLUG"
    cron_managed="${WP_CRON_MANAGED:-no}"
    cron_domain_match="${WP_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${WP_CRON_SLUG_MATCH:-no}"
    if [[ "${WP_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  if [[ "$config_present" == "yes" ]]; then
    disable_wp_cron=$(wp_cron_disabled_state)
  fi
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Scheduler file|${WP_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry (wp-cron.php)|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "DISABLE_WP_CRON|${disable_wp_cron}"
  ui_next_steps
  ui_kv "Sync scheduler" "simai-admin.sh wp cron-sync --domain ${WP_DOMAIN}"
}

wp_cron_sync_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if wp_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ -z "$WP_PHP_VERSION" || "$WP_PHP_VERSION" == "none" ]]; then
    error "WordPress site PHP version is missing for ${domain}."
    return 1
  fi
  ui_header "SIMAI ENV · WordPress scheduler sync"
  cron_site_write "$WP_DOMAIN" "$WP_SLUG" "wordpress" "$WP_ROOT" "$WP_PHP_VERSION"
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Scheduler file|${WP_CRON_FILE}" \
    "Profile|wordpress" \
    "PHP|${WP_PHP_VERSION}"
  ui_next_steps
  ui_kv "Check scheduler" "simai-admin.sh wp cron-status --domain ${WP_DOMAIN}"
}

wp_cache_clear_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if wp_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  ui_header "SIMAI ENV · WordPress cache clear"
  if ! command -v wp >/dev/null 2>&1; then
    error "wp-cli is not installed."
    return 1
  fi
  if [[ "$WP_HAS_CORE" != "yes" || "${WP_CONFIG_READY:-no}" != "yes" ]]; then
    error "WordPress core/config not ready in ${WP_DOC_ROOT}."
    return 1
  fi
  local cmd
  cmd="cd $(printf '%q' "$WP_DOC_ROOT") && wp cache flush --path=$(printf '%q' "$WP_DOC_ROOT")"
  if ! run_long "Flushing WordPress object cache" sudo -u "${SIMAI_USER:-simai}" -H bash -lc "$cmd"; then
    error "wp cache flush failed for ${WP_DOMAIN}"
    return 1
  fi
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Action|cache flush" \
    "Status|ok"
  ui_next_steps
  ui_kv "Check status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
}

wp_perf_read_mode() {
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

wp_perf_set_disable_cron_true() {
  [[ -f "$WP_CONFIG_FILE" ]] || return 1
  if grep -Eqi "DISABLE_WP_CRON[[:space:]]*,[[:space:]]*true" "$WP_CONFIG_FILE"; then
    return 0
  fi
  if grep -Eqi "DISABLE_WP_CRON" "$WP_CONFIG_FILE"; then
    perl -0pi -e "s/define\\((['\\\"])DISABLE_WP_CRON\\1\\s*,\\s*(true|false)\\s*\\);/define('DISABLE_WP_CRON', true);/ig" "$WP_CONFIG_FILE"
    return 0
  fi
  python3 - "$WP_CONFIG_FILE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = "/* That's all, stop editing!"
insert = "define('DISABLE_WP_CRON', true);\n\n"
if needle in text:
    text = text.replace(needle, insert + needle, 1)
else:
    needle2 = "require_once ABSPATH . 'wp-settings.php';"
    if needle2 in text:
        text = text.replace(needle2, insert + needle2, 1)
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += "\n" + insert
path.write_text(text)
PY
}

wp_perf_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  wp_prepare_site "$domain" || return $?

  local managed_mode
  managed_mode=$(wp_perf_read_mode "$domain")
  wp_state_summary
  local config_present="${WP_CONFIG_READY:-no}"
  local disable_wp_cron="unknown"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local home_url="n/a"
  local permalink_structure="n/a"
  local object_cache_dropin="missing"
  local redis_plugin="n/a"
  local redis_service="n/a"
  local redis_ext="no"
  local woo_plugin="n/a"
  if [[ "$config_present" == "yes" ]]; then
    disable_wp_cron=$(wp_cron_disabled_state)
  fi
  if [[ -f "$WP_CRON_FILE" ]]; then
    cron_file_state="present"
    wp_cron_markers "$WP_CRON_FILE" "$WP_DOMAIN" "$WP_SLUG"
    cron_managed="${WP_CRON_MANAGED:-no}"
    cron_domain_match="${WP_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${WP_CRON_SLUG_MATCH:-no}"
    if [[ "${WP_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  [[ -f "${WP_DOC_ROOT}/wp-content/object-cache.php" ]] && object_cache_dropin="present"
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_service="active"
    else
      redis_service="inactive"
    fi
  fi
  if [[ -n "$WP_PHP_VERSION" && "$WP_PHP_VERSION" != "none" ]]; then
    local php_bin=""
    php_bin=$(resolve_php_bin "$WP_PHP_VERSION")
    if [[ -n "$php_bin" ]] && "$php_bin" -m 2>/dev/null | grep -qi '^redis$'; then
      redis_ext="yes"
    fi
  fi
  if command -v wp >/dev/null 2>&1 && [[ "$WP_HAS_CORE" == "yes" && "$config_present" == "yes" ]]; then
    home_url=$(timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp option get home --path="$WP_DOC_ROOT" 2>/dev/null || true)
    [[ -z "$home_url" ]] && home_url="unknown"
    permalink_structure=$(timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp option get permalink_structure --path="$WP_DOC_ROOT" 2>/dev/null || true)
    [[ -z "$permalink_structure" ]] && permalink_structure="plain/default"
    if timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp plugin is-installed redis-cache --path="$WP_DOC_ROOT" >/dev/null 2>&1; then
      if timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp plugin is-active redis-cache --path="$WP_DOC_ROOT" >/dev/null 2>&1; then
        redis_plugin="active"
      else
        redis_plugin="installed"
      fi
    else
      redis_plugin="missing"
    fi
    if timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp plugin is-installed woocommerce --path="$WP_DOC_ROOT" >/dev/null 2>&1; then
      if timeout 15 sudo -u "${SIMAI_USER:-simai}" -H wp plugin is-active woocommerce --path="$WP_DOC_ROOT" >/dev/null 2>&1; then
        woo_plugin="active"
      else
        woo_plugin="installed"
      fi
    else
      woo_plugin="missing"
    fi
  fi

  ui_header "SIMAI ENV · WordPress optimization"
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Optimization mode|${managed_mode}" \
    "Docroot|${WP_DOC_ROOT}" \
    "Database state|${WP_DB_STATE}" \
    "Web state|${WP_WEB_STATE}" \
    "Install stage|${WP_INSTALL_STAGE}" \
    "PHP|${WP_PHP_VERSION:-none}" \
    "Core files|${WP_HAS_CORE}" \
    "wp-config.php|${config_present}" \
    "Home URL|${home_url}" \
    "Permalink structure|${permalink_structure}" \
    "DISABLE_WP_CRON|${disable_wp_cron}" \
    "Scheduler file|${WP_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "Object cache drop-in|${object_cache_dropin}" \
    "Redis plugin|${redis_plugin}" \
    "WooCommerce plugin|${woo_plugin}" \
    "Redis extension|${redis_ext}" \
    "Redis service|${redis_service}"
  ui_next_steps
  ui_kv "Site activity & optimization" "simai-admin.sh site perf-status --domain ${WP_DOMAIN}"
  ui_kv "Apply standard optimization" "simai-admin.sh wp perf-apply --domain ${WP_DOMAIN} --mode standard --confirm yes"
}

wp_perf_apply_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  local mode="${PARSED_ARGS[mode]:-standard}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    standard|woocommerce-safe) ;;
    *)
      error "Unsupported WordPress performance mode: ${mode}"
      return 1
      ;;
  esac
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply WordPress optimization changes"
    return 1
  fi

  wp_prepare_site "$domain" || return $?
  if [[ -z "$WP_PHP_VERSION" || "$WP_PHP_VERSION" == "none" ]]; then
    error "WordPress site PHP version is missing for ${domain}."
    return 1
  fi

  local site_mode="balanced"
  if ! wp_apply_optimization_mode "$mode"; then
    error "Failed to apply WordPress optimization for ${domain}"
    return 1
  fi
  site_mode="${WP_OPTIMIZATION_SITE_MODE:-balanced}"

  ui_header "SIMAI ENV · Apply WordPress optimization"
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Mode|${mode}" \
    "Site tune|applied (${site_mode})" \
    "Scheduler sync|${WP_OPTIMIZATION_CRON_SYNC:-ok}" \
    "DISABLE_WP_CRON|${WP_OPTIMIZATION_DISABLE_CRON:-skipped}"
  ui_next_steps
  ui_kv "Review WordPress status" "simai-admin.sh wp perf-status --domain ${WP_DOMAIN}"
}

wp_installer_ready_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local archive="${PARSED_ARGS[archive]:-yes}"
  local archive_overwrite="${PARSED_ARGS[archive-overwrite]:-${overwrite}}"
  local unpack="${PARSED_ARGS[unpack]:-yes}"
  local config_overwrite="${PARSED_ARGS[config-overwrite]:-${overwrite}}"
  local cli_install="${PARSED_ARGS[cli-install]:-yes}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${archive,,}" == "yes" ]] || archive="no"
  [[ "${archive_overwrite,,}" == "yes" ]] || archive_overwrite="no"
  [[ "${unpack,,}" == "yes" ]] || unpack="no"
  [[ "${config_overwrite,,}" == "yes" ]] || config_overwrite="no"
  [[ "${cli_install,,}" == "yes" ]] || cli_install="no"

  wp_prepare_site "$domain" || return $?
  ui_header "SIMAI ENV · WordPress installer ready"
  local cli_status="skipped"
  local archive_status="skipped"
  local unpack_status="skipped"
  local config_status="skipped"
  local overall="partial"

  if [[ "$cli_install" == "yes" ]]; then
    if wordpress_wp_cli_install; then
      cli_status="ready"
    else
      cli_status="failed"
      warn "Failed to install wp-cli"
    fi
  fi
  if [[ "$archive" == "yes" ]]; then
    if wordpress_download_distribution_archive "$WP_DOC_ROOT" "$archive_overwrite"; then
      archive_status="ready"
    else
      archive_status="failed"
      warn "Failed to download WordPress archive"
    fi
  fi
  if [[ "$unpack" == "yes" ]]; then
    if wordpress_unpack_distribution_archive "$WP_DOC_ROOT" "$overwrite"; then
      unpack_status="ready"
      WP_HAS_CORE="yes"
      if [[ -f "$WP_CONFIG_FILE" ]]; then
        if grep -q "SIMAI placeholder" "$WP_CONFIG_FILE" 2>/dev/null; then
          WP_CONFIG_READY="placeholder"
        else
          WP_CONFIG_READY="yes"
        fi
      fi
    else
      unpack_status="failed"
      warn "Failed to unpack WordPress archive"
    fi
  fi
  if wordpress_write_config "$WP_DOMAIN" "$WP_DOC_ROOT" "$config_overwrite"; then
    config_status="ready"
    WP_CONFIG_READY="yes"
  else
    config_status="failed"
    warn "Failed to generate wp-config.php from db.env"
  fi

  wp_state_summary
  if [[ "$unpack_status" == "ready" && "$config_status" == "ready" ]]; then
    overall="ready"
  fi

  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Docroot|${WP_DOC_ROOT}" \
    "WP-CLI|${cli_status}" \
    "Archive|${archive_status}" \
    "Unpack|${unpack_status}" \
    "wp-config.php|${config_status}" \
    "Database state|${WP_DB_STATE}" \
    "Web state|${WP_WEB_STATE}" \
    "Install stage|${WP_INSTALL_STAGE}" \
    "Status|${overall}"
  ui_next_steps
  ui_kv "Open installer" "${WP_INSTALLER_URL}"
  ui_kv "Status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
}

wp_finalize_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local ssl="${PARSED_ARGS[ssl]:-no}"
  local email="${PARSED_ARGS[email]:-}"
  local redirect="${PARSED_ARGS[redirect]:-no}"
  local hsts="${PARSED_ARGS[hsts]:-no}"
  local staging="${PARSED_ARGS[staging]:-no}"
  local mode="${PARSED_ARGS[mode]:-standard}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  [[ "${ssl,,}" == "yes" ]] || ssl="no"
  [[ "${redirect,,}" == "yes" ]] || redirect="no"
  [[ "${hsts,,}" == "yes" ]] || hsts="no"
  [[ "${staging,,}" == "yes" ]] || staging="no"
  case "$mode" in
    standard|woocommerce-safe) ;;
    *)
      error "Unsupported WordPress finalization mode: ${mode}"
      return 1
      ;;
  esac

  wp_prepare_site "$domain" || return $?
  wp_state_summary
  if [[ "$WP_INSTALL_STAGE" != "post-install" ]]; then
    ui_header "SIMAI ENV · WordPress complete setup"
    warn "WordPress web install is not completed yet."
    ui_result_table \
      "Domain|${WP_DOMAIN}" \
      "Database state|${WP_DB_STATE}" \
      "Web state|${WP_WEB_STATE}" \
      "Install stage|${WP_INSTALL_STAGE}"
    ui_next_steps
    ui_kv "Open installer" "${WP_INSTALLER_URL}"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to complete WordPress setup in CLI mode."
    return 1
  fi

  local cli_status="ready"
  if ! wordpress_wp_cli_install; then
    cli_status="failed"
    warn "wp-cli is not available; continuing with scheduler/optimization baseline"
  fi
  if ! wp_apply_optimization_mode "$mode"; then
    error "Failed to apply WordPress optimization baseline"
    return 1
  fi

  local ssl_status="not requested"
  if [[ "$ssl" == "yes" ]]; then
    if [[ -z "$email" ]]; then
      error "Use --email with --ssl yes to issue Let's Encrypt during finalize."
      return 1
    fi
    if run_command ssl letsencrypt --domain "$WP_DOMAIN" --email "$email" --redirect "$redirect" --hsts "$hsts" --staging "$staging"; then
      ssl_status="issued"
    else
      ssl_status="failed"
      warn "Let's Encrypt issuance failed for ${WP_DOMAIN}"
    fi
  fi

  ui_header "SIMAI ENV · WordPress complete setup"
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Install stage|${WP_INSTALL_STAGE}" \
    "WP-CLI|${cli_status}" \
    "Optimization|applied (${mode})" \
    "Scheduler sync|${WP_OPTIMIZATION_CRON_SYNC:-ok}" \
    "DISABLE_WP_CRON|${WP_OPTIMIZATION_DISABLE_CRON:-skipped}" \
    "SSL|${ssl_status}"
  ui_next_steps
  ui_kv "Open admin" "${WP_ADMIN_URL}"
  ui_kv "Status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
}

register_cmd "wp" "status" "Show WordPress status" "wp_status_handler" "domain" ""
register_cmd "wp" "cron-status" "Show WordPress scheduler status" "wp_cron_status_handler" "domain" ""
register_cmd "wp" "cron-sync" "Write/rewrite WordPress scheduler file" "wp_cron_sync_handler" "domain" ""
register_cmd "wp" "cache-clear" "Flush WordPress object cache (wp-cli)" "wp_cache_clear_handler" "domain" ""
register_cmd "wp" "perf-status" "Show WordPress optimization status" "wp_perf_status_handler" "" "domain="
register_cmd "wp" "perf-apply" "Apply WordPress optimization baseline" "wp_perf_apply_handler" "" "domain= mode= confirm="
register_cmd "wp" "installer-ready" "Prepare WordPress installer files (core + config + wp-cli)" "wp_installer_ready_handler" "domain" "overwrite= archive= archive-overwrite= unpack= config-overwrite= cli-install="
register_cmd "wp" "finalize" "Complete WordPress post-install baseline" "wp_finalize_handler" "domain" "confirm= ssl= email= redirect= hsts= staging= mode="

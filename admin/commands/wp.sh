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
  local public_dir="${SITE_META[public_dir]:-public}"
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
  [[ -d "${doc_root}/wp-includes" && -f "${doc_root}/index.php" ]] && WP_HAS_CORE="yes"
  return 0
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
  local wp_cli="missing"
  local core_version="n/a"
  local config_present="no"
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
  if [[ -f "$WP_CONFIG_FILE" ]]; then
    config_present="yes"
    if grep -Eqi "DISABLE_WP_CRON[[:space:]]*,[[:space:]]*true" "$WP_CONFIG_FILE"; then
      disable_wp_cron="true"
    else
      disable_wp_cron="false"
    fi
  fi
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

  ui_section "Result"
  print_kv_table \
    "Domain|${WP_DOMAIN}" \
    "Docroot|${WP_DOC_ROOT}" \
    "WP-CLI|${wp_cli}" \
    "Core files|${WP_HAS_CORE}" \
    "Core version|${core_version}" \
    "wp-config.php|${config_present}" \
    "Ready for WP-CLI actions|${ready_cli}" \
    "Home URL|${home_url}" \
    "wp-cron.php|${cron_entrypoint}" \
    "DISABLE_WP_CRON|${disable_wp_cron}" \
    "Cron file|${WP_CRON_FILE} (${cron_file_state})" \
    "Cron entry|${cron_line_state}" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}"
  ui_section "Next steps"
  ui_kv "Doctor" "simai-admin.sh site doctor --domain ${WP_DOMAIN}"
  ui_kv "Cron sync" "simai-admin.sh wp cron-sync --domain ${WP_DOMAIN}"
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

  ui_header "SIMAI ENV · WordPress cron status"
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
  if [[ -f "$WP_CONFIG_FILE" ]]; then
    if grep -Eqi "DISABLE_WP_CRON[[:space:]]*,[[:space:]]*true" "$WP_CONFIG_FILE"; then
      disable_wp_cron="true"
    else
      disable_wp_cron="false"
    fi
  fi
  ui_section "Result"
  print_kv_table \
    "Domain|${WP_DOMAIN}" \
    "Cron file|${WP_CRON_FILE} (${cron_file_state})" \
    "Cron line (wp-cron.php)|${cron_line_state}" \
    "Cron managed markers|${cron_managed}" \
    "Cron domain marker|${cron_domain_match}" \
    "Cron slug marker|${cron_slug_match}" \
    "DISABLE_WP_CRON|${disable_wp_cron}"
  ui_section "Next steps"
  ui_kv "Sync cron" "simai-admin.sh wp cron-sync --domain ${WP_DOMAIN}"
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
  ui_header "SIMAI ENV · WordPress cron sync"
  cron_site_write "$WP_DOMAIN" "$WP_SLUG" "wordpress" "$WP_ROOT" "$WP_PHP_VERSION"
  ui_section "Result"
  print_kv_table \
    "Domain|${WP_DOMAIN}" \
    "Cron file|${WP_CRON_FILE}" \
    "Profile|wordpress" \
    "PHP|${WP_PHP_VERSION}"
  ui_section "Next steps"
  ui_kv "Check cron" "simai-admin.sh wp cron-status --domain ${WP_DOMAIN}"
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
  if [[ "$WP_HAS_CORE" != "yes" || ! -f "$WP_CONFIG_FILE" ]]; then
    error "WordPress core/config not ready in ${WP_DOC_ROOT}."
    return 1
  fi
  local cmd
  cmd="cd $(printf '%q' "$WP_DOC_ROOT") && wp cache flush --path=$(printf '%q' "$WP_DOC_ROOT")"
  if ! run_long "Flushing WordPress object cache" sudo -u "${SIMAI_USER:-simai}" -H bash -lc "$cmd"; then
    error "wp cache flush failed for ${WP_DOMAIN}"
    return 1
  fi
  ui_section "Result"
  print_kv_table \
    "Domain|${WP_DOMAIN}" \
    "Action|cache flush" \
    "Status|ok"
  ui_section "Next steps"
  ui_kv "Check status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
}

register_cmd "wp" "status" "Show WordPress operational status" "wp_status_handler" "domain" ""
register_cmd "wp" "cron-status" "Show WordPress cron status" "wp_cron_status_handler" "domain" ""
register_cmd "wp" "cron-sync" "Write/rewrite WordPress cron file" "wp_cron_sync_handler" "domain" ""
register_cmd "wp" "cache-clear" "Flush WordPress object cache (wp-cli)" "wp_cache_clear_handler" "domain" ""

#!/usr/bin/env bash
set -euo pipefail

cron_add_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -A meta=()
  if ! site_nginx_metadata_parse "$cfg" meta; then
    error "Nginx metadata not found for ${domain}."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  local profile="${meta[profile]:-}"
  local slug="${meta[slug]:-}"
  local root="${meta[root]:-}"
  local php="${meta[php]:-}"
  if [[ -z "$slug" || -z "$profile" || -z "$root" || -z "$php" ]]; then
    error "Site metadata incomplete for ${domain}. Refusing to guess."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  if [[ "$profile" != "laravel" ]]; then
    error "Cron add is supported for laravel profile only (got ${profile})."
    return 1
  fi
  local user="${PARSED_ARGS[user]:-${SIMAI_USER:-simai}}"
  local prev_user="${SIMAI_USER:-simai}"
  SIMAI_USER="$user"
  ui_header "SIMAI ENV · Enable Laravel scheduler"
  cron_site_write "$domain" "$slug" "$profile" "$root" "$php"
  SIMAI_USER="$prev_user"
  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Scheduler file|/etc/cron.d/${slug}" \
    "PHP|${php}" \
    "User|${user}"
  ui_section "Next steps"
  ui_kv "Disable scheduler" "simai-admin.sh cron remove --domain ${domain}"
  ui_kv "Review worker status" "simai-admin.sh queue status --domain ${domain}"
}

cron_remove_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -A meta=()
  if ! site_nginx_metadata_parse "$cfg" meta; then
    error "Nginx metadata not found for ${domain}. Refusing to guess slug."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  local slug="${meta[slug]:-}"
  if [[ -z "$slug" ]]; then
    error "Metadata slug missing for ${domain}. Refusing to guess."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  ui_header "SIMAI ENV · Disable Laravel scheduler"
  remove_cron_file "$slug" "$domain"
  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Scheduler file|/etc/cron.d/${slug}" \
    "State|removed"
  ui_section "Next steps"
  ui_kv "Enable scheduler" "simai-admin.sh cron add --domain ${domain}"
  ui_kv "Review site status" "simai-admin.sh site info --domain ${domain}"
}

register_cmd "cron" "add" "Enable schedule:run scheduler entry for site" "cron_add_handler" "domain" "user="
register_cmd "cron" "remove" "Disable schedule:run scheduler entry for site" "cron_remove_handler" "domain" ""

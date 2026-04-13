#!/usr/bin/env bash
set -euo pipefail

laravel_perf_select_domain() {
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  if [[ "${SITE_META[profile]:-}" != "laravel" ]]; then
    error "Laravel performance commands are supported for laravel profile only."
    return 2
  fi
  echo "$domain"
}

laravel_perf_prepare_site() {
  local domain="$1"
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  require_site_exists "$domain" || return 1
  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  local profile="${SITE_META[profile]:-}"
  if [[ "$profile" != "laravel" ]]; then
    error "Laravel performance commands are supported for laravel profile only (got ${profile:-unknown})."
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
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local slug="${SITE_META[slug]:-$project}"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  local php_version="${SITE_META[php]:-}"
  local php_bin=""
  if [[ -n "$php_version" && "$php_version" != "none" ]]; then
    php_bin=$(resolve_php_bin "$php_version")
  fi
  LARAVEL_PERF_DOMAIN="$domain"
  LARAVEL_PERF_ROOT="$root"
  LARAVEL_PERF_DOC_ROOT="$doc_root"
  LARAVEL_PERF_PROJECT="$project"
  LARAVEL_PERF_SLUG="$slug"
  LARAVEL_PERF_PHP_VERSION="$php_version"
  LARAVEL_PERF_PHP_BIN="$php_bin"
  LARAVEL_PERF_ARTISAN="${root}/artisan"
  LARAVEL_PERF_CRON_FILE="/etc/cron.d/${slug}"
  LARAVEL_PERF_CONFIG_CACHE="${root}/bootstrap/cache/config.php"
  LARAVEL_PERF_EVENT_CACHE="${root}/bootstrap/cache/events.php"
  LARAVEL_PERF_VIEWS_DIR="${root}/storage/framework/views"
  LARAVEL_PERF_REAL_APP="no"
  if laravel_queue_has_real_app "$root"; then
    LARAVEL_PERF_REAL_APP="yes"
  fi
  local route_cache=""
  route_cache=$(find "${root}/bootstrap/cache" -maxdepth 1 -type f -name 'routes*.php' 2>/dev/null | head -n1 || true)
  LARAVEL_PERF_ROUTE_CACHE="${route_cache:-}"
}

laravel_state_summary() {
  LARAVEL_DB_STATE=$(laravel_db_state_probe "$LARAVEL_PERF_DOMAIN")
  LARAVEL_WEB_STATE=$(laravel_web_state_probe "$LARAVEL_PERF_DOMAIN" "$LARAVEL_PERF_ROOT")
  LARAVEL_APP_STATE=$(laravel_app_state "$LARAVEL_PERF_ROOT")
  LARAVEL_APP_KEY_STATE=$(laravel_app_key_state "$LARAVEL_PERF_ROOT")
  LARAVEL_SETUP_STAGE=$(laravel_setup_stage "$LARAVEL_APP_STATE" "$LARAVEL_WEB_STATE" "$LARAVEL_APP_KEY_STATE")
  LARAVEL_ENV_FILE="$(laravel_env_file_path "$LARAVEL_PERF_ROOT")"
  LARAVEL_APP_URL=$(laravel_env_get "$LARAVEL_ENV_FILE" "APP_URL" 2>/dev/null || true)
  [[ -z "$LARAVEL_APP_URL" ]] && LARAVEL_APP_URL="$(site_primary_url "$LARAVEL_PERF_DOMAIN")"
}

laravel_queue_status_summary() {
  LARAVEL_QUEUE_UNIT="missing"
  LARAVEL_QUEUE_STATE="n/a"
  if validate_project_slug "$LARAVEL_PERF_PROJECT"; then
    LARAVEL_QUEUE_UNIT=$(queue_unit_name "$LARAVEL_PERF_PROJECT") || LARAVEL_QUEUE_UNIT="missing"
    if os_svc_has_unit "$LARAVEL_QUEUE_UNIT"; then
      if os_svc_is_active "$LARAVEL_QUEUE_UNIT"; then
        LARAVEL_QUEUE_STATE="active"
      else
        LARAVEL_QUEUE_STATE="inactive"
      fi
    else
      LARAVEL_QUEUE_STATE="missing"
    fi
  fi
}

laravel_prepare_runtime_env() {
  laravel_prepare_env_file "$LARAVEL_PERF_DOMAIN" "$LARAVEL_PERF_ROOT"
  return 0
}

laravel_bootstrap_project() {
  if [[ "$LARAVEL_PERF_REAL_APP" == "yes" ]]; then
    return 0
  fi
  if ! command -v composer >/dev/null 2>&1; then
    error "composer is not installed on this server"
    return 1
  fi
  local tmpdir app_dir cmd
  tmpdir=$(mktemp -d)
  chown "${SIMAI_USER:-simai}:www-data" "$tmpdir" 2>/dev/null || true
  app_dir="${tmpdir}/app"
  cmd="cd /tmp && composer create-project --no-interaction --prefer-dist $(printf '%q' "$(laravel_distribution_package)") $(printf '%q' "$app_dir")"
  if ! run_long "Creating Laravel application" sudo -u "${SIMAI_USER:-simai}" -H bash -lc "$cmd"; then
    rm -rf "$tmpdir"
    return 1
  fi
  cp -a "${app_dir}/." "${LARAVEL_PERF_ROOT}/" || {
    rm -rf "$tmpdir"
    return 1
  }
  rm -rf "$tmpdir"
  ensure_project_permissions "$LARAVEL_PERF_ROOT"
  install_healthcheck "$LARAVEL_PERF_DOC_ROOT"
  return 0
}

laravel_finalize_run_artisan() {
  local action="$1"
  local cmd
  cmd="cd $(printf '%q' "$LARAVEL_PERF_ROOT") && $(printf '%q' "$LARAVEL_PERF_PHP_BIN") artisan ${action}"
  run_long "artisan ${action}" sudo -u "${SIMAI_USER:-simai}" -H bash -lc "$cmd"
}

laravel_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  laravel_perf_prepare_site "$domain" || return $?
  laravel_state_summary
  laravel_queue_status_summary

  local composer_state="missing"
  composer_state=$(laravel_composer_state)
  local env_state="missing"
  [[ -f "$LARAVEL_ENV_FILE" ]] && env_state="present"
  local cron_state="missing"
  [[ -f "$LARAVEL_PERF_CRON_FILE" ]] && cron_state="present"

  ui_header "SIMAI ENV · Laravel status"
  ui_section "Result"
  print_kv_table \
    "Domain|${LARAVEL_PERF_DOMAIN}" \
    "Root|${LARAVEL_PERF_ROOT}" \
    "Docroot|${LARAVEL_PERF_DOC_ROOT}" \
    "Database state|${LARAVEL_DB_STATE}" \
    "Web state|${LARAVEL_WEB_STATE}" \
    "Application state|${LARAVEL_APP_STATE}" \
    "Setup stage|${LARAVEL_SETUP_STAGE}" \
    "Composer|${composer_state}" \
    ".env|${env_state}" \
    "APP_KEY|${LARAVEL_APP_KEY_STATE}" \
    "Application URL|${LARAVEL_APP_URL}" \
    "Scheduler file|${LARAVEL_PERF_CRON_FILE} (${cron_state})" \
    "Worker unit|${LARAVEL_QUEUE_UNIT}" \
    "Worker status|${LARAVEL_QUEUE_STATE}"
  ui_section "Next steps"
  case "$LARAVEL_SETUP_STAGE" in
    placeholder)
      ui_kv "Prepare app" "simai-admin.sh laravel app-ready --domain ${LARAVEL_PERF_DOMAIN}"
      ui_kv "Open site" "$(site_primary_url "$LARAVEL_PERF_DOMAIN")"
      ;;
    app-ready)
      ui_kv "Complete setup" "simai-admin.sh laravel finalize --domain ${LARAVEL_PERF_DOMAIN}"
      ui_kv "Open site" "$(site_primary_url "$LARAVEL_PERF_DOMAIN")"
      ;;
    post-install)
      ui_kv "Open site" "$(site_primary_url "$LARAVEL_PERF_DOMAIN")"
      ui_kv "Optimization status" "simai-admin.sh laravel perf-status --domain ${LARAVEL_PERF_DOMAIN}"
      ;;
    *)
      ui_kv "Prepare app" "simai-admin.sh laravel app-ready --domain ${LARAVEL_PERF_DOMAIN}"
      ui_kv "Doctor" "simai-admin.sh site doctor --domain ${LARAVEL_PERF_DOMAIN}"
      ;;
  esac
}

laravel_app_ready_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  laravel_perf_prepare_site "$domain" || return $?

  ui_header "SIMAI ENV · Laravel prepare app"
  local composer_state="missing"
  composer_state=$(laravel_composer_state)
  local bootstrap_status="ready"
  local env_status="ready"
  if [[ "$composer_state" != "present" ]]; then
    error "composer is not installed on this server"
    return 1
  fi
  if ! laravel_bootstrap_project; then
    error "Failed to create Laravel application in ${LARAVEL_PERF_ROOT}"
    return 1
  fi
  laravel_perf_prepare_site "$domain" || return $?
  if ! laravel_prepare_runtime_env; then
    env_status="failed"
    error "Failed to prepare Laravel .env for ${LARAVEL_PERF_DOMAIN}"
    return 1
  fi
  laravel_state_summary
  ui_section "Result"
  print_kv_table \
    "Domain|${LARAVEL_PERF_DOMAIN}" \
    "Composer|${composer_state}" \
    "Bootstrap|${bootstrap_status}" \
    ".env|${env_status}" \
    "Database state|${LARAVEL_DB_STATE}" \
    "Web state|${LARAVEL_WEB_STATE}" \
    "Application state|${LARAVEL_APP_STATE}" \
    "Setup stage|${LARAVEL_SETUP_STAGE}" \
    "Status|ready"
  ui_section "Next steps"
  ui_kv "Complete setup" "simai-admin.sh laravel finalize --domain ${LARAVEL_PERF_DOMAIN}"
  ui_kv "Status" "simai-admin.sh laravel status --domain ${LARAVEL_PERF_DOMAIN}"
}

laravel_perf_read_mode() {
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

laravel_perf_apply_site_mode() {
  local domain="$1" profile="$2" mode="$3" php_version="$4" socket_project="$5"
  local -a settings=()
  mapfile -t settings < <(site_perf_mode_defaults "$profile" "$mode")
  if [[ ${#settings[@]} -eq 0 ]]; then
    error "Failed to derive site performance defaults for ${mode}"
    return 1
  fi
  write_site_perf_settings "$domain" "${settings[@]}"
  apply_site_perf_settings_to_pool "$domain" "$php_version" "$socket_project"
}

laravel_perf_run_artisan() {
  local action="$1"
  local cmd
  cmd="cd $(printf '%q' "$LARAVEL_PERF_ROOT") && $(printf '%q' "$LARAVEL_PERF_PHP_BIN") artisan ${action}"
  run_long "artisan ${action}" sudo -u "${SIMAI_USER:-simai}" -H bash -lc "$cmd"
}

laravel_perf_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(laravel_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  laravel_perf_prepare_site "$domain" || return $?
  laravel_state_summary
  laravel_queue_status_summary

  local managed_mode="none"
  managed_mode=$(laravel_perf_read_mode "$domain")
  local artisan_state="missing"
  [[ -f "$LARAVEL_PERF_ARTISAN" ]] && artisan_state="present"
  local config_cache="missing"
  [[ -f "$LARAVEL_PERF_CONFIG_CACHE" ]] && config_cache="present"
  local route_cache="missing"
  [[ -n "${LARAVEL_PERF_ROUTE_CACHE:-}" ]] && route_cache="$(basename "$LARAVEL_PERF_ROUTE_CACHE")"
  local event_cache="missing"
  [[ -f "$LARAVEL_PERF_EVENT_CACHE" ]] && event_cache="present"
  local views_state="missing"
  local views_count="0"
  if [[ -d "$LARAVEL_PERF_VIEWS_DIR" ]]; then
    views_state="present"
    views_count=$(find "$LARAVEL_PERF_VIEWS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  local cron_state="missing"
  [[ -f "$LARAVEL_PERF_CRON_FILE" ]] && cron_state="present"
  local redis_service="n/a"
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_service="active"
    else
      redis_service="inactive"
    fi
  fi
  local redis_ext="no"
  if [[ -n "$LARAVEL_PERF_PHP_BIN" ]] && "$LARAVEL_PERF_PHP_BIN" -m 2>/dev/null | grep -qi '^redis$'; then
    redis_ext="yes"
  fi

  ui_header "SIMAI ENV · Laravel optimization"
  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Optimization mode|${managed_mode}" \
    "Root|${LARAVEL_PERF_ROOT}" \
    "Database state|${LARAVEL_DB_STATE}" \
    "Web state|${LARAVEL_WEB_STATE}" \
    "Setup stage|${LARAVEL_SETUP_STAGE}" \
    "PHP|${LARAVEL_PERF_PHP_VERSION:-none}" \
    "Artisan|${artisan_state}" \
    "Real app|${LARAVEL_PERF_REAL_APP}" \
    ".env|$( [[ -f "$LARAVEL_ENV_FILE" ]] && echo present || echo missing )" \
    "APP_KEY|${LARAVEL_APP_KEY_STATE}" \
    "Config cache|${config_cache}" \
    "Route cache|${route_cache}" \
    "Event cache|${event_cache}" \
    "Compiled views|${views_state} (${views_count})" \
    "Cron file|${LARAVEL_PERF_CRON_FILE} (${cron_state})" \
    "Queue unit|${LARAVEL_QUEUE_UNIT}" \
    "Queue state|${LARAVEL_QUEUE_STATE}" \
    "Redis extension|${redis_ext}" \
    "Redis service|${redis_service}"
  ui_section "Next steps"
  ui_kv "Site activity & optimization" "simai-admin.sh site perf-status --domain ${domain}"
  ui_kv "Apply balanced optimization" "simai-admin.sh laravel perf-apply --domain ${domain} --mode balanced --confirm yes"
}

laravel_finalize_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local ssl="${PARSED_ARGS[ssl]:-no}"
  local email="${PARSED_ARGS[email]:-}"
  local redirect="${PARSED_ARGS[redirect]:-no}"
  local hsts="${PARSED_ARGS[hsts]:-no}"
  local staging="${PARSED_ARGS[staging]:-no}"
  local mode="${PARSED_ARGS[mode]:-balanced}"
  local migrate="${PARSED_ARGS[migrate]:-no}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  [[ "${ssl,,}" == "yes" ]] || ssl="no"
  [[ "${redirect,,}" == "yes" ]] || redirect="no"
  [[ "${hsts,,}" == "yes" ]] || hsts="no"
  [[ "${staging,,}" == "yes" ]] || staging="no"
  [[ "${migrate,,}" == "yes" ]] || migrate="no"
  case "$mode" in
    safe|balanced|aggressive) ;;
    *)
      error "Unsupported Laravel finalization mode: ${mode}"
      return 1
      ;;
  esac

  laravel_perf_prepare_site "$domain" || return $?
  laravel_state_summary
  if [[ "$LARAVEL_SETUP_STAGE" == "placeholder" ]]; then
    ui_header "SIMAI ENV · Laravel complete setup"
    warn "Laravel application bootstrap is not completed yet."
    ui_section "Result"
    print_kv_table \
      "Domain|${LARAVEL_PERF_DOMAIN}" \
      "Database state|${LARAVEL_DB_STATE}" \
      "Web state|${LARAVEL_WEB_STATE}" \
      "Application state|${LARAVEL_APP_STATE}" \
      "Setup stage|${LARAVEL_SETUP_STAGE}"
    ui_section "Next steps"
    ui_kv "Prepare app" "simai-admin.sh laravel app-ready --domain ${LARAVEL_PERF_DOMAIN}"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to complete Laravel setup in CLI mode."
    return 1
  fi
  if [[ -z "${LARAVEL_PERF_PHP_VERSION:-}" || "${LARAVEL_PERF_PHP_VERSION}" == "none" ]]; then
    error "Laravel site PHP version is not configured for ${domain}"
    return 1
  fi

  local env_status="ready"
  if ! laravel_prepare_runtime_env; then
    env_status="failed"
    error "Failed to prepare Laravel .env"
    return 1
  fi

  local app_key_status="present"
  if [[ "$(laravel_app_key_state "$LARAVEL_PERF_ROOT")" != "set" ]]; then
    if laravel_finalize_run_artisan "key:generate --force"; then
      app_key_status="generated"
    else
      app_key_status="failed"
      error "Failed to generate APP_KEY for ${domain}"
      return 1
    fi
  fi

  local storage_link_status="ok"
  laravel_finalize_run_artisan "storage:link" || storage_link_status="failed"

  local migrate_status="skipped"
  if [[ "$migrate" == "yes" ]]; then
    if laravel_finalize_run_artisan "migrate --force"; then
      migrate_status="ok"
    else
      migrate_status="failed"
      error "Laravel migrations failed for ${domain}"
      return 1
    fi
  fi

  local socket_project="${SITE_META[php_socket_project]:-${LARAVEL_PERF_PROJECT}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi
  if ! laravel_perf_apply_site_mode "$domain" "laravel" "$mode" "$LARAVEL_PERF_PHP_VERSION" "$socket_project"; then
    error "Failed to apply Laravel site optimization baseline"
    return 1
  fi

  local cron_status="ok"
  cron_site_write "$domain" "$LARAVEL_PERF_SLUG" "laravel" "$LARAVEL_PERF_ROOT" "$LARAVEL_PERF_PHP_VERSION" || cron_status="failed"
  if [[ "$cron_status" == "failed" ]]; then
    error "Failed to rewrite Laravel scheduler file"
    return 1
  fi

  local optimize_status="ok"
  laravel_finalize_run_artisan "config:cache" || optimize_status="failed"
  if [[ "$optimize_status" == "ok" ]]; then
    laravel_finalize_run_artisan "view:cache" || optimize_status="failed"
  fi
  if [[ "$optimize_status" == "failed" ]]; then
    error "Laravel optimization sequence failed for ${domain}"
    return 1
  fi

  local ssl_status="not requested"
  if [[ "$ssl" == "yes" ]]; then
    if [[ -z "$email" ]]; then
      error "Use --email with --ssl yes to issue Let's Encrypt during finalize."
      return 1
    fi
    if run_command ssl letsencrypt --domain "$LARAVEL_PERF_DOMAIN" --email "$email" --redirect "$redirect" --hsts "$hsts" --staging "$staging"; then
      ssl_status="issued"
    else
      ssl_status="failed"
      warn "Let's Encrypt issuance failed for ${LARAVEL_PERF_DOMAIN}"
    fi
  fi

  laravel_state_summary
  ui_header "SIMAI ENV · Laravel complete setup"
  ui_section "Result"
  print_kv_table \
    "Domain|${LARAVEL_PERF_DOMAIN}" \
    "Setup stage|${LARAVEL_SETUP_STAGE}" \
    ".env|${env_status}" \
    "APP_KEY|${app_key_status}" \
    "Storage link|${storage_link_status}" \
    "Migrations|${migrate_status}" \
    "Optimization|applied (${mode})" \
    "Scheduler sync|${cron_status}" \
    "Artisan optimize|${optimize_status}" \
    "SSL|${ssl_status}"
  ui_section "Next steps"
  ui_kv "Open site" "$(site_primary_url "$LARAVEL_PERF_DOMAIN")"
  ui_kv "Status" "simai-admin.sh laravel status --domain ${LARAVEL_PERF_DOMAIN}"
}

laravel_perf_apply_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(laravel_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  local mode="${PARSED_ARGS[mode]:-balanced}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    safe|balanced|aggressive) ;;
    *)
      error "Unsupported Laravel performance mode: ${mode}"
      return 1
      ;;
  esac
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply Laravel optimization changes"
    return 1
  fi

  laravel_perf_prepare_site "$domain" || return $?
  if [[ -z "${LARAVEL_PERF_PHP_VERSION:-}" || "${LARAVEL_PERF_PHP_VERSION}" == "none" ]]; then
    error "Laravel site PHP version is not configured for ${domain}"
    return 1
  fi

  local socket_project="${SITE_META[php_socket_project]:-${LARAVEL_PERF_PROJECT}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi
  laravel_perf_apply_site_mode "$domain" "laravel" "$mode" "$LARAVEL_PERF_PHP_VERSION" "$socket_project" || return 1

  local cron_status="ok"
  local optimize_status="skipped"
  local queue_status="skipped"

  cron_site_write "$domain" "$LARAVEL_PERF_SLUG" "laravel" "$LARAVEL_PERF_ROOT" "$LARAVEL_PERF_PHP_VERSION" || cron_status="failed"
  if [[ "$cron_status" == "failed" ]]; then
    error "Failed to rewrite cron for ${domain}"
    return 1
  fi

  if [[ "$LARAVEL_PERF_REAL_APP" == "yes" && -f "$LARAVEL_PERF_ARTISAN" && -n "$LARAVEL_PERF_PHP_BIN" ]]; then
    optimize_status="ok"
    laravel_perf_run_artisan "config:cache" || optimize_status="failed"
    if [[ "$optimize_status" == "ok" ]]; then
      laravel_perf_run_artisan "view:cache" || optimize_status="failed"
    fi
    if [[ "$optimize_status" == "failed" ]]; then
      error "Laravel optimize sequence failed for ${domain}"
      return 1
    fi
  fi

  local queue_unit=""
  if validate_project_slug "$LARAVEL_PERF_PROJECT"; then
    queue_unit=$(queue_unit_name "$LARAVEL_PERF_PROJECT" 2>/dev/null || true)
  fi
  if [[ "$LARAVEL_PERF_REAL_APP" != "yes" ]]; then
    queue_status="skipped (placeholder)"
  elif [[ -n "$queue_unit" ]] && os_svc_has_unit "$queue_unit"; then
    if os_svc_restart "$queue_unit"; then
      queue_status="restarted"
    else
      queue_status="restart-failed"
      warn "Failed to restart ${queue_unit} after Laravel performance apply"
    fi
  fi

  ui_header "SIMAI ENV · Apply Laravel optimization"
  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Mode|${mode}" \
    "Site tune|applied" \
    "Cron sync|${cron_status}" \
    "Artisan optimize|${optimize_status}" \
    "Queue restart|${queue_status}"
  ui_section "Next steps"
  ui_kv "Review Laravel status" "simai-admin.sh laravel perf-status --domain ${domain}"
}

register_cmd "laravel" "status" "Show Laravel status" "laravel_status_handler" "domain" ""
register_cmd "laravel" "app-ready" "Bootstrap Laravel application (composer scaffold + env)" "laravel_app_ready_handler" "domain" ""
register_cmd "laravel" "finalize" "Complete Laravel post-bootstrap baseline" "laravel_finalize_handler" "domain" "confirm= ssl= email= redirect= hsts= staging= mode= migrate="
register_cmd "laravel" "perf-status" "Show Laravel optimization status" "laravel_perf_status_handler" "" "domain="
register_cmd "laravel" "perf-apply" "Apply Laravel optimization baseline" "laravel_perf_apply_handler" "" "domain= mode= confirm="

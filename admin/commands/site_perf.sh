#!/usr/bin/env bash

site_usage_select_class() {
  local usage="${1:-}"
  if [[ -n "$usage" ]]; then
    site_usage_class_normalize "$usage"
    return $?
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list \
      $'Select site activity\nstandard = balanced everyday use\nhigh-traffic = more resources for busy sites\nrarely-used = lower footprint for idle sites' \
      "standard" \
      "standard" \
      "high-traffic" \
      "rarely-used")
    [[ -z "$choice" ]] && {
      command_cancelled
      return $?
    }
    site_usage_class_normalize "$choice"
    return $?
  fi
  echo "standard"
}

site_perf_select_domain() {
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    if [[ ${#sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" ]]; then
    require_args "domain" || return 1
    domain="${PARSED_ARGS[domain]:-}"
  fi
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  require_site_exists "$domain" || return 1
  echo "$domain"
}

site_usage_apply_class() {
  local domain="$1" usage_class="$2" confirm="${3:-yes}"
  local perf_mode
  usage_class=$(site_usage_class_normalize "$usage_class") || {
    error "Unsupported site usage class: ${usage_class}"
    return 1
  }
  perf_mode=$(site_usage_class_to_perf_mode "$usage_class") || return 1

  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  local profile="${SITE_META[profile]:-unknown}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local php_version="${SITE_META[php]:-none}"

  if [[ "$php_version" != "none" && -n "$php_version" ]]; then
    local settings=()
    mapfile -t settings < <(site_perf_mode_defaults "$profile" "$perf_mode")
    if [[ ${#settings[@]} -eq 0 ]]; then
      error "Failed to derive settings for usage class ${usage_class}"
      return 1
    fi
    settings+=("usage_class|${usage_class}")
    write_site_perf_settings_merged "$domain" "${settings[@]}"
    if ! validate_project_slug "$socket_project"; then
      socket_project="$(project_slug_from_domain "$domain")"
    fi
    apply_site_perf_settings_to_pool "$domain" "$php_version" "$socket_project" || return 1
  else
    write_site_perf_settings_merged "$domain" "usage_class|${usage_class}"
  fi
  return 0
}

site_perf_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0

  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi

  local profile="${SITE_META[profile]:-unknown}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local php_version="${SITE_META[php]:-none}"
  local pool_file="n/a"
  local mode="none"
  local pm="n/a" max_children="n/a" idle_timeout="n/a" max_requests="n/a" req_timeout="n/a"
  local memory_limit="n/a" memory_risk="n/a"
  local opcache_ext="n/a" redis_ext="n/a" redis_service="n/a"
  local cron_summary="n/a" queue_summary="n/a"
  local php_bin=""
  local pool_service="n/a" pool_socket="n/a" pool_socket_state="n/a" pool_error_log="n/a"
  local total_children="0" pool_share="unknown" fpm_budget="0" fpm_oversub="unknown" mem_available="unknown"
  local runtime_state
  runtime_state=$(site_runtime_state "$domain")
  local usage_class
  usage_class=$(site_usage_class_get "$domain")
  local auto_optimize_state auto_optimize_effective
  auto_optimize_state=$(site_auto_optimize_state_get "$domain")
  auto_optimize_effective=$(site_auto_optimize_effective_enabled "$domain")
  local optimization_mode optimization_recommendation
  optimization_mode=$(site_user_optimization_mode "$domain")

  declare -A perf_settings=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    perf_settings["${entry%%|*}"]="${entry#*|}"
  done < <(read_site_perf_settings "$domain")
  [[ -n "${perf_settings[mode]:-}" ]] && mode="${perf_settings[mode]}"

  if load_profile "$profile"; then
    if [[ "${PROFILE_SUPPORTS_CRON:-no}" == "yes" ]]; then
      cron_summary=$(site_cron_file_status "${SITE_META[slug]:-$project}")
    fi
    if [[ "${PROFILE_SUPPORTS_QUEUE:-no}" == "yes" ]]; then
      queue_summary=$(site_worker_status "$project")
    fi
  fi

  if [[ "$php_version" != "none" && -n "$socket_project" ]]; then
    pool_file="/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
    if [[ -f "$pool_file" ]]; then
      pool_service="php${php_version}-fpm"
      pm=$(perf_pool_directive_get "$pool_file" "pm" || true)
      max_children=$(perf_pool_directive_get "$pool_file" "pm.max_children" || true)
      idle_timeout=$(perf_pool_directive_get "$pool_file" "pm.process_idle_timeout" || true)
      max_requests=$(perf_pool_directive_get "$pool_file" "pm.max_requests" || true)
      req_timeout=$(perf_pool_directive_get "$pool_file" "request_terminate_timeout" || true)
      pool_error_log=$(perf_pool_directive_get "$pool_file" "php_admin_value[error_log]" || true)
      memory_limit=$(doctor_php_pool_ini_get "$pool_file" "memory_limit" || true)
      [[ -z "$memory_limit" ]] && memory_limit="n/a"
      memory_risk=$(site_perf_memory_risk "$memory_limit" "$max_children")
      php_bin=$(resolve_php_bin "$php_version")
      pool_socket=$(perf_pool_socket_path "$php_version" "$socket_project")
      if [[ -S "$pool_socket" ]]; then
        pool_socket_state="present"
      else
        pool_socket_state="missing"
      fi
      total_children=$(perf_fpm_total_max_children)
      fpm_budget=$(perf_fpm_recommended_total_children)
      fpm_oversub=$(perf_fpm_oversubscription_risk "$total_children" "$fpm_budget")
      optimization_recommendation=$(site_user_recommendation "$domain" "$fpm_oversub")
      mem_available=$(perf_memory_available_summary)
      pool_share=$(perf_ratio_band "${max_children:-0}" "${total_children:-0}")
      if [[ -n "$php_bin" ]] && "$php_bin" -m 2>/dev/null | grep -qi '^Zend OPcache$'; then
        opcache_ext="yes"
      else
        opcache_ext="no"
      fi
      if [[ -n "$php_bin" ]] && "$php_bin" -m 2>/dev/null | grep -qi '^redis$'; then
        redis_ext="yes"
      else
        redis_ext="no"
      fi
    fi
  fi

  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_service="active"
    else
      redis_service="inactive"
    fi
  fi
  [[ -n "${optimization_recommendation:-}" ]] || optimization_recommendation=$(site_user_recommendation "$domain" "$fpm_oversub")

  ui_header "SIMAI ENV · Site performance"
  ui_result_table \
    "Domain|${domain}" \
    "Profile|${profile}" \
    "Activity class|${usage_class}" \
    "Optimization|${optimization_mode}" \
    "Automatic optimization|${auto_optimize_effective}" \
    "Site auto optimize override|${auto_optimize_state}" \
    "Recommendation|${optimization_recommendation}" \
    "Runtime state|${runtime_state}" \
    "Optimization mode|${mode}" \
    "PHP|${php_version}" \
    "Pool file|${pool_file}" \
    "Pool service|${pool_service}" \
    "Pool pm|${pm:-n/a}" \
    "Pool max children|${max_children:-n/a}" \
    "Pool children share|${pool_share}" \
    "FPM child budget estimate|${fpm_budget}" \
    "FPM oversubscription|${fpm_oversub}" \
    "Pool idle timeout|${idle_timeout:-n/a}" \
    "Pool max requests|${max_requests:-n/a}" \
    "Request timeout|${req_timeout:-n/a}" \
    "Pool socket|${pool_socket} (${pool_socket_state})" \
    "Pool error log|${pool_error_log:-n/a}" \
    "Memory limit|${memory_limit}" \
    "Server memory available|${mem_available}" \
    "Estimated memory risk|${memory_risk}" \
    "OPcache extension|${opcache_ext}" \
    "Redis extension|${redis_ext}" \
    "Redis service|${redis_service}" \
    "Cron footprint|${cron_summary}" \
    "Queue footprint|${queue_summary}"
  ui_next_steps
  ui_kv "Usage standard" "simai-admin.sh site usage-set --domain ${domain} --class standard --confirm yes"
  ui_kv "Usage high traffic" "simai-admin.sh site usage-set --domain ${domain} --class high-traffic --confirm yes"
  ui_kv "Usage rarely used" "simai-admin.sh site usage-set --domain ${domain} --class rarely-used --confirm yes"
  ui_kv "Tune balanced" "simai-admin.sh site perf-tune --domain ${domain} --mode balanced --confirm yes"
  ui_kv "Tune safe" "simai-admin.sh site perf-tune --domain ${domain} --mode safe --confirm yes"
  ui_kv "Tune parked" "simai-admin.sh site perf-tune --domain ${domain} --mode parked --confirm yes"
}

site_perf_tune_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  local mode="${PARSED_ARGS[mode]:-balanced}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    parked|safe|balanced|aggressive) ;;
    *)
      error "Unsupported site performance mode: ${mode}"
      return 1
      ;;
  esac

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply site optimization changes"
    return 1
  fi

  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi

  local profile="${SITE_META[profile]:-unknown}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local php_version="${SITE_META[php]:-none}"

  if [[ "$php_version" == "none" || -z "$php_version" ]]; then
    warn "Site ${domain} does not use PHP; nothing to tune"
    return 0
  fi

  load_profile "$profile" || return 1

  local settings=()
  mapfile -t settings < <(site_perf_mode_defaults "$profile" "$mode")
  if [[ ${#settings[@]} -eq 0 ]]; then
    error "Failed to derive settings for mode ${mode}"
    return 1
  fi

  write_site_perf_settings_merged "$domain" "${settings[@]}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi

  if ! apply_site_perf_settings_to_pool "$domain" "$php_version" "$socket_project"; then
    return 1
  fi

  ui_header "SIMAI ENV · Site performance tune"
  ui_result_table \
    "Domain|${domain}" \
    "Profile|${profile}" \
    "Mode|${mode}" \
    "PHP|${php_version}" \
    "Pool file|/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
  ui_next_steps
  ui_kv "Review site status" "simai-admin.sh site perf-status --domain ${domain}"
}

site_usage_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  local usage_class perf_mode runtime_state
  usage_class=$(site_usage_class_get "$domain")
  perf_mode=$(site_usage_class_to_perf_mode "$usage_class")
  runtime_state=$(site_runtime_state "$domain")
  local auto_optimize_state auto_optimize_effective
  auto_optimize_state=$(site_auto_optimize_state_get "$domain")
  auto_optimize_effective=$(site_auto_optimize_effective_enabled "$domain")
  local optimization_mode optimization_recommendation
  optimization_mode=$(site_user_optimization_mode "$domain")
  optimization_recommendation=$(site_user_recommendation "$domain")

  ui_header "SIMAI ENV · Site activity"
  ui_result_table \
    "Domain|${domain}" \
    "Activity class|${usage_class}" \
    "Optimization|${optimization_mode}" \
    "Mapped perf mode|${perf_mode}" \
    "Automatic optimization|${auto_optimize_effective}" \
    "Site auto optimize override|${auto_optimize_state}" \
    "Recommendation|${optimization_recommendation}" \
    "Runtime state|${runtime_state}"
  ui_next_steps
  ui_kv "Set standard" "simai-admin.sh site usage-set --domain ${domain} --class standard --confirm yes"
  ui_kv "Set high traffic" "simai-admin.sh site usage-set --domain ${domain} --class high-traffic --confirm yes"
  ui_kv "Set rarely used" "simai-admin.sh site usage-set --domain ${domain} --class rarely-used --confirm yes"
}

site_usage_set_handler() {
  parse_kv_args "$@"
  local domain usage_class confirm
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  usage_class="${PARSED_ARGS[class]:-${PARSED_ARGS[usage]:-}}"
  confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ -z "$usage_class" ]]; then
    usage_class=$(site_usage_select_class "") || return $?
  else
    usage_class=$(site_usage_class_normalize "$usage_class") || {
      error "Unsupported site usage class: ${PARSED_ARGS[class]:-${PARSED_ARGS[usage]:-}}"
      return 1
    }
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to update site usage"
    return 1
  fi
  site_usage_apply_class "$domain" "$usage_class" "$confirm" || return 1

  ui_header "SIMAI ENV · Site activity"
  ui_result_table \
    "Domain|${domain}" \
    "Activity class|${usage_class}" \
    "Mapped perf mode|$(site_usage_class_to_perf_mode "$usage_class")"
  ui_next_steps
  ui_kv "Review performance" "simai-admin.sh site perf-status --domain ${domain}"
}

site_auto_optimize_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0

  local usage_class perf_mode runtime_state auto_optimize_state auto_optimize_effective
  usage_class=$(site_usage_class_get "$domain")
  perf_mode=$(site_usage_class_to_perf_mode "$usage_class")
  runtime_state=$(site_runtime_state "$domain")
  auto_optimize_state=$(site_auto_optimize_state_get "$domain")
  auto_optimize_effective=$(site_auto_optimize_effective_enabled "$domain")
  local optimization_mode optimization_recommendation
  optimization_mode=$(site_user_optimization_mode "$domain")
  optimization_recommendation=$(site_user_recommendation "$domain")

  ui_header "SIMAI ENV · Site automatic optimization"
  ui_result_table \
    "Domain|${domain}" \
    "Optimization|${optimization_mode}" \
    "Automatic optimization|${auto_optimize_effective}" \
    "Site override|${auto_optimize_state}" \
    "Activity class|${usage_class}" \
    "Mapped perf mode|${perf_mode}" \
    "Recommendation|${optimization_recommendation}" \
    "Runtime state|${runtime_state}"
  ui_next_steps
  ui_kv "Enable for site" "simai-admin.sh site auto-optimize-enable --domain ${domain} --confirm yes"
  ui_kv "Disable for site" "simai-admin.sh site auto-optimize-disable --domain ${domain} --confirm yes"
  ui_kv "Reset to inherit" "simai-admin.sh site auto-optimize-reset --domain ${domain} --confirm yes"
}

site_auto_optimize_write_override() {
  local domain="$1" value="$2"
  value=$(site_auto_optimize_state_normalize "$value") || {
    error "Unsupported site automatic optimization override: ${value}"
    return 1
  }
  write_site_perf_settings_merged "$domain" "auto_optimize|${value}"
}

site_auto_optimize_enable_handler() {
  parse_kv_args "$@"
  local domain confirm
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to update site automatic optimization"
    return 1
  fi
  site_auto_optimize_write_override "$domain" "yes" || return 1
  ui_success "Site automatic optimization enabled"
  print_kv_table \
    "Domain|${domain}" \
    "Site override|yes" \
    "Effective state|$(site_auto_optimize_effective_enabled "$domain")"
}

site_auto_optimize_disable_handler() {
  parse_kv_args "$@"
  local domain confirm
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to update site automatic optimization"
    return 1
  fi
  site_auto_optimize_write_override "$domain" "no" || return 1
  ui_success "Site automatic optimization disabled"
  print_kv_table \
    "Domain|${domain}" \
    "Site override|no" \
    "Effective state|$(site_auto_optimize_effective_enabled "$domain")"
}

site_auto_optimize_reset_handler() {
  parse_kv_args "$@"
  local domain confirm
  domain=$(site_perf_select_domain) || return $?
  [[ -z "$domain" ]] && return 0
  confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to reset site automatic optimization override"
    return 1
  fi
  site_auto_optimize_write_override "$domain" "inherit" || return 1
  ui_success "Site automatic optimization reset to inherit"
  print_kv_table \
    "Domain|${domain}" \
    "Site override|inherit" \
    "Effective state|$(site_auto_optimize_effective_enabled "$domain")"
}

register_cmd "site" "perf-status" "Show per-site performance/runtime governance" "site_perf_status_handler" "" "domain="
register_cmd "site" "perf-tune" "Apply per-site FPM governance mode" "site_perf_tune_handler" "" "domain= mode= confirm="
register_cmd "site" "usage-status" "Show user-facing site usage class" "site_usage_status_handler" "" "domain="
register_cmd "site" "usage-set" "Set user-facing site usage class" "site_usage_set_handler" "" "domain= class= usage= confirm="
register_cmd "site" "auto-optimize-status" "Show per-site automatic optimization status" "site_auto_optimize_status_handler" "" "domain="
register_cmd "site" "auto-optimize-enable" "Enable automatic optimization for one site" "site_auto_optimize_enable_handler" "" "domain= confirm="
register_cmd "site" "auto-optimize-disable" "Disable automatic optimization for one site" "site_auto_optimize_disable_handler" "" "domain= confirm="
register_cmd "site" "auto-optimize-reset" "Reset site automatic optimization to inherit" "site_auto_optimize_reset_handler" "" "domain= confirm="

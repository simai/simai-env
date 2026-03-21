#!/usr/bin/env bash
set -euo pipefail

self_update_ref() {
  update_ref_default
}

self_remote_version_url() {
  update_remote_version_url "$(self_update_ref)" "${REPO_URL:-https://github.com/simai/simai-env}"
}

self_post_update_smoke() {
  local root_dir="$1"
  local strict="${2:-no}"
  local has_fail=0
  local failed=()

  [[ "${strict,,}" == "yes" ]] || strict="no"

  if [[ ! -x "${root_dir}/simai-admin.sh" ]]; then
    has_fail=1
    failed+=("simai-admin.sh is missing or not executable")
  fi
  if [[ ! -x "${root_dir}/simai-env.sh" ]]; then
    has_fail=1
    failed+=("simai-env.sh is missing or not executable")
  fi
  if ! bash -n "${root_dir}/simai-admin.sh" >/dev/null 2>&1; then
    has_fail=1
    failed+=("bash -n simai-admin.sh failed")
  fi
  if ! bash -n "${root_dir}/update.sh" >/dev/null 2>&1; then
    has_fail=1
    failed+=("bash -n update.sh failed")
  fi

  if [[ "$has_fail" -eq 0 ]]; then
    info "Post-update smoke: OK"
    return 0
  fi

  local msg
  msg=$(IFS='; '; echo "${failed[*]}")
  warn "Post-update smoke: FAILED (${msg})"
  warn "Run: bash ${root_dir}/testing/release-gate.sh"
  if [[ "$strict" == "yes" ]]; then
    return 1
  fi
  return 0
}

self_update_handler() {
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ ! -x "$updater" ]]; then
    error "Updater not found or not executable at ${updater}"
    return 1
  fi
  info "Running updater ${updater}"
  progress_init 2
  progress_step "Downloading and applying update"
  "$updater"
  local smoke_strict="${SIMAI_UPDATE_SMOKE_STRICT:-no}"
  if ! self_post_update_smoke "${SCRIPT_DIR}" "$smoke_strict"; then
    progress_done "Update completed with smoke failures"
    return 1
  fi
  progress_done "Update completed"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    progress_step "Reloading admin menu"
    info "Reloading admin menu after update"
    return "${SIMAI_RC_MENU_RELOAD:-88}"
  fi
  return 0
}

self_bootstrap_handler() {
  parse_kv_args "$@"
  local php="${PARSED_ARGS[php]:-8.2}"
  local mysql="${PARSED_ARGS[mysql]:-mysql}"
  local node="${PARSED_ARGS[node-version]:-20}"
  info "Repair Environment: installs/repairs base packages and may reload services; sites are not removed."
  progress_init 4
  progress_step "Running bootstrap (php=${php}, mysql=${mysql}, node=${node})"
  if ! "${SCRIPT_DIR}/simai-env.sh" bootstrap --php "$php" --mysql "$mysql" --node-version "$node"; then
    progress_done "Bootstrap failed"
    return 1
  fi
  progress_step "Installing wp-cli baseline"
  if ! wordpress_wp_cli_install; then
    warn "wp-cli baseline install failed"
  fi
  progress_step "Initializing profile activation defaults"
  if ! maybe_init_profiles_allowlist_core_defaults; then
    warn "Profile activation defaults not initialized"
  fi
  progress_done "Bootstrap completed"
}

self_version_handler() {
  local local_version="(unknown)"
  local version_file="${SCRIPT_DIR}/VERSION"
  [[ -f "$version_file" ]] && local_version="$(cat "$version_file")"

  local update_ref remote_version_url remote_version
  update_ref="$(self_update_ref)"
  remote_version_url="$(self_remote_version_url)"
  remote_version=$(curl -fsSL "$remote_version_url" 2>/dev/null || true)
  [[ -z "$remote_version" ]] && remote_version="(unavailable)"

  local status="n/a"
  if [[ "$remote_version" != "(unavailable)" ]]; then
    if [[ "$local_version" == "$remote_version" ]]; then
      status="up to date"
    else
      status="update available"
    fi
  fi

  local GREEN=$'\e[32m' RED=$'\e[31m' RESET=$'\e[0m'
  local status_padded
  status_padded=$(printf "%-20s" "$status")
  local status_colored="$status_padded"
  if [[ "$status" == "up to date" ]]; then
    status_colored="${GREEN}${status_padded}${RESET}"
  elif [[ "$status" == "update available" ]]; then
    status_colored="${RED}${status_padded}${RESET}"
  fi

  local sep="+----------------------+----------------------+"
  printf "%s\n" "$sep"
  printf "| %-20s | %-20s |\n" "Update ref" "$update_ref"
  printf "| %-20s | %-20s |\n" "Local version" "$local_version"
  printf "| %-20s | %-20s |\n" "Remote version" "$remote_version"
  printf "| %-20s | %-20s |\n" "Status" "$status_colored"
  printf "%s\n" "$sep"
}

self_status_handler() {
  ui_header "SIMAI ENV · System status"
  platform_detect_os
  local os_name="${PLATFORM_OS_PRETTY:-unknown}"
  local supported="no"
  if platform_is_supported_os; then
    supported="yes"
  fi
  local install_dir="${SIMAI_ENV_ROOT:-${SCRIPT_DIR:-unknown}}"

  local svc_state
  svc_state() {
    local svc="$1"
    if ! os_svc_has_unit "$svc"; then
      echo "not installed"
      return
    fi
    if os_svc_is_active "$svc"; then
      echo "active"
    else
      echo "inactive"
    fi
  }

  local nginx_state mysql_state redis_state
  nginx_state=$(svc_state "nginx")
  mysql_state=$(svc_state "mysql")
  redis_state=$(svc_state "redis-server")

  local nginx_version="unknown"
  if command -v nginx >/dev/null 2>&1; then
    nginx_version=$(nginx -v 2>&1 | sed 's/^nginx version: //')
  fi
  local php_cli_version="unknown"
  if command -v php >/dev/null 2>&1; then
    php_cli_version=$(php -v 2>/dev/null | head -n1)
  fi
  local mysql_version="unknown"
  if command -v mysql >/dev/null 2>&1; then
    mysql_version=$(mysql --version 2>/dev/null)
  elif command -v mysqld >/dev/null 2>&1; then
    mysql_version=$(mysqld --version 2>/dev/null)
  fi
  local redis_version="unknown"
  if command -v redis-server >/dev/null 2>&1; then
    redis_version=$(redis-server --version 2>/dev/null)
  elif command -v redis-cli >/dev/null 2>&1; then
    redis_version=$(redis-cli --version 2>/dev/null)
  fi
  local certbot_version="unknown"
  if command -v certbot >/dev/null 2>&1; then
    certbot_version=$(certbot --version 2>/dev/null)
  fi
  local certbot_timer="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local load_state
    load_state=$(systemctl show -p LoadState --value certbot.timer 2>/dev/null || true)
    if [[ "$load_state" == "loaded" ]]; then
      if systemctl is-active --quiet certbot.timer; then
        certbot_timer="active"
      else
        certbot_timer="inactive"
      fi
    else
      certbot_timer="missing"
    fi
  fi

  local php_status="not installed"
  if command -v systemctl >/dev/null 2>&1; then
    local units=()
    mapfile -t units < <(systemctl list-units --type=service --no-legend "php*-fpm.service" 2>/dev/null | awk '{print $1}')
    if [[ ${#units[@]} -gt 0 ]]; then
      local entries=()
      local unit ver state
      for unit in "${units[@]}"; do
        ver="${unit#php}"
        ver="${ver%-fpm.service}"
        state="inactive"
        if systemctl is-active --quiet "$unit"; then
          state="active"
        fi
        entries+=("${ver}(${state})")
      done
      php_status=$(IFS=', '; echo "${entries[*]}")
    fi
  fi
  if [[ "$php_status" == "not installed" ]]; then
    local vers=()
    if compgen -G "/etc/php/*/fpm/php-fpm.conf" >/dev/null 2>&1; then
      local dir ver
      for dir in /etc/php/*/fpm; do
        [[ -d "$dir" ]] || continue
        ver="${dir#/etc/php/}"
        ver="${ver%/fpm}"
        vers+=("$ver")
      done
      if [[ ${#vers[@]} -gt 0 ]]; then
        php_status=$(IFS=', '; echo "${vers[*]}")
      fi
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "Install dir|${install_dir}" \
    "OS|${os_name}" \
    "Supported|${supported}" \
    "nginx|${nginx_state}" \
    "nginx version|${nginx_version}" \
    "mysql|${mysql_state}" \
    "mysql version|${mysql_version}" \
    "redis|${redis_state}" \
    "redis version|${redis_version}" \
    "php-fpm|${php_status}" \
    "php cli|${php_cli_version}" \
    "certbot version|${certbot_version}" \
    "certbot timer|${certbot_timer}"
  ui_section "Next steps"
  ui_kv "Diagnostics" "simai-admin.sh self platform-status"
  ui_kv "Performance" "simai-admin.sh self perf-status"
  ui_kv "Update" "simai-admin.sh self update"
}

self_platform_status_handler() {
  ui_header "SIMAI ENV · Platform diagnostics"
  local svc_state
  svc_state() {
    local svc="$1"
    if ! os_svc_has_unit "$svc"; then
      echo "missing"
      return
    fi
    if os_svc_is_active "$svc"; then
      echo "active"
    else
      echo "inactive"
    fi
  }

  local nginx_state mysql_state redis_state
  nginx_state=$(svc_state "nginx")
  mysql_state=$(svc_state "mysql")
  redis_state=$(svc_state "redis-server")

  local nginx_test="unknown"
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      nginx_test="ok"
    else
      nginx_test="fail"
    fi
  fi

  local php_units="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local units=()
    mapfile -t units < <(systemctl list-units --type=service --no-legend "php*-fpm.service" 2>/dev/null | awk '{print $1}')
    local active_units=()
    local unit
    for unit in "${units[@]}"; do
      if systemctl is-active --quiet "$unit"; then
        active_units+=("$unit")
      fi
    done
    if [[ ${#units[@]} -eq 0 ]]; then
      php_units="missing"
    elif [[ ${#active_units[@]} -eq 0 ]]; then
      php_units="inactive"
    else
      php_units=$(IFS=', '; echo "${active_units[*]}")
    fi
  fi

  local disk_root="unknown"
  disk_root=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')
  [[ -z "$disk_root" ]] && disk_root="unknown"
  local disk_data_label="disk free /var"
  local disk_var="unknown"
  if [[ -d /var/lib/mysql ]]; then
    disk_data_label="disk free /var/lib/mysql"
    disk_var=$(df -h /var/lib/mysql 2>/dev/null | awk 'NR==2{print $4}')
  elif [[ -d /var ]]; then
    disk_data_label="disk free /var"
    disk_var=$(df -h /var 2>/dev/null | awk 'NR==2{print $4}')
  fi
  [[ -z "$disk_var" ]] && disk_var="unknown"

  local inodes_root="unknown"
  inodes_root=$(df -hi / 2>/dev/null | awk 'NR==2{print $4}')
  [[ -z "$inodes_root" ]] && inodes_root="unknown"

  local mem_summary="unknown"
  if command -v free >/dev/null 2>&1; then
    local total used free
    read -r total used free < <(free -h 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
    if [[ -n "${total:-}" ]]; then
      mem_summary="${total}/${used}/${free}"
    fi
  fi

  local certbot_timer="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local load_state
    load_state=$(systemctl show -p LoadState --value certbot.timer 2>/dev/null || true)
    if [[ "$load_state" == "loaded" ]]; then
      if systemctl is-active --quiet certbot.timer; then
        certbot_timer="active"
      else
        certbot_timer="inactive"
      fi
    else
      certbot_timer="missing"
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "nginx|${nginx_state}" \
    "nginx test|${nginx_test}" \
    "mysql|${mysql_state}" \
    "redis|${redis_state}" \
    "php-fpm units|${php_units}" \
    "disk free /|${disk_root}" \
    "${disk_data_label}|${disk_var}" \
    "inodes free /|${inodes_root}" \
    "memory (total/used/free)|${mem_summary}" \
    "certbot timer|${certbot_timer}"
  ui_section "Next steps"
  ui_kv "Validate nginx" "nginx -t"
  ui_kv "Repair stack" "simai-admin.sh self bootstrap"
  ui_kv "Performance" "simai-admin.sh self perf-status"
}

self_perf_status_handler() {
  ui_header "SIMAI ENV · Server optimization status"

  perf_detect_resources
  local recommended_preset
  recommended_preset=$(perf_recommended_preset)
  local managed_preset="${SIMAI_PERF_PRESET:-none}"
  local mem_available
  mem_available=$(perf_memory_available_summary)

  local fpm_defaults="pm=${SIMAI_PERF_FPM_PM:-ondemand}, children=${SIMAI_PERF_FPM_MAX_CHILDREN:-10}, idle=${SIMAI_PERF_FPM_IDLE_TIMEOUT:-10s}, max_requests=${SIMAI_PERF_FPM_MAX_REQUESTS:-500}"
  local opcache_defaults="memory=${SIMAI_PERF_OPCACHE_MEMORY:-n/a}, strings=${SIMAI_PERF_OPCACHE_STRINGS:-n/a}, files=${SIMAI_PERF_OPCACHE_MAX_FILES:-n/a}, validate=${SIMAI_PERF_OPCACHE_VALIDATE:-n/a}, revalidate=${SIMAI_PERF_OPCACHE_REVALIDATE:-n/a}"

  local nginx_conf
  nginx_conf=$(perf_nginx_conf_path)
  local nginx_managed="missing"
  [[ -f "$nginx_conf" ]] && nginx_managed="present"
  local nginx_keepalive="unknown"
  [[ -n "${SIMAI_PERF_NGINX_KEEPALIVE_TIMEOUT:-}" ]] && nginx_keepalive="${SIMAI_PERF_NGINX_KEEPALIVE_TIMEOUT}"
  local nginx_gzip="unknown"
  if command -v nginx >/dev/null 2>&1; then
    nginx_gzip=$(nginx -T 2>/dev/null | awk '$1=="gzip"{print $2}' | tr -d ';' | tail -n1)
    [[ -z "$nginx_gzip" ]] && nginx_gzip="unknown"
  fi

  local mysql_buffer mysql_connections mysql_slow mysql_long mysql_tmp mysql_heap
  local mysql_threads_connected mysql_threads_running mysql_connection_pressure mysql_slow_file
  mysql_buffer=$(perf_mysql_show_var "innodb_buffer_pool_size")
  mysql_connections=$(perf_mysql_show_var "max_connections")
  mysql_slow=$(perf_mysql_show_var "slow_query_log")
  mysql_long=$(perf_mysql_show_var "long_query_time")
  mysql_tmp=$(perf_mysql_show_var "tmp_table_size")
  mysql_heap=$(perf_mysql_show_var "max_heap_table_size")
  mysql_threads_connected=$(perf_mysql_show_status "Threads_connected")
  mysql_threads_running=$(perf_mysql_show_status "Threads_running")
  mysql_connection_pressure=$(perf_ratio_band "${mysql_threads_connected:-0}" "${mysql_connections:-0}")
  mysql_slow_file=$(perf_mysql_slow_log_size)
  [[ -z "$mysql_buffer" ]] && mysql_buffer="unknown"
  [[ -z "$mysql_connections" ]] && mysql_connections="unknown"
  [[ -z "$mysql_slow" ]] && mysql_slow="unknown"
  [[ -z "$mysql_long" ]] && mysql_long="unknown"
  [[ -z "$mysql_tmp" ]] && mysql_tmp="unknown"
  [[ -z "$mysql_heap" ]] && mysql_heap="unknown"
  [[ -z "$mysql_threads_connected" ]] && mysql_threads_connected="unknown"
  [[ -z "$mysql_threads_running" ]] && mysql_threads_running="unknown"
  [[ -z "$mysql_connection_pressure" ]] && mysql_connection_pressure="unknown"

  local redis_state="missing"
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_state="active"
    else
      redis_state="inactive"
    fi
  fi
  local redis_maxmemory redis_policy redis_conf
  local redis_used_memory redis_clients redis_ops redis_memory_pressure
  redis_maxmemory=$(perf_redis_config_get "maxmemory")
  redis_policy=$(perf_redis_config_get "maxmemory-policy")
  redis_conf=$(perf_redis_conf_path)
  redis_used_memory=$(perf_redis_info_get "used_memory")
  redis_clients=$(perf_redis_info_get "connected_clients")
  redis_ops=$(perf_redis_info_get "instantaneous_ops_per_sec")
  redis_memory_pressure=$(perf_redis_memory_pressure "${redis_used_memory:-0}" "${redis_maxmemory:-0}")
  [[ -z "$redis_maxmemory" ]] && redis_maxmemory="unknown"
  [[ -z "$redis_policy" ]] && redis_policy="unknown"
  [[ -z "$redis_used_memory" ]] && redis_used_memory="unknown"
  [[ -z "$redis_clients" ]] && redis_clients="unknown"
  [[ -z "$redis_ops" ]] && redis_ops="unknown"
  [[ -z "$redis_memory_pressure" ]] && redis_memory_pressure="unknown"

  local fpm_services fpm_pools fpm_total_children fpm_budget fpm_oversub
  local nginx_test="unknown"
  fpm_services=$(perf_fpm_service_summary)
  fpm_pools=$(perf_fpm_pool_count)
  fpm_total_children=$(perf_fpm_total_max_children)
  fpm_budget=$(perf_fpm_recommended_total_children)
  fpm_oversub=$(perf_fpm_oversubscription_risk "$fpm_total_children" "$fpm_budget")
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      nginx_test="ok"
    else
      nginx_test="fail"
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "Server size|cpu=${PERF_CPU_COUNT}, mem=${PERF_MEM_MB}M, swap=${PERF_SWAP_MB}M" \
    "Memory available|${mem_available}" \
    "Recommended preset|${recommended_preset}" \
    "Active preset|${managed_preset}" \
    "Default site settings|${fpm_defaults}" \
    "FPM services|${fpm_services}" \
    "FPM pools|${fpm_pools}" \
    "FPM configured children|${fpm_total_children}" \
    "FPM child budget estimate|${fpm_budget}" \
    "FPM oversubscription|${fpm_oversub}" \
    "OPcache defaults|${opcache_defaults}" \
    "nginx snippet|${nginx_managed} (${nginx_conf})" \
    "nginx gzip|${nginx_gzip}" \
    "nginx keepalive|${nginx_keepalive}" \
    "nginx config test|${nginx_test}" \
    "mysql buffer pool|$(perf_bytes_human "$mysql_buffer")" \
    "mysql max connections|${mysql_connections}" \
    "mysql threads|connected=${mysql_threads_connected}, running=${mysql_threads_running}" \
    "mysql connection pressure|${mysql_connection_pressure}" \
    "mysql slow query log|${mysql_slow}" \
    "mysql slow log file|${mysql_slow_file}" \
    "mysql long_query_time|${mysql_long}" \
    "mysql tmp/max heap|$(perf_bytes_human "$mysql_tmp") / $(perf_bytes_human "$mysql_heap")" \
    "redis|${redis_state}" \
    "redis maxmemory|${redis_maxmemory}" \
    "redis used memory|$(perf_bytes_human "$redis_used_memory")" \
    "redis memory pressure|${redis_memory_pressure}" \
    "redis clients/ops|${redis_clients} / ${redis_ops}" \
    "redis policy|${redis_policy}" \
    "redis snippet|$( [[ -f "$redis_conf" ]] && printf 'present (%s)' "$redis_conf" || printf 'missing (%s)' "$redis_conf" )"
  ui_section "Next steps"
  ui_kv "Apply recommended preset" "simai-admin.sh self perf-apply --preset ${recommended_preset} --confirm yes"
  ui_kv "Apply medium preset" "simai-admin.sh self perf-apply --preset medium --confirm yes"
  ui_kv "Review FPM plan" "simai-admin.sh self perf-plan"
}

self_perf_plan_handler() {
  parse_kv_args "$@"
  local limit="${PARSED_ARGS[limit]:-8}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=8
  (( limit < 1 )) && limit=1

  local total_children budget oversub excess mem_available safe_floor parked_floor
  total_children=$(perf_fpm_total_max_children)
  budget=$(perf_fpm_recommended_total_children)
  oversub=$(perf_fpm_oversubscription_risk "$total_children" "$budget")
  excess=$(perf_fpm_excess_children "$total_children" "$budget")
  mem_available=$(perf_memory_available_summary)
  safe_floor=$(perf_fpm_mode_floor "safe")
  parked_floor=$(perf_fpm_mode_floor "parked")

  ui_header "SIMAI ENV · Server optimization plan"
  ui_section "Summary"
  print_kv_table \
    "Configured children|${total_children}" \
    "Recommended budget|${budget}" \
    "Excess children|${excess}" \
    "Oversubscription|${oversub}" \
    "Memory available|${mem_available}" \
    "Safe-mode floor|${safe_floor}" \
    "Parked-mode floor|${parked_floor}"

  if [[ "$excess" == "0" ]]; then
    ui_section "Result"
    ui_info "No server optimization changes are needed."
    return 0
  fi

  local rows=()
  local commands=()
  local idx=0
  local entry current domain profile mode usage_class auto_optimize_state suggested_mode target_children reduction php_version pool_file
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r current domain profile mode usage_class auto_optimize_state suggested_mode target_children reduction php_version pool_file <<<"$entry"
    idx=$((idx + 1))
    rows+=("${idx}. ${domain}|children=${current}, usage=${usage_class}, auto=${auto_optimize_state}, suggest=${suggested_mode}, target=${target_children}, reduce=${reduction}, mode=${mode}, profile=${profile}, php=${php_version}")
    if [[ "$domain" == *.* && "$reduction" =~ ^[0-9]+$ && "$reduction" -gt 0 ]]; then
      commands+=("Tune ${idx}|simai-admin.sh site perf-tune --domain ${domain} --mode ${suggested_mode} --confirm yes")
    fi
  done < <(perf_fpm_top_pools "$limit")

  if (( ${#rows[@]} == 0 )); then
    ui_section "Result"
    ui_warn "No PHP site pools were found."
    return 0
  fi

  ui_section "Top offenders"
  print_kv_table "${rows[@]}"

  if (( ${#commands[@]} > 0 )); then
    ui_section "Suggested commands"
    print_kv_table "${commands[@]}"
  fi
}

self_perf_rebalance_handler() {
  parse_kv_args "$@"
  local limit="${PARSED_ARGS[limit]:-8}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local mode="${PARSED_ARGS[mode]:-auto}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=8
  (( limit < 1 )) && limit=1
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    auto|safe|parked) ;;
    *)
      error "Unsupported rebalance mode: ${mode}"
      return 1
      ;;
  esac

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply server optimization changes"
    return 1
  fi

  local before_total budget before_excess
  before_total=$(perf_fpm_total_max_children)
  budget=$(perf_fpm_recommended_total_children)
  before_excess=$(perf_fpm_excess_children "$before_total" "$budget")

  if [[ "$before_excess" == "0" ]]; then
    ui_header "SIMAI ENV · Apply server optimization"
    ui_section "Result"
    ui_info "No server optimization changes are needed."
    return 0
  fi

  local changed=()
  local skipped=()
  local applied=0
  local entry current domain profile current_mode usage_class auto_optimize_state suggested_mode target_children reduction php_version pool_file apply_mode
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r current domain profile current_mode usage_class auto_optimize_state suggested_mode _target _reduction php_version pool_file <<<"$entry"
    [[ "$domain" == *.* ]] || continue
    apply_mode="$mode"
    if [[ "$apply_mode" == "auto" ]]; then
      if [[ "$auto_optimize_state" == "no" ]]; then
        skipped+=("${domain}|automatic optimization disabled for site")
        continue
      fi
      apply_mode="$suggested_mode"
    fi
    target_children=$(perf_site_mode_target_children "$profile" "$apply_mode")
    [[ -n "$target_children" && "$target_children" =~ ^[0-9]+$ ]] || continue
    if (( current <= target_children )); then
      skipped+=("${domain}|already within ${apply_mode} (usage=${usage_class})")
      continue
    fi
    if site_perf_tune_handler --domain "$domain" --mode "$apply_mode" --confirm yes >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
      reduction=$(( current - target_children ))
      changed+=("${domain}|${current} -> ${target_children} (${profile}, usage=${usage_class}, mode=${apply_mode}, php ${php_version}, reduce ${reduction})")
      applied=$((applied + 1))
    else
      skipped+=("${domain}|apply failed (${apply_mode})")
    fi
    (( applied >= limit )) && break
  done < <(perf_fpm_top_pools "$limit")

  local after_total after_excess after_risk
  after_total=$(perf_fpm_total_max_children)
  after_excess=$(perf_fpm_excess_children "$after_total" "$budget")
  after_risk=$(perf_fpm_oversubscription_risk "$after_total" "$budget")

  ui_header "SIMAI ENV · Apply server optimization"
  ui_section "Summary"
  print_kv_table \
    "Mode|${mode}" \
    "Applied changes|${applied}" \
    "Children before|${before_total}" \
    "Children after|${after_total}" \
    "Recommended budget|${budget}" \
    "Excess before|${before_excess}" \
    "Excess after|${after_excess}" \
    "Oversubscription after|${after_risk}"

  if (( ${#changed[@]} > 0 )); then
    ui_section "Changed sites"
    print_kv_table "${changed[@]}"
  fi
  if (( ${#skipped[@]} > 0 )); then
    ui_section "Skipped"
    print_kv_table "${skipped[@]}"
  fi
  ui_section "Next steps"
  ui_kv "Review current status" "simai-admin.sh self perf-status"
  ui_kv "Review plan" "simai-admin.sh self perf-plan"
}

self_perf_apply_handler() {
  parse_kv_args "$@"
  local preset="${PARSED_ARGS[preset]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ -z "$preset" ]]; then
    preset=$(perf_recommended_preset)
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply server optimization changes"
    return 1
  fi
  perf_use_preset "$preset" || return 1

  progress_init 5
  progress_step "Applying nginx baseline"
  perf_apply_nginx_baseline || return 1

  progress_step "Applying MySQL baseline"
  perf_apply_mysql_baseline || return 1

  progress_step "Applying Redis baseline"
  perf_apply_redis_baseline || true

  progress_step "Applying PHP-FPM OPcache baseline"
  perf_apply_php_fpm_baseline || return 1

  progress_step "Writing managed simai performance defaults (${PERF_PRESET})"
  perf_apply_env_defaults || return 1

  progress_done "Server optimization baseline applied"

  ui_section "Result"
  print_kv_table \
    "Preset|${PERF_PRESET}" \
    "Future FPM defaults|pm=${PERF_FPM_PM}, children=${PERF_FPM_MAX_CHILDREN}, idle=${PERF_FPM_IDLE_TIMEOUT}, max_requests=${PERF_FPM_MAX_REQUESTS}" \
    "OPcache|memory=${PERF_OPCACHE_MEMORY}, strings=${PERF_OPCACHE_STRINGS}, files=${PERF_OPCACHE_MAX_FILES}" \
    "MySQL buffer pool|${PERF_MYSQL_BUFFER_POOL}" \
    "MySQL max connections|${PERF_MYSQL_MAX_CONNECTIONS}" \
    "Redis maxmemory|${PERF_REDIS_MAXMEMORY}" \
    "Redis policy|${PERF_REDIS_POLICY}"
  ui_section "Next steps"
  ui_kv "Review current status" "simai-admin.sh self perf-status"
  ui_kv "Check platform" "simai-admin.sh self platform-status"
}

self_scheduler_persist_config() {
  scheduler_write_config \
    "${SIMAI_SCHEDULER_ENABLED:-yes}" \
    "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}" \
    "${SIMAI_AUTO_OPTIMIZE_MODE:-assist}" \
    "${SIMAI_AUTO_OPTIMIZE_INTERVAL_MINUTES:-5}" \
    "${SIMAI_AUTO_OPTIMIZE_COOLDOWN_MINUTES:-60}" \
    "${SIMAI_AUTO_OPTIMIZE_LIMIT:-3}" \
    "${SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE:-auto}" \
    "${SIMAI_HEALTH_REVIEW_ENABLED:-yes}" \
    "${SIMAI_HEALTH_REVIEW_INTERVAL_MINUTES:-30}" \
    "${SIMAI_SITE_REVIEW_ENABLED:-yes}" \
    "${SIMAI_SITE_REVIEW_INTERVAL_MINUTES:-360}" \
    "${SIMAI_SITE_REVIEW_STALE_DAYS:-3}"
}

self_scheduler_handler() {
  scheduler_tick
}

self_scheduler_status_handler() {
  ui_header "SIMAI ENV · Scheduler status"

  local cron_file cron_state cron_cmd
  cron_file=$(scheduler_cron_file)
  cron_cmd=$(scheduler_scheduler_cmd)
  cron_state="missing"
  [[ -f "$cron_file" ]] && cron_state="installed"

  local rows=()
  rows+=("Scheduler enabled|$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")")
  rows+=("Cron entry|${cron_state} (${cron_file})")
  rows+=("Cron command|${cron_cmd}")

  local job enabled mode interval cooldown limit rebalance_mode last_run next_due last_status last_message last_action
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    enabled=$(scheduler_job_enabled "$job")
    mode=$(scheduler_job_mode "$job")
    interval=$(scheduler_job_interval_minutes "$job")
    cooldown=$(scheduler_job_cooldown_minutes "$job")
    limit=$(scheduler_job_limit "$job")
    rebalance_mode=$(scheduler_job_rebalance_mode "$job")
    last_run=$(scheduler_job_state_get "$job" "last_run_epoch" 2>/dev/null || true)
    next_due=$(scheduler_job_next_due_epoch "$job")
    last_status=$(scheduler_job_state_get "$job" "last_status" 2>/dev/null || true)
    last_message=$(scheduler_job_state_get "$job" "last_message" 2>/dev/null || true)
    last_action=$(scheduler_job_state_get "$job" "last_action_epoch" 2>/dev/null || true)
    [[ -z "$last_run" ]] && last_run="never"
    [[ -z "$last_status" ]] && last_status="n/a"
    [[ -z "$last_message" ]] && last_message="n/a"
    [[ -z "$last_action" ]] && last_action="never"
    rows+=("Job ${job}|enabled=${enabled}, mode=${mode}, interval=${interval}m, cooldown=${cooldown}m, limit=${limit}, rebalance=${rebalance_mode}")
    rows+=("Job ${job} last run|$(scheduler_epoch_human "$last_run")")
    rows+=("Job ${job} last action|$(scheduler_epoch_human "$last_action")")
    rows+=("Job ${job} next due|$(scheduler_epoch_human "$next_due")")
    rows+=("Job ${job} last status|${last_status}")
    rows+=("Job ${job} last message|${last_message}")
  done < <(scheduler_jobs_list)

  ui_section "Result"
  print_kv_table "${rows[@]}"
  ui_section "Next steps"
  ui_kv "Run scheduler now" "simai-admin.sh self scheduler"
  ui_kv "Disable auto optimize" "simai-admin.sh self scheduler-disable --job auto-optimize"
}

self_scheduler_enable_handler() {
  parse_kv_args "$@"
  local job="${PARSED_ARGS[job]:-all}"
  job=$(printf '%s' "$job" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  case "$job" in
    all)
      SIMAI_SCHEDULER_ENABLED="yes"
      ;;
    auto-optimize)
      SIMAI_AUTO_OPTIMIZE_ENABLED="yes"
      ;;
    health-review)
      SIMAI_HEALTH_REVIEW_ENABLED="yes"
      ;;
    site-review)
      SIMAI_SITE_REVIEW_ENABLED="yes"
      ;;
    *)
      error "Unsupported scheduler job: ${job}"
      return 1
      ;;
  esac

  self_scheduler_persist_config
  ui_success "Scheduler config updated"
  print_kv_table \
    "Scheduler enabled|$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" \
    "Auto optimize enabled|$(scheduler_normalize_bool "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}")" \
    "Health review enabled|$(scheduler_normalize_bool "${SIMAI_HEALTH_REVIEW_ENABLED:-yes}")" \
    "Site review enabled|$(scheduler_normalize_bool "${SIMAI_SITE_REVIEW_ENABLED:-yes}")"
}

self_scheduler_disable_handler() {
  parse_kv_args "$@"
  local job="${PARSED_ARGS[job]:-all}"
  job=$(printf '%s' "$job" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

  case "$job" in
    all)
      SIMAI_SCHEDULER_ENABLED="no"
      ;;
    auto-optimize)
      SIMAI_AUTO_OPTIMIZE_ENABLED="no"
      ;;
    health-review)
      SIMAI_HEALTH_REVIEW_ENABLED="no"
      ;;
    site-review)
      SIMAI_SITE_REVIEW_ENABLED="no"
      ;;
    *)
      error "Unsupported scheduler job: ${job}"
      return 1
      ;;
  esac

  self_scheduler_persist_config
  ui_success "Scheduler config updated"
  print_kv_table \
    "Scheduler enabled|$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" \
    "Auto optimize enabled|$(scheduler_normalize_bool "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}")" \
    "Health review enabled|$(scheduler_normalize_bool "${SIMAI_HEALTH_REVIEW_ENABLED:-yes}")" \
    "Site review enabled|$(scheduler_normalize_bool "${SIMAI_SITE_REVIEW_ENABLED:-yes}")"
}

self_scheduler_run_handler() {
  parse_kv_args "$@"
  local job="${PARSED_ARGS[job]:-auto-optimize}"
  job=$(scheduler_job_normalize "$job") || {
    error "Unsupported scheduler job: ${PARSED_ARGS[job]:-}"
    return 1
  }
  scheduler_run_job "$job"
}

self_auto_optimize_status_handler() {
  ui_header "SIMAI ENV · Automatic optimization"

  local enabled mode interval cooldown limit rebalance cron_state
  enabled=$(scheduler_job_enabled "auto_optimize")
  mode=$(scheduler_job_mode "auto_optimize")
  interval=$(scheduler_job_interval_minutes "auto_optimize")
  cooldown=$(scheduler_job_cooldown_minutes "auto_optimize")
  limit=$(scheduler_job_limit "auto_optimize")
  rebalance=$(scheduler_job_rebalance_mode "auto_optimize")
  cron_state="missing"
  [[ -f "$(scheduler_cron_file)" ]] && cron_state="installed"

  local last_run last_action last_status last_message
  last_run=$(scheduler_job_state_get "auto_optimize" "last_run_epoch" 2>/dev/null || true)
  last_action=$(scheduler_job_state_get "auto_optimize" "last_action_epoch" 2>/dev/null || true)
  last_status=$(scheduler_job_state_get "auto_optimize" "last_status" 2>/dev/null || true)
  last_message=$(scheduler_job_state_get "auto_optimize" "last_message" 2>/dev/null || true)
  [[ -z "$last_run" ]] && last_run="never"
  [[ -z "$last_action" ]] && last_action="never"
  [[ -z "$last_status" ]] && last_status="n/a"
  [[ -z "$last_message" ]] && last_message="n/a"

  ui_section "Result"
  print_kv_table \
    "Automatic optimization|${enabled}" \
    "Mode|${mode}" \
    "Shared scheduler cron|${cron_state}" \
    "Interval|${interval}m" \
    "Cooldown|${cooldown}m" \
    "Batch size|${limit}" \
    "Rebalance policy|${rebalance}" \
    "Last run|$(scheduler_epoch_human "$last_run")" \
    "Last action|$(scheduler_epoch_human "$last_action")" \
    "Last status|${last_status}" \
    "Last message|${last_message}"
  ui_section "Next steps"
  if [[ "$enabled" == "yes" ]]; then
    ui_kv "Turn off" "simai-admin.sh self auto-optimize-disable"
  else
    ui_kv "Turn on" "simai-admin.sh self auto-optimize-enable"
  fi
  ui_kv "Advanced status" "simai-admin.sh self scheduler-status"
}

self_auto_optimize_enable_handler() {
  SIMAI_AUTO_OPTIMIZE_ENABLED="yes"
  self_scheduler_persist_config
  ui_success "Automatic optimization enabled"
  print_kv_table \
    "Automatic optimization|yes" \
    "Mode|$(scheduler_job_mode "auto_optimize")" \
    "Rebalance policy|$(scheduler_job_rebalance_mode "auto_optimize")"
}

self_auto_optimize_disable_handler() {
  SIMAI_AUTO_OPTIMIZE_ENABLED="no"
  self_scheduler_persist_config
  ui_success "Automatic optimization disabled"
  print_kv_table \
    "Automatic optimization|no" \
    "Mode|$(scheduler_job_mode "auto_optimize")" \
    "Rebalance policy|$(scheduler_job_rebalance_mode "auto_optimize")"
}

self_health_review_status_handler() {
  ui_header "SIMAI ENV · Platform health review"

  local enabled interval cron_state
  enabled=$(scheduler_job_enabled "health_review")
  interval=$(scheduler_job_interval_minutes "health_review")
  cron_state="missing"
  [[ -f "$(scheduler_cron_file)" ]] && cron_state="installed"

  local last_run last_status last_message generated_at
  last_run=$(scheduler_job_state_get "health_review" "last_run_epoch" 2>/dev/null || true)
  last_status=$(scheduler_job_state_get "health_review" "last_status" 2>/dev/null || true)
  last_message=$(scheduler_job_state_get "health_review" "last_message" 2>/dev/null || true)
  generated_at=$(scheduler_job_report_get "health_review" "generated_at" 2>/dev/null || true)
  [[ -z "$last_run" ]] && last_run="never"
  [[ -z "$last_status" ]] && last_status="n/a"
  [[ -z "$last_message" ]] && last_message="n/a"

  local sites_total sites_active sites_suspended sites_auto_disabled sites_setup_pending sites_ssl_expiring_soon sites_ssl_disabled fpm_children fpm_budget fpm_oversub setup_domains expiring_domains manual_domains
  sites_total=$(scheduler_job_report_get "health_review" "sites_total" 2>/dev/null || true)
  sites_active=$(scheduler_job_report_get "health_review" "sites_active" 2>/dev/null || true)
  sites_suspended=$(scheduler_job_report_get "health_review" "sites_suspended" 2>/dev/null || true)
  sites_auto_disabled=$(scheduler_job_report_get "health_review" "sites_auto_disabled" 2>/dev/null || true)
  sites_setup_pending=$(scheduler_job_report_get "health_review" "sites_setup_pending" 2>/dev/null || true)
  sites_ssl_expiring_soon=$(scheduler_job_report_get "health_review" "sites_ssl_expiring_soon" 2>/dev/null || true)
  sites_ssl_disabled=$(scheduler_job_report_get "health_review" "sites_ssl_disabled" 2>/dev/null || true)
  fpm_children=$(scheduler_job_report_get "health_review" "fpm_children" 2>/dev/null || true)
  fpm_budget=$(scheduler_job_report_get "health_review" "fpm_budget" 2>/dev/null || true)
  fpm_oversub=$(scheduler_job_report_get "health_review" "fpm_oversubscription" 2>/dev/null || true)
  setup_domains=$(scheduler_job_report_get "health_review" "setup_domains" 2>/dev/null || true)
  expiring_domains=$(scheduler_job_report_get "health_review" "expiring_domains" 2>/dev/null || true)
  manual_domains=$(scheduler_job_report_get "health_review" "manual_domains" 2>/dev/null || true)

  ui_section "Result"
  print_kv_table \
    "Health review|${enabled}" \
    "Shared scheduler cron|${cron_state}" \
    "Interval|${interval}m" \
    "Last run|$(scheduler_epoch_human "$last_run")" \
    "Last report|$(scheduler_epoch_human "${generated_at:-}")" \
    "Last status|${last_status}" \
    "Last summary|${last_message}" \
    "Sites total|${sites_total:-n/a}" \
    "Sites active|${sites_active:-n/a}" \
    "Sites suspended|${sites_suspended:-n/a}" \
    "Sites auto optimize off|${sites_auto_disabled:-n/a}" \
    "Sites needing setup|${sites_setup_pending:-n/a}" \
    "Sites with SSL expiring soon|${sites_ssl_expiring_soon:-n/a}" \
    "Sites without SSL|${sites_ssl_disabled:-n/a}" \
    "FPM configured children|${fpm_children:-n/a}" \
    "FPM budget|${fpm_budget:-n/a}" \
    "FPM oversubscription|${fpm_oversub:-n/a}"

  if [[ -n "${setup_domains:-}" || -n "${expiring_domains:-}" || -n "${manual_domains:-}" ]]; then
    ui_section "Highlights"
    local highlights=()
    [[ -n "${setup_domains:-}" ]] && highlights+=("Needs setup|${setup_domains}")
    [[ -n "${expiring_domains:-}" ]] && highlights+=("SSL expiring soon|${expiring_domains}")
    [[ -n "${manual_domains:-}" ]] && highlights+=("Auto optimization off|${manual_domains}")
    print_kv_table "${highlights[@]}"
  fi

  ui_section "Next steps"
  ui_kv "Run review now" "simai-admin.sh self scheduler-run --job health-review"
  ui_kv "Advanced scheduler status" "simai-admin.sh self scheduler-status"
}

self_site_review_status_handler() {
  ui_header "SIMAI ENV · Site review"

  local enabled interval stale_days cron_state
  enabled=$(scheduler_job_enabled "site_review")
  interval=$(scheduler_job_interval_minutes "site_review")
  stale_days=$(scheduler_site_review_stale_days)
  cron_state="missing"
  [[ -f "$(scheduler_cron_file)" ]] && cron_state="installed"

  local last_run last_status last_message generated_at
  last_run=$(scheduler_job_state_get "site_review" "last_run_epoch" 2>/dev/null || true)
  last_status=$(scheduler_job_state_get "site_review" "last_status" 2>/dev/null || true)
  last_message=$(scheduler_job_state_get "site_review" "last_message" 2>/dev/null || true)
  generated_at=$(scheduler_job_report_get "site_review" "generated_at" 2>/dev/null || true)
  [[ -z "$last_run" ]] && last_run="never"
  [[ -z "$last_status" ]] && last_status="n/a"
  [[ -z "$last_message" ]] && last_message="n/a"

  local sites_total sites_setup_pending sites_setup_stale sites_pause_candidates sites_suspended sites_manual
  local setup_pending_domains setup_stale_domains pause_candidate_domains suspended_domains
  sites_total=$(scheduler_job_report_get "site_review" "sites_total" 2>/dev/null || true)
  sites_setup_pending=$(scheduler_job_report_get "site_review" "sites_setup_pending" 2>/dev/null || true)
  sites_setup_stale=$(scheduler_job_report_get "site_review" "sites_setup_stale" 2>/dev/null || true)
  sites_pause_candidates=$(scheduler_job_report_get "site_review" "sites_pause_candidates" 2>/dev/null || true)
  sites_suspended=$(scheduler_job_report_get "site_review" "sites_suspended" 2>/dev/null || true)
  sites_manual=$(scheduler_job_report_get "site_review" "sites_manual" 2>/dev/null || true)
  setup_pending_domains=$(scheduler_job_report_get "site_review" "setup_pending_domains" 2>/dev/null || true)
  setup_stale_domains=$(scheduler_job_report_get "site_review" "setup_stale_domains" 2>/dev/null || true)
  pause_candidate_domains=$(scheduler_job_report_get "site_review" "pause_candidate_domains" 2>/dev/null || true)
  suspended_domains=$(scheduler_job_report_get "site_review" "suspended_domains" 2>/dev/null || true)

  ui_section "Result"
  print_kv_table \
    "Site review|${enabled}" \
    "Shared scheduler cron|${cron_state}" \
    "Interval|${interval}m" \
    "Stale setup threshold|${stale_days}d" \
    "Last run|$(scheduler_epoch_human "$last_run")" \
    "Last report|$(scheduler_epoch_human "${generated_at:-}")" \
    "Last status|${last_status}" \
    "Last summary|${last_message}" \
    "Sites total|${sites_total:-n/a}" \
    "Sites needing setup|${sites_setup_pending:-n/a}" \
    "Sites stale in setup|${sites_setup_stale:-n/a}" \
    "Pause candidates|${sites_pause_candidates:-n/a}" \
    "Sites suspended|${sites_suspended:-n/a}" \
    "Sites in manual optimization|${sites_manual:-n/a}"

  if [[ -n "${setup_pending_domains:-}" || -n "${setup_stale_domains:-}" || -n "${pause_candidate_domains:-}" || -n "${suspended_domains:-}" ]]; then
    ui_section "Highlights"
    local highlights=()
    [[ -n "${setup_pending_domains:-}" ]] && highlights+=("Needs setup|${setup_pending_domains}")
    [[ -n "${setup_stale_domains:-}" ]] && highlights+=("Stale in setup|${setup_stale_domains}")
    [[ -n "${pause_candidate_domains:-}" ]] && highlights+=("Good pause candidates|${pause_candidate_domains}")
    [[ -n "${suspended_domains:-}" ]] && highlights+=("Already paused|${suspended_domains}")
    print_kv_table "${highlights[@]}"
  fi

  ui_section "Next steps"
  ui_kv "Run review now" "simai-admin.sh self scheduler-run --job site-review"
  ui_kv "Open health review" "simai-admin.sh self health-review-status"
}

register_cmd "self" "update" "Update simai-env/admin scripts" "self_update_handler" "" ""
register_cmd "self" "version" "Show local and remote simai-env version" "self_version_handler" "" ""
register_cmd "self" "bootstrap" "Repair Environment (base stack: nginx/php/mysql/certbot/etc.)" "self_bootstrap_handler" "" "php= mysql= node-version="
register_cmd "self" "status" "Show platform/service status" "self_status_handler" "" ""
register_cmd "self" "platform-status" "Show platform diagnostic status" "self_platform_status_handler" "" ""
register_cmd "self" "auto-optimize-status" "Show simple automatic optimization status" "self_auto_optimize_status_handler" "" ""
register_cmd "self" "auto-optimize-enable" "Enable simple automatic optimization" "self_auto_optimize_enable_handler" "" ""
register_cmd "self" "auto-optimize-disable" "Disable simple automatic optimization" "self_auto_optimize_disable_handler" "" ""
register_cmd "self" "health-review-status" "Show platform health review status" "self_health_review_status_handler" "" ""
register_cmd "self" "site-review-status" "Show site review status" "self_site_review_status_handler" "" ""
register_cmd "self" "scheduler" "Run the internal simai scheduler tick" "self_scheduler_handler" "" ""
register_cmd "self" "scheduler-status" "Show internal scheduler status" "self_scheduler_status_handler" "" ""
register_cmd "self" "scheduler-enable" "Enable scheduler globally or by job" "self_scheduler_enable_handler" "" "job="
register_cmd "self" "scheduler-disable" "Disable scheduler globally or by job" "self_scheduler_disable_handler" "" "job="
register_cmd "self" "scheduler-run" "Run one scheduler job immediately" "self_scheduler_run_handler" "" "job="
register_cmd "self" "perf-status" "Show server optimization status" "self_perf_status_handler" "" ""
register_cmd "self" "perf-plan" "Show FPM reduction plan for oversubscribed servers" "self_perf_plan_handler" "" "limit="
register_cmd "self" "perf-rebalance" "Apply safe/parked FPM tuning to top heavy pools" "self_perf_rebalance_handler" "" "limit= mode= confirm="
register_cmd "self" "perf-apply" "Apply managed performance baseline preset" "self_perf_apply_handler" "" "preset= confirm="

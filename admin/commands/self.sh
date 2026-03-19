#!/usr/bin/env bash
set -euo pipefail

self_update_ref() {
  local branch="${SIMAI_UPDATE_BRANCH:-main}"
  local ref="${SIMAI_UPDATE_REF:-refs/heads/${branch}}"
  if [[ "$ref" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]]; then
    echo "$ref"
    return 0
  fi
  echo "refs/heads/main"
}

self_remote_version_url() {
  local ref
  ref="$(self_update_ref)"
  case "$ref" in
    refs/heads/*)
      echo "https://raw.githubusercontent.com/simai/simai-env/${ref#refs/heads/}/VERSION"
      ;;
    refs/tags/*)
      echo "https://raw.githubusercontent.com/simai/simai-env/${ref#refs/tags/}/VERSION"
      ;;
    *)
      echo "https://raw.githubusercontent.com/simai/simai-env/main/VERSION"
      ;;
  esac
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
  progress_init 3
  progress_step "Running bootstrap (php=${php}, mysql=${mysql}, node=${node})"
  if ! "${SCRIPT_DIR}/simai-env.sh" bootstrap --php "$php" --mysql "$mysql" --node-version "$node"; then
    progress_done "Bootstrap failed"
    return 1
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
  ui_header "SIMAI ENV · Performance baseline"

  perf_detect_resources
  local recommended_preset
  recommended_preset=$(perf_recommended_preset)
  local managed_preset="${SIMAI_PERF_PRESET:-none}"

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
  mysql_buffer=$(perf_mysql_show_var "innodb_buffer_pool_size")
  mysql_connections=$(perf_mysql_show_var "max_connections")
  mysql_slow=$(perf_mysql_show_var "slow_query_log")
  mysql_long=$(perf_mysql_show_var "long_query_time")
  mysql_tmp=$(perf_mysql_show_var "tmp_table_size")
  mysql_heap=$(perf_mysql_show_var "max_heap_table_size")
  [[ -z "$mysql_buffer" ]] && mysql_buffer="unknown"
  [[ -z "$mysql_connections" ]] && mysql_connections="unknown"
  [[ -z "$mysql_slow" ]] && mysql_slow="unknown"
  [[ -z "$mysql_long" ]] && mysql_long="unknown"
  [[ -z "$mysql_tmp" ]] && mysql_tmp="unknown"
  [[ -z "$mysql_heap" ]] && mysql_heap="unknown"

  local redis_state="missing"
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_state="active"
    else
      redis_state="inactive"
    fi
  fi
  local redis_maxmemory redis_policy redis_conf
  redis_maxmemory=$(perf_redis_config_get "maxmemory")
  redis_policy=$(perf_redis_config_get "maxmemory-policy")
  redis_conf=$(perf_redis_conf_path)
  [[ -z "$redis_maxmemory" ]] && redis_maxmemory="unknown"
  [[ -z "$redis_policy" ]] && redis_policy="unknown"

  ui_section "Result"
  print_kv_table \
    "Server size|cpu=${PERF_CPU_COUNT}, mem=${PERF_MEM_MB}M, swap=${PERF_SWAP_MB}M" \
    "Recommended preset|${recommended_preset}" \
    "Managed preset|${managed_preset}" \
    "FPM site defaults|${fpm_defaults}" \
    "OPcache defaults|${opcache_defaults}" \
    "nginx snippet|${nginx_managed} (${nginx_conf})" \
    "nginx gzip|${nginx_gzip}" \
    "nginx keepalive|${nginx_keepalive}" \
    "mysql buffer pool|$(perf_bytes_human "$mysql_buffer")" \
    "mysql max connections|${mysql_connections}" \
    "mysql slow query log|${mysql_slow}" \
    "mysql long_query_time|${mysql_long}" \
    "mysql tmp/max heap|$(perf_bytes_human "$mysql_tmp") / $(perf_bytes_human "$mysql_heap")" \
    "redis|${redis_state}" \
    "redis maxmemory|${redis_maxmemory}" \
    "redis policy|${redis_policy}" \
    "redis snippet|$( [[ -f "$redis_conf" ]] && printf 'present (%s)' "$redis_conf" || printf 'missing (%s)' "$redis_conf" )"
  ui_section "Next steps"
  ui_kv "Apply recommended preset" "simai-admin.sh self perf-apply --preset ${recommended_preset} --confirm yes"
  ui_kv "Apply medium preset" "simai-admin.sh self perf-apply --preset medium --confirm yes"
}

self_perf_apply_handler() {
  parse_kv_args "$@"
  local preset="${PARSED_ARGS[preset]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  if [[ -z "$preset" ]]; then
    preset=$(perf_recommended_preset)
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply performance baseline changes"
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

  progress_done "Performance baseline applied"

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
  ui_kv "Review status" "simai-admin.sh self perf-status"
  ui_kv "Check platform" "simai-admin.sh self platform-status"
}

register_cmd "self" "update" "Update simai-env/admin scripts" "self_update_handler" "" ""
register_cmd "self" "version" "Show local and remote simai-env version" "self_version_handler" "" ""
register_cmd "self" "bootstrap" "Repair Environment (base stack: nginx/php/mysql/certbot/etc.)" "self_bootstrap_handler" "" "php= mysql= node-version="
register_cmd "self" "status" "Show platform/service status" "self_status_handler" "" ""
register_cmd "self" "platform-status" "Show platform diagnostic status" "self_platform_status_handler" "" ""
register_cmd "self" "perf-status" "Show performance baseline status" "self_perf_status_handler" "" ""
register_cmd "self" "perf-apply" "Apply managed performance baseline preset" "self_perf_apply_handler" "" "preset= confirm="

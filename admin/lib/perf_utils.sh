#!/usr/bin/env bash
set -euo pipefail

perf_normalize_preset() {
  local preset="${1:-}"
  preset=$(printf '%s' "$preset" | tr '[:upper:]' '[:lower:]')
  case "$preset" in
    small|medium|large) echo "$preset" ;;
    *) return 1 ;;
  esac
}

perf_detect_resources() {
  PERF_CPU_COUNT=$(nproc 2>/dev/null || echo 1)
  PERF_MEM_MB=$(free -m 2>/dev/null | awk 'NR==2{print $2}')
  PERF_MEM_AVAILABLE_MB=$(free -m 2>/dev/null | awk 'NR==2{print $7}')
  PERF_SWAP_MB=$(free -m 2>/dev/null | awk 'NR==3{print $2}')
  [[ -z "${PERF_CPU_COUNT:-}" ]] && PERF_CPU_COUNT=1
  [[ -z "${PERF_MEM_MB:-}" ]] && PERF_MEM_MB=0
  [[ -z "${PERF_MEM_AVAILABLE_MB:-}" ]] && PERF_MEM_AVAILABLE_MB=0
  [[ -z "${PERF_SWAP_MB:-}" ]] && PERF_SWAP_MB=0
}

perf_recommended_preset() {
  perf_detect_resources
  if (( PERF_MEM_MB <= 4096 || PERF_CPU_COUNT <= 2 )); then
    echo "small"
  elif (( PERF_MEM_MB <= 8192 || PERF_CPU_COUNT <= 4 )); then
    echo "medium"
  else
    echo "large"
  fi
}

perf_use_preset() {
  local preset
  preset=$(perf_normalize_preset "${1:-}") || {
    error "Unsupported performance preset: ${1:-}"
    return 1
  }

  PERF_PRESET="$preset"
  case "$preset" in
    small)
      PERF_FPM_PM="ondemand"
      PERF_FPM_MAX_CHILDREN="8"
      PERF_FPM_IDLE_TIMEOUT="10s"
      PERF_FPM_MAX_REQUESTS="500"
      PERF_OPCACHE_MEMORY="128"
      PERF_OPCACHE_STRINGS="8"
      PERF_OPCACHE_MAX_FILES="10000"
      PERF_OPCACHE_VALIDATE="1"
      PERF_OPCACHE_REVALIDATE="2"
      PERF_REALPATH_CACHE_SIZE="4096K"
      PERF_REALPATH_CACHE_TTL="600"
      PERF_NGINX_KEEPALIVE_TIMEOUT="30"
      PERF_NGINX_GZIP_COMP_LEVEL="5"
      PERF_MYSQL_BUFFER_POOL="256M"
      PERF_MYSQL_MAX_CONNECTIONS="80"
      PERF_MYSQL_TMP_TABLE_SIZE="32M"
      PERF_MYSQL_MAX_HEAP_SIZE="32M"
      PERF_MYSQL_LONG_QUERY_TIME="2"
      PERF_REDIS_MAXMEMORY="128mb"
      PERF_REDIS_POLICY="allkeys-lru"
      ;;
    medium)
      PERF_FPM_PM="ondemand"
      PERF_FPM_MAX_CHILDREN="16"
      PERF_FPM_IDLE_TIMEOUT="10s"
      PERF_FPM_MAX_REQUESTS="750"
      PERF_OPCACHE_MEMORY="192"
      PERF_OPCACHE_STRINGS="16"
      PERF_OPCACHE_MAX_FILES="20000"
      PERF_OPCACHE_VALIDATE="1"
      PERF_OPCACHE_REVALIDATE="2"
      PERF_REALPATH_CACHE_SIZE="4096K"
      PERF_REALPATH_CACHE_TTL="600"
      PERF_NGINX_KEEPALIVE_TIMEOUT="30"
      PERF_NGINX_GZIP_COMP_LEVEL="5"
      PERF_MYSQL_BUFFER_POOL="512M"
      PERF_MYSQL_MAX_CONNECTIONS="120"
      PERF_MYSQL_TMP_TABLE_SIZE="64M"
      PERF_MYSQL_MAX_HEAP_SIZE="64M"
      PERF_MYSQL_LONG_QUERY_TIME="2"
      PERF_REDIS_MAXMEMORY="256mb"
      PERF_REDIS_POLICY="allkeys-lru"
      ;;
    large)
      PERF_FPM_PM="ondemand"
      PERF_FPM_MAX_CHILDREN="32"
      PERF_FPM_IDLE_TIMEOUT="10s"
      PERF_FPM_MAX_REQUESTS="1000"
      PERF_OPCACHE_MEMORY="256"
      PERF_OPCACHE_STRINGS="16"
      PERF_OPCACHE_MAX_FILES="40000"
      PERF_OPCACHE_VALIDATE="1"
      PERF_OPCACHE_REVALIDATE="2"
      PERF_REALPATH_CACHE_SIZE="8192K"
      PERF_REALPATH_CACHE_TTL="600"
      PERF_NGINX_KEEPALIVE_TIMEOUT="30"
      PERF_NGINX_GZIP_COMP_LEVEL="5"
      PERF_MYSQL_BUFFER_POOL="1G"
      PERF_MYSQL_MAX_CONNECTIONS="200"
      PERF_MYSQL_TMP_TABLE_SIZE="128M"
      PERF_MYSQL_MAX_HEAP_SIZE="128M"
      PERF_MYSQL_LONG_QUERY_TIME="2"
      PERF_REDIS_MAXMEMORY="512mb"
      PERF_REDIS_POLICY="allkeys-lru"
      ;;
  esac
}

perf_env_file() {
  echo "/etc/simai-env.conf"
}

perf_replace_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$file" ]]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$file" >"$tmp"
  fi
  {
    cat "$tmp"
    [[ -s "$tmp" ]] && printf "\n"
    printf "%s\n" "$begin"
    printf "%s\n" "$content"
    printf "%s\n" "$end"
  } >"${tmp}.new"
  install -m 0644 /dev/null "$file"
  cat "${tmp}.new" >"$file"
  rm -f "$tmp" "${tmp}.new"
}

perf_apply_env_defaults() {
  local file
  file=$(perf_env_file)
  local content
  content=$(cat <<EOF
SIMAI_PERF_PRESET=${PERF_PRESET}
SIMAI_PERF_FPM_PM=${PERF_FPM_PM}
SIMAI_PERF_FPM_MAX_CHILDREN=${PERF_FPM_MAX_CHILDREN}
SIMAI_PERF_FPM_IDLE_TIMEOUT=${PERF_FPM_IDLE_TIMEOUT}
SIMAI_PERF_FPM_MAX_REQUESTS=${PERF_FPM_MAX_REQUESTS}
SIMAI_PERF_OPCACHE_MEMORY=${PERF_OPCACHE_MEMORY}
SIMAI_PERF_OPCACHE_STRINGS=${PERF_OPCACHE_STRINGS}
SIMAI_PERF_OPCACHE_MAX_FILES=${PERF_OPCACHE_MAX_FILES}
SIMAI_PERF_OPCACHE_VALIDATE=${PERF_OPCACHE_VALIDATE}
SIMAI_PERF_OPCACHE_REVALIDATE=${PERF_OPCACHE_REVALIDATE}
SIMAI_PERF_REALPATH_CACHE_SIZE=${PERF_REALPATH_CACHE_SIZE}
SIMAI_PERF_REALPATH_CACHE_TTL=${PERF_REALPATH_CACHE_TTL}
SIMAI_PERF_NGINX_KEEPALIVE_TIMEOUT=${PERF_NGINX_KEEPALIVE_TIMEOUT}
SIMAI_PERF_NGINX_GZIP_COMP_LEVEL=${PERF_NGINX_GZIP_COMP_LEVEL}
SIMAI_PERF_MYSQL_BUFFER_POOL=${PERF_MYSQL_BUFFER_POOL}
SIMAI_PERF_MYSQL_MAX_CONNECTIONS=${PERF_MYSQL_MAX_CONNECTIONS}
SIMAI_PERF_MYSQL_TMP_TABLE_SIZE=${PERF_MYSQL_TMP_TABLE_SIZE}
SIMAI_PERF_MYSQL_MAX_HEAP_SIZE=${PERF_MYSQL_MAX_HEAP_SIZE}
SIMAI_PERF_MYSQL_LONG_QUERY_TIME=${PERF_MYSQL_LONG_QUERY_TIME}
SIMAI_PERF_REDIS_MAXMEMORY=${PERF_REDIS_MAXMEMORY}
SIMAI_PERF_REDIS_POLICY=${PERF_REDIS_POLICY}
EOF
)
  perf_replace_managed_block "$file" "# simai-perf-begin" "# simai-perf-end" "$content"
}

perf_php_ini_render() {
  cat <<EOF
; managed by simai-env performance baseline
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${PERF_OPCACHE_MEMORY}
opcache.interned_strings_buffer=${PERF_OPCACHE_STRINGS}
opcache.max_accelerated_files=${PERF_OPCACHE_MAX_FILES}
opcache.validate_timestamps=${PERF_OPCACHE_VALIDATE}
opcache.revalidate_freq=${PERF_OPCACHE_REVALIDATE}
realpath_cache_size=${PERF_REALPATH_CACHE_SIZE}
realpath_cache_ttl=${PERF_REALPATH_CACHE_TTL}
EOF
}

perf_installed_fpm_versions() {
  local dir
  shopt -s nullglob
  for dir in /etc/php/*/fpm; do
    [[ -d "$dir" ]] || continue
    basename "$(dirname "$dir")"
  done
  shopt -u nullglob
}

perf_apply_php_fpm_baseline() {
  local ver file
  local versions=()
  mapfile -t versions < <(perf_installed_fpm_versions)
  for ver in "${versions[@]}"; do
    file="/etc/php/${ver}/fpm/conf.d/99-simai-performance.ini"
    perf_php_ini_render >"$file"
    os_svc_reload_or_restart "php${ver}-fpm" || {
      error "Failed to reload php${ver}-fpm after performance baseline update"
      return 1
    }
  done
}

perf_nginx_conf_path() {
  echo "/etc/nginx/conf.d/99-simai-performance.conf"
}

perf_nginx_render() {
  cat <<EOF
# managed by simai-env performance baseline
gzip_vary on;
gzip_proxied any;
gzip_comp_level ${PERF_NGINX_GZIP_COMP_LEVEL};
gzip_min_length 1024;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
keepalive_timeout ${PERF_NGINX_KEEPALIVE_TIMEOUT};
server_tokens off;
EOF
}

perf_apply_nginx_baseline() {
  local file backup=""
  file=$(perf_nginx_conf_path)
  [[ -f "$file" ]] && backup="${file}.bak.$(date +%Y%m%d%H%M%S)" && cp -p "$file" "$backup"
  perf_nginx_render >"$file"
  if ! nginx -t >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -p "$backup" "$file"
    else
      rm -f "$file"
    fi
    error "nginx config test failed after performance baseline update"
    return 1
  fi
  os_svc_reload_or_restart nginx || true
}

perf_mysql_conf_path() {
  echo "/etc/mysql/mysql.conf.d/99-simai-performance.cnf"
}

perf_mysql_render() {
  cat <<EOF
[mysqld]
innodb_buffer_pool_size = ${PERF_MYSQL_BUFFER_POOL}
max_connections = ${PERF_MYSQL_MAX_CONNECTIONS}
tmp_table_size = ${PERF_MYSQL_TMP_TABLE_SIZE}
max_heap_table_size = ${PERF_MYSQL_MAX_HEAP_SIZE}
slow_query_log = ON
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = ${PERF_MYSQL_LONG_QUERY_TIME}
EOF
}

perf_apply_mysql_baseline() {
  local file backup=""
  file=$(perf_mysql_conf_path)
  [[ -f "$file" ]] && backup="${file}.bak.$(date +%Y%m%d%H%M%S)" && cp -p "$file" "$backup"
  perf_mysql_render >"$file"
  if ! os_svc_restart mysql; then
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -p "$backup" "$file"
      os_svc_restart mysql || true
    else
      rm -f "$file"
      os_svc_restart mysql || true
    fi
    error "Failed to restart mysql after performance baseline update"
    return 1
  fi
}

perf_redis_conf_path() {
  echo "/etc/redis/redis.conf.d/99-simai-performance.conf"
}

perf_redis_ensure_include() {
  local main_conf="/etc/redis/redis.conf"
  [[ -f "$main_conf" ]] || return 0
  grep -Fq "include /etc/redis/redis.conf.d/*.conf" "$main_conf" && return 0
  printf "\ninclude /etc/redis/redis.conf.d/*.conf\n" >>"$main_conf"
}

perf_redis_render() {
  cat <<EOF
# managed by simai-env performance baseline
maxmemory ${PERF_REDIS_MAXMEMORY}
maxmemory-policy ${PERF_REDIS_POLICY}
EOF
}

perf_apply_redis_baseline() {
  if ! os_svc_has_unit "redis-server"; then
    return 0
  fi
  install -d /etc/redis/redis.conf.d
  perf_redis_ensure_include || return 1
  perf_redis_render >"$(perf_redis_conf_path)"
  if ! os_svc_restart redis-server; then
    error "Failed to restart redis-server after performance baseline update"
    return 1
  fi
}

perf_bytes_human() {
  local val="${1:-0}"
  if [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]]; then
    echo "unknown"
    return 0
  fi
  if (( val >= 1073741824 )); then
    echo "$(( val / 1073741824 ))G"
  elif (( val >= 1048576 )); then
    echo "$(( val / 1048576 ))M"
  elif (( val >= 1024 )); then
    echo "$(( val / 1024 ))K"
  else
    echo "${val}B"
  fi
}

perf_mysql_show_var() {
  local name="$1"
  mysql -NBe "SHOW VARIABLES LIKE '${name}';" 2>/dev/null | awk '{print $2}' | head -n1
}

perf_redis_config_get() {
  local key="$1"
  redis-cli CONFIG GET "$key" 2>/dev/null | awk 'NR==2{print}'
}

perf_parse_size_to_bytes() {
  local raw="${1:-0}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    ""|unknown|n/a) echo "0" ;;
    *gb|*g) echo $(( ${raw%g*} * 1073741824 )) ;;
    *mb|*m) echo $(( ${raw%m*} * 1048576 )) ;;
    *kb|*k) echo $(( ${raw%k*} * 1024 )) ;;
    *b) echo "${raw%b}" ;;
    *[0-9]) echo "$raw" ;;
    *) echo "0" ;;
  esac
}

perf_ratio_band() {
  local current="$1" total="$2"
  if [[ -z "$current" || -z "$total" || ! "$current" =~ ^[0-9]+$ || ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
    echo "unknown"
    return 0
  fi
  local pct=$(( current * 100 / total ))
  if (( pct >= 85 )); then
    echo "high (${current}/${total})"
  elif (( pct >= 60 )); then
    echo "medium (${current}/${total})"
  else
    echo "low (${current}/${total})"
  fi
}

perf_mysql_show_status() {
  local name="$1"
  mysql -NBe "SHOW STATUS LIKE '${name}';" 2>/dev/null | awk '{print $2}' | head -n1
}

perf_mysql_slow_log_size() {
  local path
  path=$(perf_mysql_show_var "slow_query_log_file")
  [[ -z "$path" ]] && path="/var/log/mysql/mysql-slow.log"
  if [[ -f "$path" ]]; then
    local size
    size=$(wc -c <"$path" 2>/dev/null | tr -d ' ' || true)
    [[ -n "$size" ]] && printf "%s (%s)" "$(perf_bytes_human "$size")" "$path" && return 0
  fi
  echo "missing (${path})"
}

perf_redis_info_get() {
  local key="$1"
  redis-cli INFO 2>/dev/null | awk -F: -v target="$key" '$1==target{print $2}' | tr -d '\r' | head -n1
}

perf_redis_memory_pressure() {
  local used="$1" max="$2"
  if [[ -z "$used" || -z "$max" || ! "$used" =~ ^[0-9]+$ || ! "$max" =~ ^[0-9]+$ || "$max" -eq 0 ]]; then
    echo "unknown"
    return 0
  fi
  perf_ratio_band "$used" "$max"
}

perf_fpm_service_summary() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi
  local total=0 active=0 unit
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    total=$((total + 1))
    if systemctl is-active --quiet "$unit"; then
      active=$((active + 1))
    fi
  done < <(systemctl list-unit-files --type=service 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
  if (( total == 0 )); then
    echo "missing"
    return 0
  fi
  echo "${active}/${total} active"
}

perf_fpm_pool_count() {
  local count=0 file
  shopt -s nullglob
  for file in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$file" ]] || continue
    count=$((count + 1))
  done
  shopt -u nullglob
  echo "$count"
}

perf_fpm_total_max_children() {
  local total=0 file val
  shopt -s nullglob
  for file in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$file" ]] || continue
    val=$(perf_pool_directive_get "$file" "pm.max_children" || true)
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      total=$((total + val))
    fi
  done
  shopt -u nullglob
  echo "$total"
}

perf_fpm_recommended_total_children() {
  perf_detect_resources
  local mem_mb="${PERF_MEM_MB:-0}"
  if [[ -z "$mem_mb" || ! "$mem_mb" =~ ^[0-9]+$ || "$mem_mb" -le 0 ]]; then
    echo "0"
    return 0
  fi
  local reserve_mb=512
  if (( mem_mb > 4096 )); then
    reserve_mb=1024
  fi
  local worker_mb=64
  local usable=$(( mem_mb - reserve_mb ))
  if (( usable <= worker_mb )); then
    echo "1"
    return 0
  fi
  local budget=$(( usable / worker_mb ))
  (( budget < 1 )) && budget=1
  echo "$budget"
}

perf_fpm_oversubscription_risk() {
  local total="$1" budget="$2"
  if [[ -z "$total" || -z "$budget" || ! "$total" =~ ^[0-9]+$ || ! "$budget" =~ ^[0-9]+$ || "$budget" -le 0 ]]; then
    echo "unknown"
    return 0
  fi
  local pct=$(( total * 100 / budget ))
  if (( pct >= 200 )); then
    echo "critical (${total}/${budget})"
  elif (( pct >= 120 )); then
    echo "high (${total}/${budget})"
  elif (( pct >= 80 )); then
    echo "medium (${total}/${budget})"
  else
    echo "low (${total}/${budget})"
  fi
}

perf_memory_available_summary() {
  perf_detect_resources
  local avail="${PERF_MEM_AVAILABLE_MB:-0}"
  local total="${PERF_MEM_MB:-0}"
  if [[ ! "$avail" =~ ^[0-9]+$ || ! "$total" =~ ^[0-9]+$ || "$total" -le 0 ]]; then
    echo "unknown"
    return 0
  fi
  local pct=$(( avail * 100 / total ))
  echo "${avail}M (${pct}% free)"
}

perf_fpm_excess_children() {
  local total="$1" budget="$2"
  if [[ -z "$total" || -z "$budget" || ! "$total" =~ ^[0-9]+$ || ! "$budget" =~ ^[0-9]+$ ]]; then
    echo "0"
    return 0
  fi
  if (( total > budget )); then
    echo $(( total - budget ))
  else
    echo "0"
  fi
}

perf_site_mode_get() {
  local domain="$1"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "mode" ]]; then
      echo "${entry#*|}"
      return 0
    fi
  done < <(read_site_perf_settings "$domain")
  echo "none"
}

site_usage_class_normalize() {
  local raw="${1:-standard}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  case "$raw" in
    standard|default) echo "standard" ;;
    high|high-traffic|hightraffic|busy) echo "high-traffic" ;;
    rare|rarely-used|rarelyused|cold) echo "rarely-used" ;;
    *) return 1 ;;
  esac
}

site_usage_class_get() {
  local domain="$1"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "usage_class" ]]; then
      local value="${entry#*|}"
      site_usage_class_normalize "$value" && return 0
    fi
  done < <(read_site_perf_settings "$domain")
  echo "standard"
}

site_auto_optimize_state_normalize() {
  local raw="${1:-inherit}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  case "$raw" in
    ""|inherit|default|auto) echo "inherit" ;;
    yes|enabled|enable|on) echo "yes" ;;
    no|disabled|disable|off) echo "no" ;;
    *) return 1 ;;
  esac
}

site_auto_optimize_state_get() {
  local domain="$1"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "auto_optimize" ]]; then
      local value="${entry#*|}"
      site_auto_optimize_state_normalize "$value" && return 0
    fi
  done < <(read_site_perf_settings "$domain")
  echo "inherit"
}

site_auto_optimize_effective_enabled() {
  local domain="$1"
  local global_enabled site_state
  global_enabled="$(scheduler_normalize_bool "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}")"
  [[ "$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" == "yes" ]] || global_enabled="no"
  site_state="$(site_auto_optimize_state_get "$domain")"
  case "$site_state" in
    no) echo "no" ;;
    yes) [[ "$global_enabled" == "yes" ]] && echo "yes" || echo "no (global off)" ;;
    *)
      [[ "$global_enabled" == "yes" ]] && echo "yes (inherit)" || echo "no (global off)"
      ;;
  esac
}

site_usage_class_to_perf_mode() {
  local usage
  usage=$(site_usage_class_normalize "${1:-standard}") || return 1
  case "$usage" in
    standard) echo "balanced" ;;
    high-traffic) echo "aggressive" ;;
    rarely-used) echo "parked" ;;
  esac
}

site_usage_class_to_rebalance_mode() {
  local usage
  usage=$(site_usage_class_normalize "${1:-standard}") || return 1
  case "$usage" in
    standard) echo "safe" ;;
    high-traffic) echo "balanced" ;;
    rarely-used) echo "parked" ;;
  esac
}

perf_site_mode_target_children() {
  local profile="$1" mode="$2"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "pm.max_children" ]]; then
      echo "${entry#*|}"
      return 0
    fi
  done < <(site_perf_mode_defaults "$profile" "$mode" 2>/dev/null || true)
  echo "0"
}

perf_fpm_top_pools() {
  local limit="${1:-5}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=5
  (( limit < 1 )) && limit=1

  declare -A domain_map=()
  declare -A profile_map=()
  declare -A mode_map=()
  declare -A usage_map=()
  declare -A auto_optimize_map=()
  local domain socket_project profile project
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    if ! read_site_metadata "$domain" >/dev/null 2>&1; then
      continue
    fi
    profile="${SITE_META[profile]:-unknown}"
    project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
    socket_project="${SITE_META[php_socket_project]:-$project}"
    [[ -z "$socket_project" ]] && continue
    domain_map["$socket_project"]="$domain"
    profile_map["$socket_project"]="$profile"
    mode_map["$socket_project"]="$(perf_site_mode_get "$domain")"
    usage_map["$socket_project"]="$(site_usage_class_get "$domain")"
    auto_optimize_map["$socket_project"]="$(site_auto_optimize_state_get "$domain")"
  done < <(list_sites 2>/dev/null || true)

  local rows=()
  local file pool_name current php_version mapped_domain mapped_profile managed_mode usage_class auto_optimize_state suggested_mode target_children reduction
  shopt -s nullglob
  for file in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$file" ]] || continue
    current=$(perf_pool_directive_get "$file" "pm.max_children" || true)
    [[ -n "$current" && "$current" =~ ^[0-9]+$ ]] || continue
    pool_name=$(basename "$file" .conf)
    php_version="${file#/etc/php/}"
    php_version="${php_version%%/*}"
    mapped_domain="${domain_map[$pool_name]:-$pool_name}"
    mapped_profile="${profile_map[$pool_name]:-unknown}"
    managed_mode="${mode_map[$pool_name]:-none}"
    usage_class="${usage_map[$pool_name]:-standard}"
    auto_optimize_state="${auto_optimize_map[$pool_name]:-inherit}"
    suggested_mode=$(site_usage_class_to_rebalance_mode "$usage_class")
    target_children=$(perf_site_mode_target_children "$mapped_profile" "$suggested_mode")
    [[ -n "$target_children" && "$target_children" =~ ^[0-9]+$ ]] || target_children=0
    reduction=0
    if (( current > target_children && target_children > 0 )); then
      reduction=$(( current - target_children ))
    fi
    rows+=("${current}|${mapped_domain}|${mapped_profile}|${managed_mode}|${usage_class}|${auto_optimize_state}|${suggested_mode}|${target_children}|${reduction}|${php_version}|${file}")
  done
  shopt -u nullglob

  if (( ${#rows[@]} == 0 )); then
    return 0
  fi

  printf "%s\n" "${rows[@]}" | sort -t'|' -k1,1nr | head -n "$limit"
}

perf_fpm_mode_floor() {
  local mode="${1:-safe}"
  local total=0
  declare -A profile_map=()
  local domain socket_project profile project
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    if ! read_site_metadata "$domain" >/dev/null 2>&1; then
      continue
    fi
    profile="${SITE_META[profile]:-unknown}"
    project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
    socket_project="${SITE_META[php_socket_project]:-$project}"
    [[ -z "$socket_project" ]] && continue
    profile_map["$socket_project"]="$profile"
  done < <(list_sites 2>/dev/null || true)

  local file pool_name current profile target
  shopt -s nullglob
  for file in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$file" ]] || continue
    current=$(perf_pool_directive_get "$file" "pm.max_children" || true)
    [[ -n "$current" && "$current" =~ ^[0-9]+$ ]] || continue
    pool_name=$(basename "$file" .conf)
    profile="${profile_map[$pool_name]:-unknown}"
    target=$(perf_site_mode_target_children "$profile" "$mode")
    if [[ -n "$target" && "$target" =~ ^[0-9]+$ && "$target" -gt 0 ]]; then
      total=$(( total + target ))
    else
      total=$(( total + current ))
    fi
  done
  shopt -u nullglob
  echo "$total"
}

perf_pool_socket_path() {
  local php_version="$1" socket_project="$2"
  echo "/run/php/php${php_version}-fpm-${socket_project}.sock"
}

site_perf_file() {
  local domain="$1"
  echo "$(site_sites_config_dir)/${domain}/perf.env"
}

read_site_perf_settings() {
  local domain="$1"
  local file
  file=$(site_perf_file "$domain")
  [[ -f "$file" ]] || return 0
  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    NF >= 2 {
      key=$1
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)
      val=substr($0, index($0, "=")+1)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      print key "|" val
    }
  ' "$file"
}

write_site_perf_settings() {
  local domain="$1"
  shift
  local file tmp dir
  file=$(site_perf_file "$domain")
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp=$(mktemp)
  local entry
  for entry in "$@"; do
    [[ -z "$entry" ]] && continue
    printf "%s=%s\n" "${entry%%|*}" "${entry#*|}" >>"$tmp"
  done
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$file"
    chmod 0644 "$file"
    chown root:root "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
    rm -f "$file"
  fi
}

write_site_perf_settings_merged() {
  local domain="$1"
  shift
  declare -A kv=()
  local entry key
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    kv["${entry%%|*}"]="${entry#*|}"
  done < <(read_site_perf_settings "$domain")

  for entry in "$@"; do
    [[ -z "$entry" ]] && continue
    key="${entry%%|*}"
    kv["$key"]="${entry#*|}"
  done

  local ordered=()
  local known_keys=(
    mode
    usage_class
    auto_optimize
    pm
    pm.max_children
    pm.process_idle_timeout
    pm.max_requests
    request_terminate_timeout
  )
  for key in "${known_keys[@]}"; do
    [[ -n "${kv[$key]:-}" ]] || continue
    ordered+=("${key}|${kv[$key]}")
    unset 'kv[$key]'
  done
  for key in $(printf '%s\n' "${!kv[@]}" | sort); do
    [[ -n "${kv[$key]:-}" ]] || continue
    ordered+=("${key}|${kv[$key]}")
  done
  write_site_perf_settings "$domain" "${ordered[@]}"
}

perf_pool_directive_get() {
  local pool_file="$1" key="$2"
  [[ -f "$pool_file" ]] || return 1
  awk -F= -v target="$key" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ "^" target "[[:space:]]*=") {
        sub("^[^=]+=[[:space:]]*", "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
      }
    }
  ' "$pool_file" | tail -n1
}

perf_ini_to_mb() {
  local raw="${1:-}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    "" ) echo "0" ;;
    -1|unlimited) echo "-1" ;;
    *g) echo $(( ${raw%g} * 1024 )) ;;
    *m) echo $(( ${raw%m} )) ;;
    *k) echo $(( ${raw%k} / 1024 )) ;;
    *[0-9]) echo $(( raw / 1048576 )) ;;
    *) echo "0" ;;
  esac
}

site_perf_memory_risk() {
  local memory_limit="$1" max_children="$2"
  perf_detect_resources
  local mem_mb child_count
  mem_mb=$(perf_ini_to_mb "$memory_limit")
  child_count="${max_children:-0}"
  if [[ "$mem_mb" == "-1" || "$mem_mb" == "0" || -z "$child_count" || ! "$child_count" =~ ^[0-9]+$ || "$child_count" -eq 0 || "${PERF_MEM_MB:-0}" -le 0 ]]; then
    echo "unknown"
    return 0
  fi
  local estimated=$(( mem_mb * child_count ))
  local ratio=$(( estimated * 100 / PERF_MEM_MB ))
  if (( ratio >= 100 )); then
    echo "high (~${estimated}M / ${PERF_MEM_MB}M)"
  elif (( ratio >= 60 )); then
    echo "medium (~${estimated}M / ${PERF_MEM_MB}M)"
  else
    echo "low (~${estimated}M / ${PERF_MEM_MB}M)"
  fi
}

site_perf_mode_defaults() {
  local profile="$1" mode="$2"
  local base_children="${SIMAI_PERF_FPM_MAX_CHILDREN:-10}"
  local base_requests="${SIMAI_PERF_FPM_MAX_REQUESTS:-500}"
  local base_pm="${SIMAI_PERF_FPM_PM:-ondemand}"
  local safe_children=$(( base_children / 2 ))
  (( safe_children < 2 )) && safe_children=2
  local aggressive_children=$(( base_children + (base_children / 2) ))
  (( aggressive_children <= base_children )) && aggressive_children=$(( base_children + 2 ))
  local safe_requests=$(( base_requests / 2 ))
  (( safe_requests < 250 )) && safe_requests=250
  local aggressive_requests=$(( base_requests + (base_requests / 2) ))
  (( aggressive_requests <= base_requests )) && aggressive_requests=$(( base_requests + 250 ))

  case "$mode" in
    parked)
      printf "%s\n" \
        "mode|parked" \
        "pm|ondemand" \
        "pm.max_children|2" \
        "pm.process_idle_timeout|5s" \
        "pm.max_requests|200" \
        "request_terminate_timeout|60s"
      ;;
    safe)
      printf "%s\n" \
        "mode|safe" \
        "pm|${base_pm}" \
        "pm.max_children|${safe_children}" \
        "pm.process_idle_timeout|10s" \
        "pm.max_requests|${safe_requests}" \
        "request_terminate_timeout|120s"
      ;;
    balanced)
      local req_timeout="180s"
      [[ "$profile" == "bitrix" ]] && req_timeout="300s"
      printf "%s\n" \
        "mode|balanced" \
        "pm|${base_pm}" \
        "pm.max_children|${base_children}" \
        "pm.process_idle_timeout|10s" \
        "pm.max_requests|${base_requests}" \
        "request_terminate_timeout|${req_timeout}"
      ;;
    aggressive)
      local req_timeout="300s"
      printf "%s\n" \
        "mode|aggressive" \
        "pm|${base_pm}" \
        "pm.max_children|${aggressive_children}" \
        "pm.process_idle_timeout|20s" \
        "pm.max_requests|${aggressive_requests}" \
        "request_terminate_timeout|${req_timeout}"
      ;;
    *)
      return 1
      ;;
  esac
}

apply_site_perf_settings_to_pool() {
  local domain="$1" php_version="$2" socket_project="$3" reload_flag="${4:-yes}"
  local pool_file="/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
  if [[ ! -f "$pool_file" ]]; then
    error "Pool file not found for ${socket_project} (php ${php_version})"
    return 1
  fi

  declare -A kv=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    kv["${entry%%|*}"]="${entry#*|}"
  done < <(read_site_perf_settings "$domain")

  local perf_block=""
  if [[ ${#kv[@]} -gt 0 ]]; then
    perf_block=$'; simai-site-perf-begin\n'
    local key
    for key in pm pm.max_children pm.process_idle_timeout pm.max_requests request_terminate_timeout; do
      [[ -n "${kv[$key]:-}" ]] || continue
      perf_block+="${key} = ${kv[$key]}"$'\n'
    done
    perf_block+=$'; simai-site-perf-end\n'
  fi

  local site_ini_block=""
  site_ini_block=$(awk '/; simai-site-ini-begin/{flag=1}flag{print}/; simai-site-ini-end/{flag=0}' "$pool_file")
  local profile_block=""
  profile_block=$(awk '/; simai-profile-ini-begin/{flag=1}flag{print}/; simai-profile-ini-end/{flag=0}' "$pool_file")
  local base_content
  base_content=$(sed '/; simai-profile-ini-begin/,/; simai-profile-ini-end/d;/; simai-site-ini-begin/,/; simai-site-ini-end/d;/; simai-site-perf-begin/,/; simai-site-perf-end/d' "$pool_file")

  local new_content=""
  new_content+="$base_content"
  [[ -n "$base_content" && "${base_content: -1}" != $'\n' ]] && new_content+=$'\n'
  if [[ -n "$perf_block" ]]; then
    new_content+="$perf_block"
    [[ "${new_content: -1}" != $'\n' ]] && new_content+=$'\n'
  fi
  if [[ -n "$site_ini_block" ]]; then
    new_content+="$site_ini_block"
    [[ "${new_content: -1}" != $'\n' ]] && new_content+=$'\n'
  fi
  if [[ -n "$profile_block" ]]; then
    new_content+="$profile_block"
    [[ "${new_content: -1}" != $'\n' ]] && new_content+=$'\n'
  fi

  local current_content
  current_content=$(cat "$pool_file")
  if [[ "$current_content" == "$new_content" ]]; then
    info "No site performance changes to apply for ${domain}."
    return 0
  fi

  local backup tmp_out
  backup=$(mktemp)
  cp -p "$pool_file" "$backup" >>"$LOG_FILE" 2>&1 || backup=""
  tmp_out=$(mktemp)
  printf "%s" "$new_content" >"$tmp_out"
  chmod --reference="$pool_file" "$tmp_out" 2>/dev/null || true
  chown --reference="$pool_file" "$tmp_out" 2>/dev/null || true
  mv "$tmp_out" "$pool_file"

  local fpm_bin
  fpm_bin=$(command -v "php-fpm${php_version}" 2>/dev/null || true)
  if [[ -z "$fpm_bin" && -x "/usr/sbin/php-fpm${php_version}" ]]; then
    fpm_bin="/usr/sbin/php-fpm${php_version}"
  fi
  if [[ -z "$fpm_bin" ]]; then
    error "php-fpm${php_version} binary not found for config test"
    [[ -n "$backup" && -f "$backup" ]] && cp -p "$backup" "$pool_file" >>"$LOG_FILE" 2>&1 || true
    return 1
  fi
  if ! "$fpm_bin" -t >>"$LOG_FILE" 2>&1; then
    error "php-fpm${php_version} config test failed; restoring previous pool"
    [[ -n "$backup" && -f "$backup" ]] && cp -p "$backup" "$pool_file" >>"$LOG_FILE" 2>&1 || true
    return 1
  fi
  [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"

  if [[ "${reload_flag,,}" != "no" ]]; then
    if ! os_svc_reload "php${php_version}-fpm"; then
      warn "Failed to reload php${php_version}-fpm after applying site perf settings; please reload manually"
    fi
  fi
}

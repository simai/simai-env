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
  PERF_SWAP_MB=$(free -m 2>/dev/null | awk 'NR==3{print $2}')
  [[ -z "${PERF_CPU_COUNT:-}" ]] && PERF_CPU_COUNT=1
  [[ -z "${PERF_MEM_MB:-}" ]] && PERF_MEM_MB=0
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
gzip on;
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

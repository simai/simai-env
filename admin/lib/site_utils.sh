#!/usr/bin/env bash
set -euo pipefail

SIMAI_USER=${SIMAI_USER:-simai}
WWW_ROOT=${WWW_ROOT:-/home/${SIMAI_USER}/www}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-${SCRIPT_DIR}/templates/nginx-laravel.conf}
NGINX_TEMPLATE_GENERIC=${NGINX_TEMPLATE_GENERIC:-${SCRIPT_DIR}/templates/nginx-generic.conf}

project_slug_from_domain() {
  local domain="$1"
  local slug
  slug=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\\+/-/g' -e 's/^-//' -e 's/-$//')
  [[ -z "$slug" ]] && slug="site"
  echo "$slug"
}

list_sites() {
  shopt -s nullglob
  for cfg in /etc/nginx/sites-available/*.conf; do
    local name
    name=$(basename "$cfg" .conf)
    echo "$name"
  done | sort
  shopt -u nullglob
}

ensure_user() {
  if ! id -u "$SIMAI_USER" >/dev/null 2>&1; then
    info "Creating user ${SIMAI_USER}"
    useradd -m -s /bin/bash "$SIMAI_USER"
  fi
  usermod -a -G www-data "$SIMAI_USER" || true
  mkdir -p "$WWW_ROOT"
  chown -R "$SIMAI_USER":www-data "$(dirname "$WWW_ROOT")"
}

resolve_php_bin() {
  local php_version="$1"
  local php_bin
  php_bin=$(command -v "php${php_version}" || true)
  if [[ -z "$php_bin" ]]; then
    php_bin=$(command -v php || echo "/usr/bin/php")
  fi
  echo "$php_bin"
}

installed_php_versions() {
  local versions=()
  shopt -s nullglob
  for d in /etc/php/*; do
    [[ -d "$d" ]] && versions+=("$(basename "$d")")
  done
  shopt -u nullglob
  printf "%s\n" "${versions[@]}"
}

create_php_pool() {
  local project="$1" php_version="$2" project_path="$3"
  local pool_dir="/etc/php/${php_version}/fpm/pool.d"
  local pool_file="${pool_dir}/${project}.conf"
  mkdir -p "$pool_dir"
  cat >"$pool_file" <<EOF
[${project}]
user = ${SIMAI_USER}
group = www-data
listen = /run/php/php${php_version}-fpm-${project}.sock
listen.owner = ${SIMAI_USER}
listen.group = www-data
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
request_terminate_timeout = 120s
chdir = ${project_path}
php_admin_value[error_log] = /var/log/php${php_version}-fpm-${project}.log
php_admin_flag[log_errors] = on
EOF
  systemctl reload "php${php_version}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${php_version}-fpm" >>"$LOG_FILE" 2>&1 || true
}

create_nginx_site() {
  local domain="$1" project="$2" project_path="$3" php_version="$4" template_path="${5:-$NGINX_TEMPLATE}"
  if [[ ! -f "$template_path" ]]; then
    error "nginx template not found at ${template_path}"
    exit 1
  fi
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  sed -e "s#{{SERVER_NAME}}#${domain}#g" \
      -e "s#{{PROJECT_ROOT}}#${project_path}#g" \
      -e "s#{{PROJECT_NAME}}#${project}#g" \
      -e "s#{{PHP_VERSION}}#${php_version}#g" "$template_path" > "$site_available"
  ln -sf "$site_available" "$site_enabled"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  nginx -t >>"$LOG_FILE" 2>&1 || { error "nginx config test failed"; exit 1; }
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || systemctl restart nginx >>"$LOG_FILE" 2>&1 || true
}

ensure_project_permissions() {
  local project_path="$1"
  chown -R "$SIMAI_USER":www-data "$project_path"
  if [[ -d "$project_path/storage" || -d "$project_path/bootstrap/cache" ]]; then
    find "$project_path/storage" "$project_path/bootstrap/cache" -type d -print0 2>/dev/null | xargs -0 -r chmod 775 || true
  fi
}

require_laravel_structure() {
  local project_path="$1"
  if [[ ! -f "$project_path/artisan" ]]; then
    error "artisan not found in ${project_path}; is this a Laravel project?"
    return 1
  fi
}

create_placeholder_if_missing() {
  local project_path="$1"
  local index_php="${project_path}/index.php"
  local public_index="${project_path}/public/index.php"
  if [[ -f "$index_php" || -f "$public_index" ]]; then
    return
  fi
  mkdir -p "${project_path}"
  mkdir -p "${project_path}/public"
  cat >"$index_php" <<'EOF'
<?php
http_response_code(200);
echo "Placeholder: site is configured.";
EOF
  cp "$index_php" "$public_index" 2>/dev/null || true
}

remove_nginx_site() {
  local domain="$1"
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  rm -f "$site_enabled" "$site_available"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >>"$LOG_FILE" 2>&1 || warn "nginx test failed after removing ${domain}"
    systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
  fi
}

remove_php_pools() {
  local project="$1"
  shopt -s nullglob
  local pools=(/etc/php/*/fpm/pool.d/${project}.conf)
  local versions=()
  for pool in "${pools[@]:-}"; do
    rm -f "$pool"
    local ver
    ver=$(echo "$pool" | awk -F'/' '{print $4}')
    versions+=("$ver")
  done
  shopt -u nullglob
  for v in $(printf "%s\n" "${versions[@]}" | sort -u); do
    systemctl reload "php${v}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${v}-fpm" >>"$LOG_FILE" 2>&1 || true
  done
}

remove_project_files() {
  local path="$1"
  if [[ -z "$path" || "$path" == "/" ]]; then
    warn "Skip removing dangerous path: ${path:-<empty>}"
    return
  fi
  rm -rf "$path"
}
